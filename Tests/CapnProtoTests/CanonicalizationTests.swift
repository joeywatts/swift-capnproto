import Foundation
import Testing

@testable import CapnProto

private func canonicalBytes(_ words: [UInt64]) -> [UInt8] {
    words.flatMap { value in
        (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
}

// Ported byte vectors: truncation, dense packing, and MSB retention from
// canonicalize-test.c++.
@Test func canonicalizationTruncatesZeroSectionsButRetainsHighBit() throws {
    let input = canonicalBytes([
        0x0000_0002_0000_0000,
        0x1111_1111_1111_1111,
        0x8000_0000_0000_0000,
    ])
    let reader = try MessageReader(segments: [input])
    #expect(reader.isCanonical)
    #expect(try reader.canonicalized() == input)

    let nonTruncated = try MessageReader(segments: [
        canonicalBytes([
            0x0000_0001_0000_0000, 0,
        ])
    ])
    #expect(nonTruncated.isCanonical == false)
    #expect(try nonTruncated.canonicalized() == canonicalBytes([0xffff_fffc]))
}

@Test func nonNullEmptyStructUsesCanonicalMinusOneOffset() throws {
    let message = try MessageBuilder(firstSegmentWords: 2)
    _ = try message.initRootStruct(dataWords: 0, pointerCount: 0)
    #expect(message.segments[0] == canonicalBytes([0xffff_fffc]))
    #expect(try message.asReader().isCanonical)
}

@Test func canonicalizationNormalizesPrimitiveAndBitPadding() throws {
    let bytesWithPadding = canonicalBytes([
        0x0001_0000_0000_0000,
        0x0000_001a_0000_0001,
        0x0000_0000_0103_0201,
    ])
    let byteMessage = try MessageReader(segments: [bytesWithPadding])
    #expect(byteMessage.isCanonical == false)
    #expect(
        try byteMessage.canonicalized()
            == canonicalBytes([
                0x0001_0000_0000_0000,
                0x0000_001a_0000_0001,
                0x0000_0000_0003_0201,
            ]))

    let bitsWithPadding = canonicalBytes([
        0x0001_0000_0000_0000,
        0x0000_0059_0000_0001,
        0x0000_0000_0000_0fee,
    ])
    #expect(
        try MessageReader(segments: [bitsWithPadding]).canonicalized()
            == canonicalBytes([
                0x0001_0000_0000_0000,
                0x0000_0059_0000_0001,
                0x0000_0000_0000_07ee,
            ]))
}

// Ported cases: pointer preorder, gaps, trailing words, and multi-segment
// rejection from canonicalize-test.c++.
@Test func canonicalValidationRequiresDenseSingleSegmentPreorder() throws {
    let gap = try MessageReader(segments: [
        canonicalBytes([
            0x0000_0001_0000_0004, 0, 0x0706_0504_0302_0100,
        ])
    ])
    #expect(gap.isCanonical == false)
    let normalized = try gap.canonicalized()
    #expect(
        normalized
            == canonicalBytes([
                0x0000_0001_0000_0000, 0x0706_0504_0302_0100,
            ]))
    #expect(try MessageReader(segments: [normalized]).isCanonical)

    let multi = try MessageBuilder(firstSegmentWords: 1, allocationStrategy: .fixedSize)
    let root = try multi.initRootStruct(dataWords: 1, pointerCount: 0)
    try root.setInteger(atByte: 0, to: UInt64(7))
    #expect(try multi.asReader().isCanonical == false)
    #expect(try MessageReader(segments: [multi.asReader().canonicalized()]).isCanonical)
}

@Test func canonicalizationHandlesCompositeListsAndIsIdempotent() throws {
    let message = try MessageBuilder(firstSegmentWords: 4, allocationStrategy: .fixedSize)
    let root = try message.initRootStruct(dataWords: 1, pointerCount: 2)
    try root.setInteger(atByte: 0, to: UInt64(44))
    let list = try root.initStructListField(at: 0, count: 2, dataWords: 2, pointerCount: 1)
    try list[0].setInteger(atByte: 0, to: UInt64(11))
    try list[1].setInteger(atByte: 0, to: UInt64(22))
    _ = try list[1].setTextField(at: 0, to: "nested")

    let canonical = try message.asReader().canonicalized()
    let canonicalReader = try MessageReader(segments: [canonical])
    #expect(canonicalReader.isCanonical)
    #expect(try canonicalReader.canonicalized() == canonical)
    #expect(try canonicalReader.canonicalSizeInWords == canonical.count / 8)
    let read = try canonicalReader.rootStruct().listField(at: 0)
    #expect(try read.structElement(at: 1).integer(atByte: 0, as: UInt64.self) == 22)
    #expect(try read.structElement(at: 1).textField(at: 0).string == "nested")
}

@Test func canonicalOutputMatchesPinnedCppForSharedFixturesWhenAvailable() throws {
    guard runCanonicalCapnp(arguments: ["--version"], input: []).status == 0 else { return }
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../InteropFixtures/generated").standardized
    for fixture in [
        "stream.bin", "multi-segment.bin", "defaults.bin", "union.bin",
        "group.bin", "nested-list.bin",
    ] {
        let frame = [UInt8](try Data(contentsOf: directory.appendingPathComponent(fixture)))
        let swift = try MessageFraming.decodePrefix(frame).reader().canonicalized()
        let reference = runCanonicalCapnp(
            arguments: ["convert", "binary:canonical"], input: frame)
        #expect(reference.status == 0)
        #expect(swift == reference.output)
    }
    let packed = [UInt8](try Data(contentsOf: directory.appendingPathComponent("packed.bin")))
    let unpacked = try PackedEncoding.unpack(packed)
    let swiftPacked = try MessageFraming.decodePrefix(unpacked).reader().canonicalized()
    let referencePacked = runCanonicalCapnp(
        arguments: ["convert", "packed:canonical"], input: packed)
    #expect(referencePacked.status == 0)
    #expect(swiftPacked == referencePacked.output)

    let flat = [UInt8](try Data(contentsOf: directory.appendingPathComponent("flat.bin")))
    let swiftFlat = try MessageReader(segments: [flat]).canonicalized()
    let referenceFlat = runCanonicalCapnp(
        arguments: ["convert", "flat:canonical"], input: flat)
    #expect(referenceFlat.status == 0)
    #expect(swiftFlat == referenceFlat.output)
}

private func runCanonicalCapnp(arguments: [String], input: [UInt8]) -> (
    status: Int32, output: [UInt8]
) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["capnp"] + arguments
    let standardInput = Pipe()
    let standardOutput = Pipe()
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = Pipe()
    do {
        try process.run()
        standardInput.fileHandleForWriting.write(Data(input))
        try standardInput.fileHandleForWriting.close()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, [UInt8](output))
    } catch {
        return (-1, [])
    }
}
