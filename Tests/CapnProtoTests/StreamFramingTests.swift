import Foundation
import Testing

@testable import CapnProto

// Ported behavior: segment-table and round-trip cases from serialize-test.c++.
@Test func streamFrameRoundTripsSingleAndMultipleSegments() throws {
    for firstSegmentWords in [2, 64] {
        let message = try MessageBuilder(
            firstSegmentWords: firstSegmentWords, allocationStrategy: .fixedSize)
        let root = try message.initRootStruct(dataWords: 1, pointerCount: 1)
        try root.setInteger(atByte: 0, to: UInt64(1234))
        _ = try root.setTextField(at: 0, to: "stream framing")
        let slices = try message.framedSegments
        #expect(slices.count == message.segmentCount + 1)
        let decoded = try MessageFraming.decodePrefix(slices.flatMap { $0 })
        #expect(decoded.byteCount == slices.reduce(0) { $0 + $1.count })
        let read = try decoded.reader().rootStruct()
        #expect(try read.integer(atByte: 0, as: UInt64.self) == 1234)
        #expect(try read.textField(at: 0).string == "stream framing")
    }
}

// Ported behavior: concatenation and partial reads from serialize-test.c++ and
// serialize-async-test.c++. Every possible single split point is exercised.
@Test func incrementalDecoderAcceptsEverySplitAndConcatenatedMessages() throws {
    let first = try MessageBuilder(firstSegmentWords: 4)
    _ = try first.setRootText("first")
    let second = try MessageBuilder(firstSegmentWords: 4)
    _ = try second.setRootText("second")
    let bytes = try first.framedBytes + second.framedBytes

    for split in 0...bytes.count {
        var decoder = StreamMessageDecoder()
        var messages = try decoder.append(Array(bytes[..<split]))
        messages += try decoder.append(Array(bytes[split...]))
        try decoder.finish()
        #expect(messages.count == 2)
        #expect(try messages[0].reader().rootText().string == "first")
        #expect(try messages[1].reader().rootText().string == "second")
    }
    #expect(try MessageFraming.decodeAll(bytes).count == 2)
}

@Test func framingRejectsMalformedTablesAndEnforcesLimits() throws {
    #expect(throws: CapnProtoError.incompleteFrame) {
        try MessageFraming.decodePrefix([0, 0, 0])
    }
    #expect(throws: CapnProtoError.frameTooLarge) {
        try MessageFraming.decodePrefix([1, 0, 0, 0], options: .init(maximumSegments: 1))
    }
    #expect(throws: CapnProtoError.invalidFrame) {
        try MessageFraming.decodePrefix([
            1, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 1, 0, 0, 0,
        ])
    }
    #expect(throws: CapnProtoError.frameTooLarge) {
        try MessageFraming.decodePrefix(
            [0, 0, 0, 0, 2, 0, 0, 0], options: .init(maximumTotalWords: 1))
    }
}

private struct AsyncChunks: AsyncSequence {
    typealias Element = [UInt8]
    let chunks: [[UInt8]]

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: IndexingIterator<[[UInt8]]>
        mutating func next() async -> [UInt8]? { iterator.next() }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: chunks.makeIterator())
    }
}

@Test func asyncChunkAdapterHandlesByteSizedChunks() async throws {
    let message = try MessageBuilder(firstSegmentWords: 2)
    _ = try message.setRootText("async")
    let chunks = try message.framedBytes.map { [$0] }
    let decoded = try await MessageFraming.decode(AsyncChunks(chunks: chunks))
    #expect(decoded.count == 1)
    #expect(try decoded[0].reader().rootText().string == "async")
}

// Swift<->C++ stream verification. The pinned development oracle is optional
// for normal Swift-only test runs and mandatory in the Nix/interop job.
@Test func pinnedCppOracleCrossDecodesStreamsWhenAvailable() throws {
    guard runCapnp(arguments: ["--version"], input: []).status == 0 else { return }
    let message = try MessageBuilder(firstSegmentWords: 3, allocationStrategy: .fixedSize)
    let root = try message.initRootStruct(dataWords: 1, pointerCount: 2)
    try root.setInteger(atByte: 0, to: UInt64(321))
    _ = try root.setTextField(at: 0, to: "swift")
    let numbers = try root.initListField(at: 1, elementSize: .twoBytes, count: 2)
    try numbers.setInteger(at: 0, to: UInt16(4))
    try numbers.setInteger(at: 1, to: UInt16(5))
    let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../InteropFixtures/milestone2.capnp").standardized.path

    let decoded = runCapnp(
        arguments: ["decode", schema, "BuildInterop"], input: try message.framedBytes)
    #expect(decoded.status == 0)
    let normalized = String(decoding: decoded.output, as: UTF8.self)
    #expect(normalized.contains("value = 321"))
    #expect(normalized.contains("text = \"swift\""))
    #expect(normalized.contains("numbers = [4, 5]"))

    let encoded = runCapnp(
        arguments: ["encode", schema, "BuildInterop"],
        input: Array("(value = 654, text = \"cpp\", numbers = [8, 9])".utf8))
    #expect(encoded.status == 0)
    let cpp = try MessageFraming.decodePrefix(encoded.output).reader().rootStruct()
    #expect(try cpp.integer(atByte: 0, as: UInt64.self) == 654)
    #expect(try cpp.textField(at: 0).string == "cpp")
    #expect(try cpp.listField(at: 1).integer(at: 1, as: UInt16.self) == 9)
}

private func runCapnp(arguments: [String], input: [UInt8]) -> (status: Int32, output: [UInt8]) {
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
