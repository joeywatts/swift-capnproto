import Foundation
import Testing

@testable import CapnProto

private func words(_ values: [UInt64]) -> [UInt8] {
    values.flatMap { value in
        (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
}

// Ported vectors: zero words, sparse tags, and literal runs from
// serialize-packed-test.c++.
@Test(arguments: [
    ([], []),
    (words([0]), [0, 0]),
    ([0, 0, 12, 0, 0, 34, 0, 0], [0x24, 12, 34]),
    ([1, 3, 2, 4, 5, 7, 6, 8], [0xff, 1, 3, 2, 4, 5, 7, 6, 8, 0]),
    (
        [0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 2, 4, 5, 7, 6, 8],
        [0, 0, 0xff, 1, 3, 2, 4, 5, 7, 6, 8, 0]
    ),
    (
        [0, 0, 12, 0, 0, 34, 0, 0, 1, 3, 2, 4, 5, 7, 6, 8],
        [0x24, 12, 34, 0xff, 1, 3, 2, 4, 5, 7, 6, 8, 0]
    ),
    (
        [1, 3, 2, 4, 5, 7, 6, 8, 8, 6, 7, 4, 5, 2, 3, 1],
        [0xff, 1, 3, 2, 4, 5, 7, 6, 8, 1, 8, 6, 7, 4, 5, 2, 3, 1]
    ),
    (
        [
            1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
            1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
            0, 2, 4, 0, 9, 0, 5, 1,
        ],
        [
            0xff, 1, 2, 3, 4, 5, 6, 7, 8, 3,
            1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
            1, 2, 3, 4, 5, 6, 7, 8, 0xd6, 2, 4, 9, 5, 1,
        ]
    ),
    (
        [
            1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
            6, 2, 4, 3, 9, 0, 5, 1, 1, 2, 3, 4, 5, 6, 7, 8,
            0, 2, 4, 0, 9, 0, 5, 1,
        ],
        [
            0xff, 1, 2, 3, 4, 5, 6, 7, 8, 3,
            1, 2, 3, 4, 5, 6, 7, 8, 6, 2, 4, 3, 9, 0, 5, 1,
            1, 2, 3, 4, 5, 6, 7, 8, 0xd6, 2, 4, 9, 5, 1,
        ]
    ),
    (
        [
            8, 0, 100, 6, 0, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 1, 0, 2, 0, 3, 1,
        ],
        [0xed, 8, 100, 6, 1, 1, 2, 0, 2, 0xd4, 1, 2, 3, 1]
    ),
])
func packedReferenceVectors(unpacked: [UInt8], packed: [UInt8]) throws {
    #expect(try PackedEncoding.pack(unpacked) == packed)
    #expect(try PackedEncoding.unpack(packed) == unpacked)
}

@Test func encoderAndDecoderAcceptEveryInputSplit() throws {
    let unpacked = words([
        0, 0, 0x0807_0605_0403_0201, 0x100f_0e0d_0c0b_0a09,
        0x0000_0000_0000_0001, 0,
    ])
    let packed = try PackedEncoding.pack(unpacked)
    for split in 0...unpacked.count {
        var encoder = PackedEncoder()
        var result = try encoder.append(Array(unpacked[..<split]))
        result += try encoder.append(Array(unpacked[split...]))
        result += try encoder.finish()
        #expect(result == packed)
    }
    for split in 0...packed.count {
        var decoder = try PackedDecoder()
        var result = try decoder.append(Array(packed[..<split]))
        result += try decoder.append(Array(packed[split...]))
        result += try decoder.finish()
        #expect(result == unpacked)
    }
}

@Test func packedDecoderRejectsTruncationAndBoundsExpansion() throws {
    #expect(throws: CapnProtoError.invalidPackedData) {
        try PackedEncoding.unpack([0])
    }
    #expect(throws: CapnProtoError.invalidPackedData) {
        try PackedEncoding.unpack([0xff, 1, 2])
    }
    #expect(throws: CapnProtoError.packedOutputLimitExceeded) {
        try PackedEncoding.unpack([0, 255], maximumOutputBytes: 8)
    }
    #expect(throws: CapnProtoError.invalidPackedData) {
        try PackedEncoding.pack([1, 2, 3])
    }
}

@Test func packedMessagesCrossDecodeWithPinnedCppWhenAvailable() throws {
    guard runPackedCapnp(arguments: ["--version"], input: []).status == 0 else { return }
    var state: UInt64 = 0x1234_5678
    var unpacked = [UInt8]()
    for _ in 0..<100 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        unpacked += words([state, state & 7 == 0 ? 0 : ~state])
    }
    // A framed byte stream is required by capnp convert; use randomized data as
    // a data field so the reference tool also validates the frame.
    let message = try MessageBuilder(firstSegmentWords: 512)
    let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
    _ = try root.setDataField(at: 0, to: unpacked)
    let frame = try message.framedBytes
    let referencePacked = runPackedCapnp(arguments: ["convert", "binary:packed"], input: frame)
    #expect(
        referencePacked.status == 0,
        Comment(rawValue: String(decoding: referencePacked.error, as: UTF8.self)))
    #expect(try PackedEncoding.unpack(referencePacked.output) == frame)
    #expect(try PackedEncoding.pack(frame) == referencePacked.output)

    let referenceUnpacked = runPackedCapnp(
        arguments: ["convert", "packed:binary"], input: try PackedEncoding.pack(frame))
    #expect(
        referenceUnpacked.status == 0,
        Comment(rawValue: String(decoding: referenceUnpacked.error, as: UTF8.self)))
    #expect(referenceUnpacked.output == frame)
}

private func runPackedCapnp(arguments: [String], input: [UInt8]) -> (
    status: Int32, output: [UInt8], error: [UInt8]
) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["capnp"] + arguments
    let standardInput = Pipe()
    let standardOutput = Pipe()
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    let standardError = Pipe()
    process.standardError = standardError
    do {
        try process.run()
        standardInput.fileHandleForWriting.write(Data(input))
        try standardInput.fileHandleForWriting.close()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, [UInt8](output), [UInt8](error))
    } catch {
        return (-1, [], [])
    }
}
