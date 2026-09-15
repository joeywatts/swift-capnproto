import Foundation
import Testing

@testable import CapnProto

private func farBytes(_ words: [UInt64]) -> [UInt8] {
    words.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> UInt64($0 * 8)) } }
}

private func farStructPointer(offset: Int32 = 0, data: UInt16, pointers: UInt16) -> UInt64 {
    (UInt64(UInt32(bitPattern: offset)) & 0x3fff_ffff) << 2
        | UInt64(data) << 32 | UInt64(pointers) << 48
}

private func farPointer(double: Bool = false, landing: UInt32, segment: UInt32) -> UInt64 {
    2 | (double ? 4 : 0) | UInt64(landing & 0x1fff_ffff) << 3 | UInt64(segment) << 32
}

private func framedSegments(_ data: Data) throws -> [[UInt8]] {
    let bytes = [UInt8](data)
    let count = Int(try LittleEndian.loadInteger(UInt32.self, from: bytes, at: 0)) + 1
    let tableEntries = count + 1
    let tableBytes = ((tableEntries + 1) & ~1) * 4
    var cursor = tableBytes
    var result: [[UInt8]] = []
    for index in 0..<count {
        let words = Int(try LittleEndian.loadInteger(UInt32.self, from: bytes, at: 4 + index * 4))
        let byteCount = words * 8
        result.append(Array(bytes[cursor..<(cursor + byteCount)]))
        cursor += byteCount
    }
    return result
}

private func expectFarError(_ expected: CapnProtoError, _ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("expected \(expected)")
    } catch let error as CapnProtoError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// Ported behavior: single-far, double-far, and malformed landing-pad cases from
// capnproto c++/src/capnp/layout-test.c++ at the revision in BASELINES.
@Test func farAndDoubleFarPointers() throws {
    let single = try MessageReader(segments: [
        farBytes([farPointer(landing: 0, segment: 1)]),
        farBytes([farStructPointer(data: 1, pointers: 0), 0xfeed_face]),
    ])
    #expect(try single.rootStruct().integer(atByte: 0, as: UInt64.self) == 0xfeed_face)
    expectFarError(.traversalLimitExceeded) {
        _ = try MessageReader(
            segments: [
                farBytes([farPointer(landing: 0, segment: 1)]),
                farBytes([farStructPointer(data: 1, pointers: 0), 0xfeed_face]),
            ],
            options: ReaderOptions(traversalLimitInWords: 0)
        ).rootStruct()
    }

    let double = try MessageReader(segments: [
        farBytes([farPointer(double: true, landing: 0, segment: 1)]),
        farBytes([
            farPointer(landing: 0, segment: 2), farStructPointer(data: 1, pointers: 0),
        ]),
        farBytes([0xcafe_babe]),
    ])
    #expect(try double.rootStruct().integer(atByte: 0, as: UInt64.self) == 0xcafe_babe)

    expectFarError(.invalidFarPointer) {
        _ = try MessageReader(segments: [farBytes([farPointer(landing: 0, segment: 7)])])
            .rootStruct()
    }
    expectFarError(.invalidFarPointer) {
        _ = try MessageReader(segments: [
            farBytes([farPointer(double: true, landing: 0, segment: 1)]),
            farBytes([farPointer(landing: 0, segment: 0)]),
        ]).rootStruct()
    }
    expectFarError(.invalidFarPointer) {
        _ = try MessageReader(segments: [
            farBytes([farPointer(double: true, landing: 0, segment: 1)]),
            farBytes([
                farPointer(landing: 0, segment: 0),
                farStructPointer(offset: 1, data: 0, pointers: 0),
            ]),
        ]).rootStruct()
    }
}

// C++-produced multi-segment fixture from encoding-test.c++ provenance. Framing
// is split in test code because stream framing belongs to Milestone 2.
@Test func decodesPinnedCppMultiSegmentFixture() throws {
    let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fixture =
        testDirectory
        .appendingPathComponent("../InteropFixtures/generated/multi-segment.bin")
        .standardizedFileURL
    let segments = try framedSegments(Data(contentsOf: fixture))
    #expect(segments.count > 1)
    let root = try MessageReader(segments: segments).rootStruct()
    #expect(try root.textField(at: 0).string == "multi-segment-padding-for-a-second-allocation")
    #expect(try root.textField(at: 2).string == "union")
    let nested = try root.listField(at: 3)
    #expect(try nested.pointerElement(at: 0).integer(at: 1, as: UInt16.self) == 2)
}
