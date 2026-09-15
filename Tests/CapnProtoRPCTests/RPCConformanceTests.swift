import CapnProto
import Testing

@testable import CapnProtoRPC

private func transcriptMessage(_ configure: (Message.Builder) throws -> Void) throws -> [UInt8] {
    let message = try MessageBuilder()
    try configure(try Message.initRoot(in: message))
    return try message.framedBytes
}

// Deterministic transcript coverage for bootstrap/finish and randomized legal
// ID sequences, adapted from rpc-test.c++ at pinned commit
// 3a82de9b39736a2625f03c93b2b7c50642dd5b25.
@Test func deterministicTranscriptReplayChecksEveryTableTransition() throws {
    let bootstrap = try transcriptMessage {
        try $0.initBootstrap().setQuestionId(12)
    }
    let finish = try transcriptMessage {
        let value = try $0.initFinish()
        try value.setQuestionId(12)
        try value.setReleaseResultCaps(true)
    }
    var afterBootstrap = RPCWireValidationState()
    afterBootstrap.inboundQuestions = [12]
    let result = try RPCTranscriptRunner.replay([
        RPCTranscriptEntry(bytes: bootstrap, expectedState: afterBootstrap),
        RPCTranscriptEntry(bytes: finish, expectedState: RPCWireValidationState()),
    ])
    #expect(result.states.count == 2)
    #expect(result.finalState == RPCWireValidationState())
}

@Test func randomizedLegalTranscriptsReturnAllQuestionTablesToZero() throws {
    var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
    func next() -> UInt32 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt32(truncatingIfNeeded: seed >> 16)
    }
    for _ in 0..<100 {
        var ids = Set<UInt32>()
        while ids.count < 32 { ids.insert(next()) }
        var entries: [RPCTranscriptEntry] = []
        for id in ids.sorted() {
            entries.append(
                RPCTranscriptEntry(
                    bytes: try transcriptMessage {
                        try $0.initBootstrap().setQuestionId(id)
                    }))
        }
        for id in ids.sorted().reversed() {
            entries.append(
                RPCTranscriptEntry(
                    bytes: try transcriptMessage {
                        let finish = try $0.initFinish()
                        try finish.setQuestionId(id)
                        try finish.setReleaseResultCaps(true)
                    }))
        }
        #expect(try RPCTranscriptRunner.replay(entries).finalState.inboundQuestions.isEmpty)
    }
}

@Test func transcriptLimitsRejectLargeAndDeepInputsWithoutMutation() throws {
    let bytes = try transcriptMessage { try $0.initBootstrap().setQuestionId(1) }
    #expect(throws: RPCProtocolError.messageTooLarge) {
        _ = try RPCTranscriptRunner.replay(
            [RPCTranscriptEntry(bytes: bytes)], maximumMessageWords: 1)
    }
}
