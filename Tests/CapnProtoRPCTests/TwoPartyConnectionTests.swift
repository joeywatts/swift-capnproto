import CapnProto
import Foundation
import Testing

@testable import CapnProtoRPC

private let wireMethod = CapabilityMethodDescriptor(
    interfaceID: 0xfeed, methodID: 2, name: "increment",
    paramStructID: 1, resultStructID: 2, isStreaming: false)

private func wireValue(_ value: UInt32) throws -> StructReader {
    let message = try MessageBuilder()
    let root = try message.initRootStruct(dataWords: 1, pointerCount: 0)
    try root.setInteger(atByte: 0, to: value)
    return try message.asReader().rootStruct()
}

private final class SwitchableFailTransport: RPCMessageTransport, @unchecked Sendable {
    private let base: any RPCMessageTransport
    private let lock = NSLock()
    private var shouldFailCall = false

    init(_ base: any RPCMessageTransport) { self.base = base }
    func failNextCall() { lock.withLock { shouldFailCall = true } }
    func send(_ bytes: [UInt8]) async throws {
        let isCall: Bool
        if let message = try? RPCWireValidator.decode(bytes),
            case .call = try? message.which
        {
            isCall = true
        } else {
            isCall = false
        }
        let fail = lock.withLock {
            guard shouldFailCall, isCall else { return false }
            shouldFailCall = false
            return true
        }
        if fail { throw RPCTransportError.injected(operation: 0) }
        try await base.send(bytes)
    }
    func receive() async throws -> [UInt8]? { try await base.receive() }
    func close() async { await base.close() }
}

private final class ReceiverAnswerProbeTransport: RPCMessageTransport, @unchecked Sendable {
    private let base: any RPCMessageTransport
    private let lock = NSLock()
    private var observedReceiverAnswer = false

    init(_ base: any RPCMessageTransport) { self.base = base }

    func send(_ bytes: [UInt8]) async throws {
        if let message = try? RPCWireValidator.decode(bytes),
            case .call(let call) = try? message.which,
            let descriptor = try? call.params.capTable.first,
            case .receiverAnswer = try? descriptor.which
        {
            lock.withLock { observedReceiverAnswer = true }
        }
        try await base.send(bytes)
    }

    func receive() async throws -> [UInt8]? { try await base.receive() }
    func close() async { await base.close() }
    var observed: Bool { lock.withLock { observedReceiverAnswer } }
}

private final class WireService: CapabilityCallTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var receivedValues: [UInt32] = []

    func supports(interfaceID: UInt64) -> Bool { interfaceID == wireMethod.interfaceID }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        guard method.interfaceID == wireMethod.interfaceID, method.methodID == wireMethod.methodID
        else {
            throw CapabilityError.unknownMethod(
                interfaceID: method.interfaceID, methodID: method.methodID)
        }
        let value = try params.integer(atByte: 0, as: UInt32.self)
        lock.withLock { receivedValues.append(value) }
        return try wireValue(value + 1)
    }

    var values: [UInt32] { lock.withLock { receivedValues } }
}

// Adapts Rpc.Pipelining, Rpc.PromiseResolve, and call-order cases from
// rpc-test.c++ at the pinned upstream commit above.
@Test func promisedAnswerCallsAreSentBeforeBootstrapResolutionAndStayOrdered() async throws {
    let service = WireService()
    let (a, b) = InMemoryRPCTransport.makePair(configuration: .init(fragmentSize: 1))
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: service))
    await client.start()
    await server.start()

    let bootstrap = try await client.beginBootstrap()
    let pipeline = bootstrap.pipeline()
    let first = Task { try await pipeline.call(wireMethod, params: wireValue(10)) }
    while (await client.snapshot).questions < 2 { await Task.yield() }
    let second = Task { try await pipeline.call(wireMethod, params: wireValue(20)) }
    while (await client.snapshot).questions < 3 { await Task.yield() }
    let remote = try await bootstrap.response()
    _ = remote
    #expect(try await first.value.integer(atByte: 0, as: UInt32.self) == 11)
    #expect(try await second.value.integer(atByte: 0, as: UInt32.self) == 21)
    #expect(service.values == [10, 20])
    await client.close()
    await server.close()
}

// Adapts Rpc.Bootstrap, Rpc.Basic, Rpc.Exception, Rpc.Finish, and Rpc.Release
// from rpc-test.c++ at pinned commit 3a82de9b39736a2625f03c93b2b7c50642dd5b25.
@Test func twoPartyBootstrapCallExceptionFinishAndReleaseRoundTrip() async throws {
    let (clientTransport, serverTransport) = InMemoryRPCTransport.makePair(
        configuration: .init(fragmentSize: 3))
    let client = TwoPartyRPCConnection(side: .client, transport: clientTransport)
    let server = TwoPartyRPCConnection(
        side: .server, transport: serverTransport,
        bootstrap: CapabilityClient(target: WireService()))
    await client.start()
    await server.start()

    var remote: CapabilityClient? = try await client.bootstrap()
    let result = try await remote!.call(wireMethod, params: wireValue(41))
    #expect(try result.integer(atByte: 0, as: UInt32.self) == 42)

    let unknown = CapabilityMethodDescriptor(
        interfaceID: wireMethod.interfaceID, methodID: 99, name: "missing",
        paramStructID: 0, resultStructID: 0, isStreaming: false)
    await #expect(
        throws: CapabilityError.broken(
            RemoteException(
                kind: .failed,
                reason: "unknownMethod(interfaceID: 65261, methodID: 99)"))
    ) {
        _ = try await remote!.call(unknown, params: wireValue(0))
    }

    remote = nil
    for _ in 0..<100 where (await server.snapshot).exports != 0 { await Task.yield() }
    #expect((await server.snapshot).exports == 0)
    #expect((await client.snapshot).questions == 0)
    #expect((await server.snapshot).answers == 0)
    await client.close()
    await server.close()
}

private actor NeverReturnWireService: CapabilityCallTarget {
    private(set) var cancelled = false
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        do {
            try await Task.sleep(for: .seconds(60))
            return params
        } catch {
            cancelled = true
            throw error
        }
    }
}

@Test func wireCancellationSendsFinishAndCancelsServerAnswer() async throws {
    let service = NeverReturnWireService()
    let (a, b) = InMemoryRPCTransport.makePair()
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: service))
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()
    let call = Task { try await remote.call(wireMethod, params: wireValue(1)) }
    while (await server.snapshot).answers == 0 { await Task.yield() }
    call.cancel()
    await #expect(throws: CapabilityError.cancelled) { _ = try await call.value }
    while !(await service.cancelled) { await Task.yield() }
    #expect((await server.snapshot).answers == 0)
    for _ in 0..<10 { await Task.yield() }
    #expect(!(await client.snapshot).isClosed)
    await client.close()
    await server.close()
}

private actor StreamingProbe: CapabilityMethodLookupTarget {
    private var active = 0
    private(set) var maximumActive = 0

    nonisolated func methodDescriptor(interfaceID: UInt64, methodID: UInt16)
        -> CapabilityMethodDescriptor?
    {
        guard interfaceID == wireMethod.interfaceID, methodID == wireMethod.methodID else {
            return nil
        }
        return CapabilityMethodDescriptor(
            interfaceID: interfaceID, methodID: methodID, name: "stream",
            paramStructID: 1, resultStructID: 2, isStreaming: true)
    }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        active += 1
        maximumActive = max(maximumActive, active)
        await Task.yield()
        active -= 1
        return params
    }
}

private actor StreamingFailureProbe: CapabilityMethodLookupTarget {
    let gate = WireGate()
    private(set) var values: [UInt32] = []

    nonisolated func methodDescriptor(interfaceID: UInt64, methodID: UInt16)
        -> CapabilityMethodDescriptor?
    {
        guard interfaceID == wireMethod.interfaceID, methodID == wireMethod.methodID else {
            return nil
        }
        return CapabilityMethodDescriptor(
            interfaceID: interfaceID, methodID: methodID, name: "stream",
            paramStructID: 1, resultStructID: 2, isStreaming: true)
    }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        let value = try params.integer(atByte: 0, as: UInt32.self)
        values.append(value)
        if value == 1 { await gate.wait() }
        if value == 2 { throw RemoteException(kind: .overloaded, reason: "stream failed") }
        return params
    }
}

private final class CapabilityPassingService: CapabilityCallTargetWithCaps, @unchecked Sendable {
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        throw CapabilityError.unserializableCapability
    }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        let callback = try #require(capabilities.first)
        let callbackResult = try await callback.call(wireMethod, params: params)
        return CapabilityCallResult(results: callbackResult, capabilities: [callback])
    }
}

private final class ReceiverAnswerService: CapabilityCallTargetWithCaps, @unchecked Sendable {
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        try wireValue(try params.integer(atByte: 0, as: UInt32.self) + 1)
    }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        let callback = try #require(capabilities.first)
        return CapabilityCallResult(results: try await callback.call(method, params: params))
    }
}

private final class ReceiverAnswerTransformService: CapabilityCallTargetWithCaps,
    @unchecked Sendable
{
    let gate: WireGate
    let returned: CapabilityClient

    init(gate: WireGate, returned: CapabilityClient) {
        self.gate = gate
        self.returned = returned
    }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    { throw CapabilityError.unserializableCapability }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        if let callback = capabilities.first {
            return CapabilityCallResult(results: try await callback.call(method, params: params))
        }
        await gate.wait()
        let message = try MessageBuilder()
        let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
        try root.setCapabilityField(at: 0, tableIndex: 0)
        return CapabilityCallResult(
            results: try message.asReader().rootStruct(), capabilities: [returned])
    }
}

private actor WireGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private final class CapabilityFactoryService: CapabilityCallTargetWithCaps, @unchecked Sendable {
    let gate: WireGate
    let callback: CapabilityClient
    init(gate: WireGate, callback: CapabilityClient) {
        self.gate = gate
        self.callback = callback
    }
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    { throw CapabilityError.unserializableCapability }
    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        await gate.wait()
        let message = try MessageBuilder()
        let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
        try root.setCapabilityField(at: 0, tableIndex: 0)
        return CapabilityCallResult(
            results: try message.asReader().rootStruct(), capabilities: [callback])
    }
}

private final class PromiseFactoryService: CapabilityCallTargetWithCaps, @unchecked Sendable {
    let promise: (client: CapabilityClient, resolver: CapabilityResolver)

    init() { promise = CapabilityClient.makePromise() }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    { throw CapabilityError.unserializableCapability }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        let message = try MessageBuilder()
        let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
        try root.setCapabilityField(at: 0, tableIndex: 0)
        return CapabilityCallResult(
            results: try message.asReader().rootStruct(), capabilities: [promise.client])
    }
}

private final class RedirectPromiseFactoryService: CapabilityCallTargetWithCaps, @unchecked Sendable
{
    let first = CapabilityClient.makePromise()
    let second = CapabilityClient.makePromise()

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    { throw CapabilityError.unserializableCapability }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        let message = try MessageBuilder()
        let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
        try root.setCapabilityField(at: 0, tableIndex: 0)
        return CapabilityCallResult(
            results: try message.asReader().rootStruct(), capabilities: [first.client])
    }
}

private final class PromiseCaptureService: CapabilityCallTargetWithCaps, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: CapabilityClient?

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    { throw CapabilityError.unserializableCapability }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        let capability = try #require(capabilities.first)
        lock.withLock {
            if captured == nil { captured = capability }
        }
        return CapabilityCallResult(results: params)
    }

    var capability: CapabilityClient? { lock.withLock { captured } }
    func clear() { lock.withLock { captured = nil } }
}

private final class LoopbackPromiseService: CapabilityCallTargetWithCaps, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: CapabilityClient?
    private let promise = CapabilityClient.makePromise()

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    { throw CapabilityError.unserializableCapability }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        lock.withLock { captured = capabilities.first }
        let message = try MessageBuilder()
        let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
        try root.setCapabilityField(at: 0, tableIndex: 0)
        return CapabilityCallResult(
            results: try message.asReader().rootStruct(), capabilities: [promise.client])
    }

    func resolveBackToCaller() throws {
        try promise.resolver.resolve(to: #require(lock.withLock { captured }))
    }
}

// Adapts Rpc.SendCap and Rpc.ReturnCap from rpc-test.c++ at the pinned upstream
// commit, exercising parameter and result cap-table adoption in both directions.
@Test func capabilitiesPassInParametersAndResults() async throws {
    let callback = WireService()
    let (a, b) = InMemoryRPCTransport.makePair(configuration: .init(fragmentSize: 5))
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b,
        bootstrap: CapabilityClient(target: CapabilityPassingService()))
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()
    let response = try await remote.call(
        wireMethod, params: wireValue(5),
        capabilities: [CapabilityClient(target: callback)])
    #expect(try response.results.integer(atByte: 0, as: UInt32.self) == 6)
    let returned = try #require(response.capabilities.first)
    let second = try await returned.call(wireMethod, params: wireValue(8))
    #expect(try second.integer(atByte: 0, as: UInt32.self) == 9)
    #expect(callback.values == [5, 8])
    await client.close()
    await server.close()
}

@Test func receiverAnswerCapabilityTableEntryResolvesWithoutProxyExport() async throws {
    let (rawClient, serverTransport) = InMemoryRPCTransport.makePair(
        configuration: .init(fragmentSize: 3))
    let clientTransport = ReceiverAnswerProbeTransport(rawClient)
    let client = TwoPartyRPCConnection(side: .client, transport: clientTransport)
    let server = TwoPartyRPCConnection(
        side: .server, transport: serverTransport,
        bootstrap: CapabilityClient(target: ReceiverAnswerService()))
    await client.start()
    await server.start()

    let bootstrap = try await client.beginBootstrap()
    let pipeline = bootstrap.pipeline()
    let result = try await pipeline.call(
        wireMethod, params: wireValue(14), capabilities: [pipeline])
    #expect(try result.results.integer(atByte: 0, as: UInt32.self) == 15)
    #expect(clientTransport.observed)
    _ = try await bootstrap.response()

    await client.close()
    await server.close()
}

@Test func receiverAnswerTransformWaitsForTheReferencedResult() async throws {
    let gate = WireGate()
    let callback = WireService()
    let service = ReceiverAnswerTransformService(
        gate: gate, returned: CapabilityClient(target: callback))
    let (rawClient, serverTransport) = InMemoryRPCTransport.makePair(
        configuration: .init(fragmentSize: 2))
    let clientTransport = ReceiverAnswerProbeTransport(rawClient)
    let client = TwoPartyRPCConnection(side: .client, transport: clientTransport)
    let server = TwoPartyRPCConnection(
        side: .server, transport: serverTransport,
        bootstrap: CapabilityClient(target: service))
    await client.start()
    await server.start()

    let remote = try await client.bootstrap()
    let parent = Task {
        try await remote.call(wireMethod, params: wireValue(0), capabilities: [])
    }
    while (await client.snapshot).questions < 1 { await Task.yield() }
    let promisedCallback = await client.pipeline(questionID: 1, pointerFields: [0])
    let child = Task {
        try await remote.call(
            wireMethod, params: wireValue(20), capabilities: [promisedCallback])
    }
    while (await client.snapshot).questions < 2 { await Task.yield() }
    await gate.open()

    _ = try await parent.value
    #expect(try await child.value.results.integer(atByte: 0, as: UInt32.self) == 21)
    #expect(clientTransport.observed)
    #expect(callback.values == [20])

    await client.close()
    await server.close()
}

@Test func nonEmptyPromisedAnswerTransformResolvesReturnedCapability() async throws {
    let gate = WireGate()
    let callback = WireService()
    let factory = CapabilityFactoryService(
        gate: gate, callback: CapabilityClient(target: callback))
    let (a, b) = InMemoryRPCTransport.makePair(configuration: .init(fragmentSize: 1))
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: factory))
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()
    let parent = Task { try await remote.call(wireMethod, params: wireValue(0)) }
    while (await client.snapshot).questions < 1 { await Task.yield() }
    let pipeline = await client.pipeline(questionID: 1, pointerFields: [0])
    let child = Task { try await pipeline.call(wireMethod, params: wireValue(12)) }
    while (await client.snapshot).questions < 2 { await Task.yield() }
    await gate.open()
    _ = try await parent.value
    #expect(try await child.value.integer(atByte: 0, as: UInt32.self) == 13)
    #expect(callback.values == [12])
    await client.close()
    await server.close()
}

// Exercises CapDescriptor.senderPromise and Resolve on the wire, including a
// call queued before the delayed resolution arrives.
@Test func senderPromiseResolvesToCapabilityAndErrorAcrossTheWire() async throws {
    let factory = PromiseFactoryService()
    let resolvedTarget = WireService()
    let (a, b) = InMemoryRPCTransport.makePair(configuration: .init(fragmentSize: 2))
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: factory))
    await client.start()
    await server.start()

    let remote = try await client.bootstrap()
    let response = try await remote.call(
        wireMethod, params: wireValue(0), capabilities: [])
    let promised = try #require(response.capabilities.first)
    let delayed = Task { try await promised.call(wireMethod, params: wireValue(30)) }
    try factory.promise.resolver.resolve(to: CapabilityClient(target: resolvedTarget))
    #expect(try await delayed.value.integer(atByte: 0, as: UInt32.self) == 31)

    let rejectedFactory = PromiseFactoryService()
    let (c, d) = InMemoryRPCTransport.makePair()
    let rejectedClient = TwoPartyRPCConnection(side: .client, transport: c)
    let rejectedServer = TwoPartyRPCConnection(
        side: .server, transport: d,
        bootstrap: CapabilityClient(target: rejectedFactory))
    await rejectedClient.start()
    await rejectedServer.start()
    let rejectedRemote = try await rejectedClient.bootstrap()
    let rejectedResponse = try await rejectedRemote.call(
        wireMethod, params: wireValue(0), capabilities: [])
    let rejected = try #require(rejectedResponse.capabilities.first)
    let failed = Task { try await rejected.call(wireMethod, params: wireValue(1)) }
    let exception = RemoteException(kind: .overloaded, reason: "delayed failure")
    try rejectedFactory.promise.resolver.reject(exception)
    await #expect(throws: CapabilityError.broken(exception)) { _ = try await failed.value }

    await client.close()
    await server.close()
    await rejectedClient.close()
    await rejectedServer.close()
}

@Test func senderPromiseRedirectChainResolvesAcrossTheWire() async throws {
    let factory = RedirectPromiseFactoryService()
    let target = WireService()
    let (a, b) = InMemoryRPCTransport.makePair()
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: factory))
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()
    let response = try await remote.call(
        wireMethod, params: wireValue(0), capabilities: [])
    let redirected = try #require(response.capabilities.first)
    let call = Task { try await redirected.call(wireMethod, params: wireValue(50)) }
    try factory.first.resolver.resolve(to: factory.second.client)
    try factory.second.resolver.resolve(to: CapabilityClient(target: target))
    #expect(try await call.value.integer(atByte: 0, as: UInt32.self) == 51)
    await client.close()
    await server.close()
}

// Ports rpc-test.c++'s "export the same promise twice": identity is reused,
// references accumulate on one table entry, and one Resolve covers both sends.
@Test func exportingTheSamePromiseTwiceReusesOneReferenceCountedEntry() async throws {
    let capture = PromiseCaptureService()
    let promise = CapabilityClient.makePromise()
    let resolvedTarget = WireService()
    let (a, b) = InMemoryRPCTransport.makePair()
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: capture))
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()

    _ = try await remote.call(
        wireMethod, params: wireValue(1), capabilities: [promise.client])
    _ = try await remote.call(
        wireMethod, params: wireValue(2), capabilities: [promise.client])
    #expect((await client.snapshot).exports == 1)
    #expect((await server.snapshot).imports == 1)

    do {
        let importedPromise = try #require(capture.capability)
        let queued = Task { try await importedPromise.call(wireMethod, params: wireValue(40)) }
        try promise.resolver.resolve(to: CapabilityClient(target: resolvedTarget))
        #expect(try await queued.value.integer(atByte: 0, as: UInt32.self) == 41)
        #expect((await server.snapshot).imports == 2)
    }
    capture.clear()
    for _ in 0..<100 where (await server.snapshot).imports != 0 { await Task.yield() }
    #expect((await server.snapshot).imports == 0)

    await client.close()
    await server.close()
}

@Test func failedCallSendRollsBackParameterCapabilityExports() async throws {
    let (rawClient, serverTransport) = InMemoryRPCTransport.makePair()
    let clientTransport = SwitchableFailTransport(rawClient)
    let client = TwoPartyRPCConnection(side: .client, transport: clientTransport)
    let server = TwoPartyRPCConnection(
        side: .server, transport: serverTransport,
        bootstrap: CapabilityClient(target: CapabilityPassingService()))
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()
    clientTransport.failNextCall()
    await #expect(throws: RPCTransportError.injected(operation: 0)) {
        _ = try await remote.call(
            wireMethod, params: wireValue(1),
            capabilities: [CapabilityClient(target: WireService())])
    }
    #expect((await client.snapshot).exports == 0)
    await client.close()
    await server.close()
}

private final class TailCallService: CapabilityCallTargetWithCaps, @unchecked Sendable {
    weak var connection: TwoPartyRPCConnection?

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    { throw CapabilityError.unserializableCapability }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        let connection = try #require(connection)
        let callback = try #require(capabilities.first)
        let importID = try #require(callback.tableIndex)
        let questionID = try await connection.beginTailCall(
            importID: importID, method: method, params: params)
        throw RPCTailCall(questionID: questionID)
    }
}

@Test func takeFromOtherQuestionAdoptsTheTailCalleeResult() async throws {
    let service = TailCallService()
    let (a, b) = InMemoryRPCTransport.makePair(configuration: .init(fragmentSize: 1))
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: service))
    service.connection = server
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()
    let response = try await remote.call(
        wireMethod, params: wireValue(100),
        capabilities: [CapabilityClient(target: WireService())])
    #expect(try response.results.integer(atByte: 0, as: UInt32.self) == 101)

    await client.close()
    await server.close()
}

@Test func cancellingTailCallCancelsReverseDirectionCallee() async throws {
    let service = TailCallService()
    let callback = NeverReturnWireService()
    let (a, b) = InMemoryRPCTransport.makePair()
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: service))
    service.connection = server
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()
    let call = Task {
        try await remote.call(
            wireMethod, params: wireValue(1),
            capabilities: [CapabilityClient(target: callback)])
    }
    while (await client.snapshot).answers == 0 { await Task.yield() }
    call.cancel()
    await #expect(throws: CapabilityError.cancelled) { _ = try await call.value }
    while !(await callback.cancelled) { await Task.yield() }
    #expect((await client.snapshot).answers == 0)
    await client.close()
    await server.close()
}

// Adapts Rpc.Streaming and its flow-control ordering cases from rpc-test.c++ at
// pinned commit 3a82de9b39736a2625f03c93b2b7c50642dd5b25.
@Test func streamingCallsApplyOneAtATimeFlowControl() async throws {
    let service = StreamingProbe()
    let (a, b) = InMemoryRPCTransport.makePair()
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: service))
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for value in UInt32(0)..<8 {
            group.addTask { _ = try await remote.call(wireMethod, params: wireValue(value)) }
        }
        try await group.waitForAll()
    }
    #expect(await service.maximumActive == 1)
    await client.close()
    await server.close()
}

@Test func streamingFailureCascadesToQueuedFollowersWithoutDispatch() async throws {
    let service = StreamingFailureProbe()
    let (a, b) = InMemoryRPCTransport.makePair()
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: service))
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()

    let first = Task { try await remote.call(wireMethod, params: wireValue(1)) }
    while (await client.snapshot).questions < 1 { await Task.yield() }
    let failing = Task { try await remote.call(wireMethod, params: wireValue(2)) }
    while (await client.snapshot).questions < 2 { await Task.yield() }
    let follower = Task { try await remote.call(wireMethod, params: wireValue(3)) }
    while (await client.snapshot).questions < 3 { await Task.yield() }
    await service.gate.open()

    _ = try await first.value
    let failure = CapabilityError.broken(
        RemoteException(kind: .overloaded, reason: "stream failed"))
    await #expect(throws: failure) { _ = try await failing.value }
    await #expect(throws: failure) { _ = try await follower.value }
    #expect(await service.values == [1, 2])
    await client.close()
    await server.close()
}

// Adapts the sender/receiver-loopback disembargo and call-order regressions in
// rpc-test.c++ at the pinned upstream commit above.
@Test func disembargoFormsAnOrderingBarrierBetweenCalls() async throws {
    let service = LoopbackPromiseService()
    let callback = WireService()
    let (a, b) = InMemoryRPCTransport.makePair(configuration: .init(fragmentSize: 2))
    let client = TwoPartyRPCConnection(side: .client, transport: a)
    let server = TwoPartyRPCConnection(
        side: .server, transport: b, bootstrap: CapabilityClient(target: service))
    await client.start()
    await server.start()
    let remote = try await client.bootstrap()
    let response = try await remote.call(
        wireMethod, params: wireValue(0),
        capabilities: [CapabilityClient(target: callback)])
    let loopbackPromise = try #require(response.capabilities.first)
    try service.resolveBackToCaller()

    let id = try #require(loopbackPromise.tableIndex)
    _ = try await loopbackPromise.call(wireMethod, params: wireValue(1))
    try await client.establishOrderingBarrier(for: id)
    _ = try await loopbackPromise.call(wireMethod, params: wireValue(2))
    #expect(callback.values == [1, 2])
    #expect((await client.snapshot).embargoes == 0)
    #expect((await server.snapshot).embargoes == 0)
    await client.close()
    await server.close()
}
