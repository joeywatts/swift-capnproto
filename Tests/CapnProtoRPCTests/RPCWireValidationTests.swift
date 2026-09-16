import CapnProto
import Testing

@testable import CapnProtoRPC

private func rpcBytes(_ configure: (Message.Builder) throws -> Void) throws -> [UInt8] {
    let message = try MessageBuilder()
    let root = try Message.initRoot(in: message)
    try configure(root)
    return try message.framedBytes
}

@Test func validatorAppliesQuestionTableLimitTransactionally() throws {
    var state = RPCWireValidationState()
    let first = try RPCWireValidator.decode(
        rpcBytes { root in try root.initBootstrap().setQuestionId(1) })
    try RPCWireValidator.validate(
        first, state: &state,
        limits: RPCValidationLimits(maximumQuestions: 1))
    let before = state
    let second = try RPCWireValidator.decode(
        rpcBytes { root in try root.initBootstrap().setQuestionId(2) })
    #expect(throws: RPCProtocolError.tableLimitExceeded) {
        try RPCWireValidator.validate(
            second, state: &state,
            limits: RPCValidationLimits(maximumQuestions: 1))
    }
    #expect(state == before)
}

// Ports the malformed-message/table-transition boundary exercised throughout
// rpc-test.c++ at pinned commit 3a82de9b39736a2625f03c93b2b7c50642dd5b25.
@Test func generatedRPCSchemaRoundTripsAndRejectsMalformedVariantsTransactionally() throws {
    let bytes = try rpcBytes { root in
        let bootstrap = try root.initBootstrap()
        try bootstrap.setQuestionId(7)
    }
    let decoded = try RPCWireValidator.decode(bytes)
    guard case .bootstrap(let bootstrap) = try decoded.which else {
        Issue.record("expected bootstrap")
        return
    }
    #expect(try bootstrap.questionId == 7)

    let copy = try MessageBuilder()
    let copyRoot = try copy.initRootStruct(dataWords: 1, pointerCount: 1)
    try copyRoot.copyContent(from: decoded.raw)
    #expect(try copy.framedBytes == bytes)

    var state = RPCWireValidationState()
    try RPCWireValidator.validate(decoded, state: &state)
    #expect(state.inboundQuestions == [7])
    let unchanged = state
    #expect(throws: RPCProtocolError.duplicateQuestion(7)) {
        try RPCWireValidator.validate(decoded, state: &state)
    }
    #expect(state == unchanged)

    var corrupt = bytes
    corrupt.removeLast()
    #expect(throws: RPCProtocolError.self) { _ = try RPCWireValidator.decode(corrupt) }

    let unknown = try rpcBytes { try $0.setUnknownDiscriminant(99) }
    let unknownReader = try RPCWireValidator.decode(unknown)
    #expect(throws: RPCProtocolError.unknownMessageVariant(99)) {
        try RPCWireValidator.validate(unknownReader, state: &state)
    }
}

@Test func validatorChecksTargetsReturnsReleasesAndEmbargoIDsBeforeMutation() throws {
    var state = RPCWireValidationState()
    state.exports = [3]
    state.outboundQuestions = [8]

    let call = try rpcBytes { root in
        let value = try root.initCall()
        try value.setQuestionId(4)
        try value.initTarget().setImportedCap(3)
        _ = try value.initParams()
    }
    try RPCWireValidator.validate(try RPCWireValidator.decode(call), state: &state)
    #expect(state.inboundQuestions == [4])

    let result = try rpcBytes { root in
        let value = try root.initReturn()
        try value.setAnswerId(8)
        try value.setCanceled()
    }
    try RPCWireValidator.validate(try RPCWireValidator.decode(result), state: &state)
    #expect(state.returnedQuestions == [8])

    let release = try rpcBytes { root in
        let value = try root.initRelease()
        try value.setId(3)
        try value.setReferenceCount(0)
    }
    let before = state
    #expect(throws: RPCProtocolError.invalidReferenceCount) {
        try RPCWireValidator.validate(try RPCWireValidator.decode(release), state: &state)
    }
    #expect(state == before)
}

@Test func validatorAcceptsTailCallsAndLateCancellationReturns() throws {
    var state = RPCWireValidationState()
    state.outboundQuestions = [1, 2]
    state.inboundQuestions = [1]
    let tail = try rpcBytes { root in
        let value = try root.initReturn()
        try value.setAnswerId(2)
        try value.setTakeFromOtherQuestion(1)
    }
    try RPCWireValidator.validate(try RPCWireValidator.decode(tail), state: &state)
    #expect(state.returnedQuestions == [2])

    state.outboundQuestions.remove(1)
    state.cancelledOutboundQuestions.insert(1)
    let late = try rpcBytes { root in
        let value = try root.initReturn()
        try value.setAnswerId(1)
        try value.setCanceled()
    }
    try RPCWireValidator.validate(try RPCWireValidator.decode(late), state: &state)
    #expect(state.cancelledOutboundQuestions.isEmpty)
}

@Test func validatorAcceptsOneResolveAfterAnUnresolvedPromiseWasReleased() throws {
    var state = RPCWireValidationState()
    state.releasedPromiseImports = [12]
    let bytes = try rpcBytes { root in
        let resolve = try root.initResolve()
        try resolve.setPromiseId(12)
        let exception = try resolve.initException()
        try exception.setReason("resolved after release")
    }
    let message = try RPCWireValidator.decode(bytes)
    try RPCWireValidator.validate(message, state: &state)
    #expect(state.releasedPromiseImports.isEmpty)
    #expect(throws: RPCProtocolError.unknownCapability(12)) {
        try RPCWireValidator.validate(message, state: &state)
    }
}
