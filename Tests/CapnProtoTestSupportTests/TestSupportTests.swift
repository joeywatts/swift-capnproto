import Foundation
import Testing

@testable import CapnProtoTestSupport

@Test func hexRoundTripAndErrors() throws {
    let bytes = try Hex.decode("00 ff_10\n7a")
    #expect(bytes == [0, 255, 16, 122])
    #expect(Hex.encode(bytes) == "00ff107a")
    #expect(throws: HexError.oddDigitCount) { try Hex.decode("0") }
    #expect(throws: HexError.invalidDigit("g")) { try Hex.decode("0g") }
}

@Test func wordsAreComparedInWireByteOrder() {
    let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    #expect(WordAssertions.littleEndianWords(bytes) == [0x0807_0605_0403_0201])
    #expect(
        WordAssertions.firstMismatch(expected: [0x0807_0605_0403_0201], actualBytes: bytes) == nil)
    #expect(WordAssertions.firstMismatch(expected: [0], actualBytes: bytes)?.index == 0)
}

@Test func seededPropertyFailureReproducesExactly() {
    let failure = DeterministicProperty.check(seed: 0xc0ff_ee, iterations: 100) { value in
        !value.isMultiple(of: 7)
    }
    #expect(failure != nil)
    if let failure {
        #expect(DeterministicProperty.reproduce(failure) == failure.value)
        #expect(failure.seed == 0xc0ff_ee)
    }
}

@Test func subprocessCapturesBothStreamsAndStatus() throws {
    let result = try Subprocess.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf output; printf error >&2; exit 7"]
    )
    #expect(result.status == 7)
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "output")
    #expect(String(decoding: result.standardError, as: UTF8.self) == "error")
}

@Test func fuzzParsersAreTotalForDeterministicArbitraryInput() {
    var generator = SplitMix64(seed: 0x5eed)
    for size in 0..<512 {
        let bytes = (0..<size).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        _ = MessageFuzzTarget.consume(bytes)
        _ = PackedFuzzTarget.consume(bytes)
    }
}

@Test func upstreamGeneratedCorpusIsAcceptedWithoutCrashing() throws {
    let tests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let corpus = tests.appending(path: "InteropFixtures/generated")
    let files = try FileManager.default.contentsOfDirectory(
        at: corpus, includingPropertiesForKeys: nil)
    #expect(files.count == 8)
    for file in files {
        let bytes = [UInt8](try Data(contentsOf: file))
        _ = MessageFuzzTarget.consume(bytes)
        _ = PackedFuzzTarget.consume(bytes)
    }
}
