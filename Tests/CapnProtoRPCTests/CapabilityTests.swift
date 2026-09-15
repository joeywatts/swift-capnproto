import CapnProto
import Foundation
import Testing

@testable import CapnProtoRPC

private let testMethod = CapabilityMethodDescriptor(
    interfaceID: 0x1234, methodID: 0, name: "echo",
    paramStructID: 1, resultStructID: 2, isStreaming: false)

private func valueReader(_ value: UInt32 = 0) throws -> StructReader {
    let message = try MessageBuilder()
    let root = try message.initRootStruct(dataWords: 1, pointerCount: 0)
    try root.setInteger(atByte: 0, to: value)
    return try message.asReader().rootStruct()
}

private final class EchoTarget: CapabilityCallTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt32] = []

    func supports(interfaceID: UInt64) -> Bool { interfaceID == testMethod.interfaceID }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        guard method == testMethod else {
            throw CapabilityError.unknownMethod(
                interfaceID: method.interfaceID, methodID: method.methodID)
        }
        let value = try params.integer(atByte: 0, as: UInt32.self)
        lock.withLock { values.append(value) }
        return try valueReader(value + 1)
    }

    var calls: [UInt32] { lock.withLock { values } }
}

// Adapts Capability.Basic and Capability.Inheritance from capability-test.c++ at
// upstream commit 3a82de9b39736a2625f03c93b2b7c50642dd5b25, plus its null/broken cases.
@Test func localNullBrokenAndCastCapabilities() async throws {
    #expect(CapnProtoRPCRuntime.isImplemented)
    let target = EchoTarget()
    let client = CapabilityClient(target: target)
    let cast = try client.cast(to: testMethod.interfaceID)
    let result = try await cast.call(testMethod, params: valueReader(41))
    #expect(try result.integer(atByte: 0, as: UInt32.self) == 42)

    #expect(throws: CapabilityError.unsupportedInterface(99)) {
        _ = try client.cast(to: 99)
    }
    await #expect(throws: CapabilityError.nullCapability) {
        _ = try await CapabilityClient.null.call(testMethod, params: valueReader())
    }
    let exception = RemoteException(kind: .overloaded, reason: "busy", detail: "local-only")
    await #expect(throws: CapabilityError.broken(exception)) {
        _ = try await CapabilityClient.broken(exception).call(
            testMethod, params: valueReader())
    }
}

// Adapts Capability.Pipelining, Rpc.Pipelining, and Rpc.PromiseResolve from
// capability-test.c++/rpc-test.c++ at the pinned upstream commit above.
@Test func promiseQueuesCallsBeforeResolutionAndDispatchesInOrder() async throws {
    let promise = CapabilityClient.makePromise()
    let target = EchoTarget()
    let first = Task { try await promise.client.call(testMethod, params: valueReader(10)) }
    while promise.resolver.pendingCallCount < 1 { await Task.yield() }
    let second = Task { try await promise.client.call(testMethod, params: valueReader(20)) }
    while promise.resolver.pendingCallCount < 2 { await Task.yield() }
    #expect(target.calls.isEmpty)
    try promise.resolver.resolve(to: CapabilityClient(target: target))
    #expect(try await first.value.integer(atByte: 0, as: UInt32.self) == 11)
    #expect(try await second.value.integer(atByte: 0, as: UInt32.self) == 21)
    #expect(target.calls == [10, 20])
    #expect(throws: CapabilityError.promiseAlreadyResolved) {
        try promise.resolver.resolve(to: CapabilityClient(target: target))
    }
}

@Test func promiseRejectsRedirectLoopsAndDoesNotSuspendCancelledCalls() async throws {
    let first = CapabilityClient.makePromise()
    let second = CapabilityClient.makePromise()
    try first.resolver.resolve(to: second.client)
    #expect(throws: CapabilityError.promiseResolutionLoop) {
        try second.resolver.resolve(to: first.client)
    }

    let pending = CapabilityClient.makePromise()
    let task = Task { try await pending.client.call(testMethod, params: valueReader()) }
    await Task.yield()
    task.cancel()
    await #expect(throws: CapabilityError.cancelled) { _ = try await task.value }
}

private actor ManualGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class DelayedResultTarget: CapabilityCallTarget, @unchecked Sendable {
    let gate: ManualGate
    init(gate: ManualGate) { self.gate = gate }
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        await gate.wait()
        return try valueReader(0)
    }
}

@Test func pipelinedCapabilityAcceptsCallsBeforeParentResultArrives() async throws {
    let gate = ManualGate()
    let downstream = EchoTarget()
    let parentClient = CapabilityClient(target: DelayedResultTarget(gate: gate))
    let parent = parentClient.startCall(testMethod, params: try valueReader())
    while !(await gate.isWaiting) { await Task.yield() }

    let pipelined = parent.pipelineCapability { _ in CapabilityClient(target: downstream) }
    let childCall = Task { try await pipelined.call(testMethod, params: valueReader(8)) }
    await Task.yield()
    #expect(downstream.calls.isEmpty)
    await gate.open()

    let result = try await childCall.value
    #expect(try result.integer(atByte: 0, as: UInt32.self) == 9)
    #expect(downstream.calls == [8])
}

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private actor CancellationProbe {
    private(set) var started = false
    private(set) var cancelled = false
    func markStarted() { started = true }
    func markCancelled() { cancelled = true }
}

private final class NeverReturnTarget: CapabilityCallTarget, @unchecked Sendable {
    let probe: CancellationProbe
    init(probe: CancellationProbe) { self.probe = probe }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        await probe.markStarted()
        do {
            try await Task.sleep(for: .seconds(60))
            return try valueReader()
        } catch {
            await probe.markCancelled()
            throw error
        }
    }
}

@Test func abandonedCallCancelsNeverReturningServerWork() async throws {
    let probe = CancellationProbe()
    var call: CapabilityCall? = CapabilityClient(target: NeverReturnTarget(probe: probe))
        .startCall(testMethod, params: try valueReader())
    while !(await probe.started) { await Task.yield() }
    call = nil
    while !(await probe.cancelled) { await Task.yield() }
    #expect(call == nil)
}

// Adapts Rpc.Release, Rpc.ReleaseOnCancel, and Rpc.RetainAndRelease from
// rpc-test.c++ at upstream commit 3a82de9b39736a2625f03c93b2b7c50642dd5b25.
@Test func capabilityTableReleasesExactlyOnceAndReturnsToZero() throws {
    let table = CapabilityTable()
    let counter = ReleaseCounter()
    let id = try table.insert(
        CapabilityClient.null, references: 2, onRelease: { counter.increment() })
    try table.retain(id)
    #expect(table.snapshot == .init(entries: 1, references: 3))
    try table.release(id, count: 2)
    #expect(counter.value == 0)
    try table.release(id)
    #expect(counter.value == 1)
    #expect(table.snapshot == .init(entries: 0, references: 0))
    #expect(throws: CapabilityTableError.unknownID(id)) { try table.release(id) }

    let other = try table.insert(CapabilityClient.null, onRelease: { counter.increment() })
    #expect(try table.lookup(other).tableIndex == nil)
    table.removeAll()
    table.removeAll()
    #expect(counter.value == 2)
    #expect(table.snapshot == .init(entries: 0, references: 0))
}

@Test func connectionDisconnectCancelsOperationsAndEmptiesAllTables() async throws {
    let (transport, peer) = InMemoryRPCTransport.makePair()
    let state = RPCConnectionState()
    let harness = RPCConnectionHarness(transport: transport, state: state)
    let counter = ReleaseCounter()
    let question = try state.beginQuestion(onCancel: { counter.increment() })
    let answer = try state.beginAnswer(onCancel: { counter.increment() })
    _ = try state.imports.insert(CapabilityClient.null, onRelease: { counter.increment() })
    _ = try state.exports.insert(CapabilityClient.null, onRelease: { counter.increment() })
    #expect(question.id == 0)
    #expect(answer.id == 0)

    await harness.disconnect()
    await harness.disconnect()
    #expect(counter.value == 4)
    #expect(
        state.snapshot
            == .init(
                questions: 0, answers: 0, imports: .init(entries: 0, references: 0),
                exports: .init(entries: 0, references: 0), isDisconnected: true))
    #expect(try await peer.receive() == nil)
    #expect(throws: RPCConnectionError.disconnected) { _ = try state.beginQuestion() }
}

@Test func taskCancellationFinishesQuestionExactlyOnce() async throws {
    let state = RPCConnectionState()
    let counter = ReleaseCounter()
    let question = try state.beginQuestion(onCancel: { counter.increment() })
    let task = Task {
        try await question.run {
            try await Task.sleep(for: .seconds(60))
        }
    }
    await Task.yield()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    question.cancel()
    #expect(counter.value == 1)
    #expect(state.snapshot.questions == 0)
}
