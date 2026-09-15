import Testing

@testable import CapnProto

private func readerBytes(_ words: [UInt64]) -> [UInt8] {
    words.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> UInt64($0 * 8)) } }
}

private func readerStructPointer(offset: Int32 = 0, data: UInt16, pointers: UInt16) -> UInt64 {
    (UInt64(UInt32(bitPattern: offset)) & 0x3fff_ffff) << 2
        | UInt64(data) << 32 | UInt64(pointers) << 48
}

private func readerListPointer(
    offset: Int32 = 0, size: ListElementSize, countOrWords: UInt32
) -> UInt64 {
    1 | (UInt64(UInt32(bitPattern: offset)) & 0x3fff_ffff) << 2
        | UInt64(size.rawValue) << 32 | UInt64(countOrWords & 0x1fff_ffff) << 35
}

private func readerFarPointer(double: Bool = false, landing: UInt32, segment: UInt32) -> UInt64 {
    2 | (double ? 4 : 0) | UInt64(landing & 0x1fff_ffff) << 3 | UInt64(segment) << 32
}

private func expectReaderError(_ expected: CapnProtoError, _ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("expected \(expected)")
    } catch let error as CapnProtoError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// Ported behavior: malformed pointers and reader limits from layout-test.c++,
// message-test.c++, and fuzz-test.c++ at the revision recorded in BASELINES.
@Test func malformedPointersAndResourceLimitsFailDeterministically() throws {
    expectReaderError(.objectOutOfBounds(segment: 0, start: -1, words: 1)) {
        _ = try MessageReader(segments: [
            readerBytes([readerStructPointer(offset: -2, data: 1, pointers: 0)])
        ]).rootStruct()
    }
    expectReaderError(.objectOutOfBounds(segment: 0, start: 1, words: 2)) {
        _ = try MessageReader(segments: [
            readerBytes([readerStructPointer(data: 2, pointers: 0), 0])
        ]).rootStruct()
    }
    expectReaderError(.invalidInlineCompositeTag) {
        _ = try MessageReader(segments: [
            readerBytes([readerListPointer(size: .inlineComposite, countOrWords: 1), 1, 0])
        ]).rootList()
    }
    expectReaderError(.invalidText) {
        _ = try MessageReader(segments: [
            readerBytes([readerListPointer(size: .byte, countOrWords: 1), 0x61])
        ]).rootText()
    }
    expectReaderError(.arithmeticOverflow) { _ = try checkedMultiply(Int.max, 2) }
    expectReaderError(.invalidFarPointer) {
        _ = try MessageReader(segments: [
            readerBytes([readerFarPointer(landing: 0, segment: 7)])
        ]).rootStruct()
    }
    expectReaderError(.traversalLimitExceeded) {
        _ = try MessageReader(
            segments: [readerBytes([readerStructPointer(data: 2, pointers: 0), 0, 0])],
            options: ReaderOptions(traversalLimitInWords: 1)
        ).rootStruct()
    }

    let recursive = readerBytes([
        readerStructPointer(data: 0, pointers: 1),
        readerStructPointer(data: 0, pointers: 1),
        0,
    ])
    let limited = try MessageReader(
        segments: [recursive], options: ReaderOptions(nestingLimit: 1))
    let root = try limited.rootStruct()
    expectReaderError(.nestingLimitExceeded) { _ = try root.structField(at: 0) }
}

@Test func readerOwnsStorageAndNullBlobsAreEmpty() throws {
    var source = readerBytes([readerStructPointer(data: 1, pointers: 1), 42, 0])
    let message = try MessageReader(segments: [source])
    source = [UInt8](repeating: 0, count: source.count)
    let root = try message.rootStruct()
    #expect(try root.integer(atByte: 0, as: UInt64.self) == 42)
    #expect(try root.dataField(at: 0).bytes.isEmpty)
    #expect(try root.textField(at: 0).string == "")
    #expect(try message.segment(0).word(at: 1) == Word(42))
    expectReaderError(.invalidSegment(1)) { _ = try message.segment(1) }
    expectReaderError(.arithmeticOverflow) {
        _ = try MessageReader(segments: [[0]])
    }
}

// Deterministic malformed-input sweep modeled on fuzz-test.c++: arbitrary
// aligned bytes may throw, but must never trap, loop, or access outside storage.
@Test func arbitraryAlignedSegmentsAreSafe() throws {
    var state: UInt64 = 0x4d59_5df4_d0f3_3173
    for wordCount in 1...64 {
        var words: [UInt64] = []
        for _ in 0..<wordCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            words.append(state)
        }
        let reader = try MessageReader(
            segments: [readerBytes(words)],
            options: ReaderOptions(traversalLimitInWords: 128, nestingLimit: 8)
        )
        _ = try? reader.rootStruct()
        _ = try? reader.rootList()
    }
}
