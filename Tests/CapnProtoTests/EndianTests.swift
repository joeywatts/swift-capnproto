import Testing

@testable import CapnProto

private func expectEndianError(_ expected: CapnProtoError, _ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("expected \(expected)")
    } catch let error as CapnProtoError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func roundTripBoundaries<T: FixedWidthInteger>(_ values: [T]) throws {
    for value in values {
        var bytes = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        try LittleEndian.storeInteger(value, to: &bytes, at: 0)
        #expect(try LittleEndian.loadInteger(T.self, from: bytes, at: 0) == value)
    }
}

// Ported behavior: capnproto c++/src/kj/compat/endian-test.c++ and the primitive
// scalar cases in c++/src/capnp/layout-test.c++ at pinned revision in BASELINES.
@Test func endianAccessIsAlignmentIndependentAndCoversBoundaries() throws {
    var buffer = [UInt8](repeating: 0xaa, count: 19)
    try LittleEndian.storeInteger(UInt64.max, to: &buffer, at: 1)
    #expect(try LittleEndian.loadInteger(UInt64.self, from: buffer, at: 1) == .max)
    try LittleEndian.storeInteger(Int64.min, to: &buffer, at: 3)
    #expect(try LittleEndian.loadInteger(Int64.self, from: buffer, at: 3) == .min)
    try LittleEndian.storeInteger(UInt16(0x1234), to: &buffer, at: 11)
    #expect(Array(buffer[11..<13]) == [0x34, 0x12])
    #expect(
        try LittleEndian.loadInteger(
            UInt32.self, from: [0x78, 0x56, 0x34, 0x12], at: 0) == 0x1234_5678)

    try roundTripBoundaries([Int8.min, Int8.max])
    try roundTripBoundaries([UInt8.min, UInt8.max])
    try roundTripBoundaries([Int16.min, Int16.max])
    try roundTripBoundaries([UInt16.min, UInt16.max])
    try roundTripBoundaries([Int32.min, Int32.max])
    try roundTripBoundaries([UInt32.min, UInt32.max])
    try roundTripBoundaries([Int64.min, Int64.max])
    try roundTripBoundaries([UInt64.min, UInt64.max])

    var word = Word()
    word[bits: 0..<2] = 3
    word[bits: 32..<48] = 0xbeef
    #expect(word[bits: 0..<2] == 3)
    #expect(word[bits: 32..<48] == 0xbeef)
    #expect(signExtend(0x3fff_ffff, width: 30) == -1)
    #expect(signExtend(0x2000_0000, width: 30) == -(1 << 29))

    expectEndianError(.arithmeticOverflow) {
        _ = try LittleEndian.loadInteger(UInt64.self, from: buffer, at: Int.max)
    }
    expectEndianError(.arithmeticOverflow) { _ = try wordsForBytes(Int.max) }
}
