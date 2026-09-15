import Testing

@testable import CapnProtoRPC

// Exercises the transport transitions used by Rpc.Basic, Rpc.Cancellation, and
// Rpc.Abort in rpc-test.c++ at upstream commit
// 3a82de9b39736a2625f03c93b2b7c50642dd5b25.
@Test(arguments: 1...16)
func inMemoryTransportFragmentsAtEveryBoundary(fragmentSize: Int) async throws {
    let (sender, receiver) = InMemoryRPCTransport.makePair(
        configuration: .init(maximumBufferedChunks: 32, fragmentSize: fragmentSize))
    let bytes = Array(UInt8(0)..<UInt8(16))
    try await sender.send(bytes)
    var received: [UInt8] = []
    while received.count < bytes.count {
        received.append(contentsOf: try #require(try await receiver.receive()))
    }
    #expect(received == bytes)
    await sender.close()
    #expect(try await receiver.receive() == nil)
}

@Test func inMemoryTransportCoalescesWritesAndRecordsTrace() async throws {
    let trace = TransportTrace()
    let (first, second) = InMemoryRPCTransport.makePair(
        configuration: .init(coalesceWrites: true), trace: trace)
    try await first.send([1, 2])
    try await first.send([3, 4])
    #expect(try await second.receive() == [1, 2, 3, 4])
    let events = await trace.snapshot
    #expect(events.map(\.direction) == [.send, .send, .receive])
    #expect(events.map(\.byteCount) == [2, 2, 4])
}

@Test func transportFaultsAndDisconnectResumeAllWaiters() async throws {
    let (failing, peer) = InMemoryRPCTransport.makePair(
        configuration: .init(failSendAt: 0))
    await #expect(throws: RPCTransportError.injected(operation: 0)) {
        try await failing.send([1])
    }
    await #expect(throws: RPCTransportError.injected(operation: 0)) {
        _ = try await peer.receive()
    }

    let (first, second) = InMemoryRPCTransport.makePair()
    let waiter = Task { try await second.receive() }
    await Task.yield()
    await first.close()
    #expect(try await waiter.value == nil)
}

@Test func boundedTransportAppliesAndReleasesBackpressure() async throws {
    let (sender, receiver) = InMemoryRPCTransport.makePair(
        configuration: .init(maximumBufferedChunks: 1))
    try await sender.send([1])
    let blocked = Task { try await sender.send([2]) }
    await Task.yield()
    #expect(try await receiver.receive() == [1])
    try await blocked.value
    #expect(try await receiver.receive() == [2])
    await sender.close()
}

@Test func receiveFaultAndInjectedEOFAreDeterministic() async throws {
    let (_, failureReceiver) = InMemoryRPCTransport.makePair(
        configuration: .init(failReceiveAt: 0))
    await #expect(throws: RPCTransportError.injected(operation: 0)) {
        _ = try await failureReceiver.receive()
    }

    let (_, eofReceiver) = InMemoryRPCTransport.makePair(
        configuration: .init(eofReceiveAt: 0))
    #expect(try await eofReceiver.receive() == nil)
    #expect(try await eofReceiver.receive() == nil)
}

@Test(arguments: 0...3)
func sendErrorsCanBeInjectedAtEveryScriptedTransition(faultAt: Int) async throws {
    let (sender, receiver) = InMemoryRPCTransport.makePair(
        configuration: .init(maximumBufferedChunks: 8, failSendAt: faultAt))
    for operation in 0..<faultAt {
        try await sender.send([UInt8(operation)])
        #expect(try await receiver.receive() == [UInt8(operation)])
    }
    await #expect(throws: RPCTransportError.injected(operation: faultAt)) {
        try await sender.send([255])
    }
    await #expect(throws: RPCTransportError.injected(operation: faultAt)) {
        _ = try await receiver.receive()
    }
}

@Test(arguments: 0...3)
func receiveErrorsCanBeInjectedAtEveryScriptedTransition(faultAt: Int) async throws {
    let (sender, receiver) = InMemoryRPCTransport.makePair(
        configuration: .init(maximumBufferedChunks: 8, failReceiveAt: faultAt))
    for operation in 0...faultAt { try await sender.send([UInt8(operation)]) }
    for operation in 0..<faultAt {
        #expect(try await receiver.receive() == [UInt8(operation)])
    }
    await #expect(throws: RPCTransportError.injected(operation: faultAt)) {
        _ = try await receiver.receive()
    }
}

@Test func cancellingBlockedTransportOperationsRemovesContinuations() async throws {
    let (sender, receiver) = InMemoryRPCTransport.makePair(
        configuration: .init(maximumBufferedChunks: 1))
    let blockedReceive = Task { try await receiver.receive() }
    while await receiver.pendingOperationCount == 0 { await Task.yield() }
    blockedReceive.cancel()
    await #expect(throws: CancellationError.self) { _ = try await blockedReceive.value }
    while await receiver.pendingOperationCount != 0 { await Task.yield() }

    try await sender.send([1])
    let blockedSend = Task { try await sender.send([2]) }
    while await sender.pendingOperationCount == 0 { await Task.yield() }
    blockedSend.cancel()
    await #expect(throws: CancellationError.self) { try await blockedSend.value }
    while await sender.pendingOperationCount != 0 { await Task.yield() }
    #expect(try await receiver.receive() == [1])
    await sender.close()
}
