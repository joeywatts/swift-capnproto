import CapnProto
import Foundation

public struct TwoPartyConnectionSnapshot: Equatable, Sendable {
    public let questions: Int
    public let answers: Int
    public let imports: Int
    public let exports: Int
    public let embargoes: Int
    public let isClosed: Bool
    public let terminalError: String?
}

/// A server may throw this directive to forward its answer to another question
/// using the protocol's `takeFromOtherQuestion` return variant.
public struct RPCTailCall: Error, Equatable, Sendable {
    public let questionID: UInt32
    public init(questionID: UInt32) { self.questionID = questionID }
}

private final class PendingWireQuestion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<[UInt8], any Error>] = []
    private var result: Result<[UInt8], any Error>?

    func wait() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            let completed: Result<[UInt8], any Error>? = lock.withLock {
                if let result { return result }
                continuations.append(continuation)
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }
    }

    func resume(returning value: [UInt8]) {
        complete(.success(value))
    }

    func resume(throwing error: any Error) {
        complete(.failure(error))
    }

    private func complete(_ completed: Result<[UInt8], any Error>) {
        let waiters: [CheckedContinuation<[UInt8], any Error>] = lock.withLock {
            guard result == nil else { return [] }
            result = completed
            let waiters = continuations
            continuations.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters { waiter.resume(with: completed) }
    }
}

private final class PendingTailResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<CapabilityCallResult, any Error>] = []
    private var result: Result<CapabilityCallResult, any Error>?

    func wait() async throws -> CapabilityCallResult {
        try await withCheckedThrowingContinuation { continuation in
            let completed: Result<CapabilityCallResult, any Error>? = lock.withLock {
                if let result { return result }
                continuations.append(continuation)
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }
    }

    func resume(with completed: Result<CapabilityCallResult, any Error>) {
        let waiters: [CheckedContinuation<CapabilityCallResult, any Error>] = lock.withLock {
            guard result == nil else { return [] }
            result = completed
            let waiters = continuations
            continuations.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters { waiter.resume(with: completed) }
    }
}

private final class RemoteCapabilityTarget: CapabilityCallTargetWithCaps, @unchecked Sendable {
    let importID: UInt32
    weak var connection: TwoPartyRPCConnection?

    init(importID: UInt32, connection: TwoPartyRPCConnection) {
        self.importID = importID
        self.connection = connection
    }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        guard let connection else { throw RPCConnectionError.disconnected }
        return try await connection.call(importID: importID, method: method, params: params)
    }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        guard let connection else { throw RPCConnectionError.disconnected }
        return try await connection.callPayload(
            importID: importID, method: method, params: params,
            capabilities: capabilities)
    }

    deinit {
        guard let connection else { return }
        let id = importID
        Task { await connection.releaseImport(id) }
    }
}

private final class PromisedAnswerCapabilityTarget: CapabilityCallTargetWithCaps,
    @unchecked Sendable
{
    let questionID: UInt32
    let pointerFields: [UInt16]
    weak var connection: TwoPartyRPCConnection?

    init(questionID: UInt32, pointerFields: [UInt16], connection: TwoPartyRPCConnection) {
        self.questionID = questionID
        self.pointerFields = pointerFields
        self.connection = connection
    }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        guard let connection else { throw RPCConnectionError.disconnected }
        return try await connection.callPromised(
            questionID: questionID, pointerFields: pointerFields,
            method: method, params: params
        ).results
    }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        guard let connection else { throw RPCConnectionError.disconnected }
        return try await connection.callPromised(
            questionID: questionID, pointerFields: pointerFields,
            method: method, params: params, capabilities: capabilities)
    }
}

private final class ReceiverAnswerCapabilityTarget: CapabilityCallTargetWithCaps,
    @unchecked Sendable
{
    let questionID: UInt32
    let pointerFields: [UInt16]
    weak var connection: TwoPartyRPCConnection?

    init(questionID: UInt32, pointerFields: [UInt16], connection: TwoPartyRPCConnection) {
        self.questionID = questionID
        self.pointerFields = pointerFields
        self.connection = connection
    }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        guard let connection else { throw RPCConnectionError.disconnected }
        return try await connection.callReceiverAnswer(
            questionID: questionID, pointerFields: pointerFields,
            method: method, params: params)
    }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        guard let connection else { throw RPCConnectionError.disconnected }
        return try await connection.callReceiverAnswer(
            questionID: questionID, pointerFields: pointerFields,
            method: method, params: params, capabilities: capabilities)
    }
}

private final class ImportedPromiseCapabilityTarget: CapabilityCallTargetWithCaps,
    @unchecked Sendable
{
    let importID: UInt32
    let promised: CapabilityClient
    weak var connection: TwoPartyRPCConnection?

    init(importID: UInt32, promised: CapabilityClient, connection: TwoPartyRPCConnection) {
        self.importID = importID
        self.promised = promised
        self.connection = connection
    }

    func supports(interfaceID: UInt64) -> Bool {
        promised.target.supports(interfaceID: interfaceID)
    }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        try await promised.call(method, params: params)
    }

    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        try await promised.call(method, params: params, capabilities: capabilities)
    }

    deinit {
        guard let connection else { return }
        let id = importID
        Task { await connection.releaseAllImports(id) }
    }
}

private enum WireCallTarget: Sendable {
    case imported(UInt32)
    case promised(questionID: UInt32, pointerFields: [UInt16])
}

private enum InboundWireTarget: Sendable {
    case imported(UInt32)
    case promised(questionID: UInt32, pointerFields: [UInt16])
}

public final class RPCBootstrapCall: @unchecked Sendable {
    public let questionID: UInt32
    private let waiter: PendingWireQuestion
    private weak var connection: TwoPartyRPCConnection?

    fileprivate init(
        questionID: UInt32, waiter: PendingWireQuestion, connection: TwoPartyRPCConnection
    ) {
        self.questionID = questionID
        self.waiter = waiter
        self.connection = connection
    }

    public func response() async throws -> CapabilityClient {
        guard let connection else { throw RPCConnectionError.disconnected }
        return try await connection.completeBootstrap(questionID: questionID, waiter: waiter)
    }

    public func pipeline(pointerFields: [UInt16] = []) -> CapabilityClient {
        guard let connection else { return .null }
        return CapabilityClient(
            target: PromisedAnswerCapabilityTarget(
                questionID: questionID, pointerFields: pointerFields, connection: connection))
    }

    public func cancel() {
        guard let connection else { return }
        Task { await connection.cancelBootstrap(questionID) }
    }
}

/// Level-3 two-party RPC state machine over an ordered byte transport.
///
/// The connection consumes standard stream-framed `rpc.capnp` messages. All
/// inbound messages pass `RPCWireValidator` before any live table is touched.
public actor TwoPartyRPCConnection {
    public let side: Side
    private let transport: any RPCMessageTransport
    private let bootstrapTarget: CapabilityClient?
    private let maximumMessageWords: Int
    private var receiveTask: Task<Void, Never>?
    private var decoder = StreamMessageDecoder(
        options: FramingOptions(maximumSegments: 64, maximumTotalWords: 1 << 20))
    private var validation = RPCWireValidationState()
    private var nextQuestionID: UInt32 = 0
    private var nextExportID: UInt32 = 0
    private var nextEmbargoID: UInt32 = 0
    private var pending: [UInt32: PendingWireQuestion] = [:]
    private var returnedMessages: [UInt32: [UInt8]] = [:]
    private var questionParamExportIDs: [UInt32: [UInt32]] = [:]
    private var inboundTailResults: [UInt32: PendingTailResult] = [:]
    private var tailAdoptions: [UInt32: PendingTailResult] = [:]
    private var tailAnswerQuestions: [UInt32: UInt32] = [:]
    private var cancelledQuestionIDs: Set<UInt32> = []
    private var embargoWaiters: [UInt32: PendingWireQuestion] = [:]
    private var answers: [UInt32: Task<Void, any Error>] = [:]
    private var exports: [UInt32: CapabilityClient] = [:]
    private var exportIDsByTarget: [ObjectIdentifier: UInt32] = [:]
    private var exportReferences: [UInt32: Int] = [:]
    private var importReferences: [UInt32: Int] = [:]
    private var promiseResolvers: [UInt32: CapabilityResolver] = [:]
    private var promiseClients: [UInt32: CapabilityClient] = [:]
    private var promiseRedirects: [UInt32: UInt32] = [:]
    private var answerCapabilities: [UInt32: CapabilityClient] = [:]
    private var answerResults: [UInt32: CapabilityCallResult] = [:]
    private var answerResultWaiters: [UInt32: PendingTailResult] = [:]
    private var answerExportIDs: [UInt32: [UInt32]] = [:]
    private var answerDependents: [UInt32: Int] = [:]
    private var finishedAnswers: Set<UInt32> = []
    private var streamingTail: Task<Void, any Error>?
    private var streamingGeneration: UInt64 = 0
    private var closed = false
    private var terminalError: String?

    public init(
        side: Side, transport: any RPCMessageTransport,
        bootstrap: CapabilityClient? = nil, maximumMessageWords: Int = 1 << 20
    ) {
        self.side = side
        self.transport = transport
        bootstrapTarget = bootstrap
        self.maximumMessageWords = maximumMessageWords
        decoder = StreamMessageDecoder(
            options: FramingOptions(
                maximumSegments: 64, maximumTotalWords: maximumMessageWords))
    }

    public func start() {
        guard receiveTask == nil, !closed else { return }
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    public func bootstrap() async throws -> CapabilityClient {
        let call = try await beginBootstrap()
        return try await call.response()
    }

    public func beginBootstrap() async throws -> RPCBootstrapCall {
        let id = try allocateQuestion()
        let waiter = PendingWireQuestion()
        pending[id] = waiter
        validation.outboundQuestions.insert(id)
        do {
            try await sendMessage { root in
                try root.initBootstrap().setQuestionId(id)
            }
            return RPCBootstrapCall(questionID: id, waiter: waiter, connection: self)
        } catch {
            pending.removeValue(forKey: id)
            validation.outboundQuestions.remove(id)
            throw error
        }
    }

    fileprivate func completeBootstrap(
        questionID: UInt32, waiter: PendingWireQuestion
    ) async throws -> CapabilityClient {
        let bytes = try await withTaskCancellationHandler {
            try await waiter.wait()
        } onCancel: {
            Task { await self.cancelQuestion(questionID) }
        }
        return try capabilityFromReturn(
            RPCWireValidator.decode(bytes, maximumWords: maximumMessageWords),
            questionID: questionID)
    }

    fileprivate func cancelBootstrap(_ id: UInt32) async { await cancelQuestion(id) }

    public func call(
        importID: UInt32, method: CapabilityMethodDescriptor, params: StructReader
    ) async throws -> StructReader {
        guard importReferences[importID] != nil else {
            throw RPCProtocolError.unknownCapability(importID)
        }
        return try await callPayload(
            importID: importID, method: method, params: params, capabilities: []
        ).results
    }

    public func callPayload(
        importID: UInt32, method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        guard importReferences[importID] != nil else {
            throw RPCProtocolError.unknownCapability(importID)
        }
        return try await performCall(
            target: .imported(importID), method: method, params: params,
            capabilities: capabilities)
    }

    /// Starts the reverse-direction call used by a server tail call. The server
    /// should throw `RPCTailCall(questionID:)` with the returned ID.
    public func beginTailCall(
        importID: UInt32, method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient] = []
    ) async throws -> UInt32 {
        guard importReferences[importID] != nil else {
            throw RPCProtocolError.unknownCapability(importID)
        }
        let id = try allocateQuestion()
        let waiter = PendingWireQuestion()
        pending[id] = waiter
        validation.outboundQuestions.insert(id)
        validation.outboundTailQuestions.insert(id)
        var callSent = false
        do {
            try await sendMessage { root in
                let call = try root.initCall()
                try call.setQuestionId(id)
                try call.initTarget().setImportedCap(importID)
                try call.setInterfaceId(method.interfaceID)
                try call.setMethodId(method.methodID)
                try call.sendResultsTo.setYourself()
                let payload = try call.initParams()
                try payload.content.setStruct(params)
                if !capabilities.isEmpty {
                    let table = try payload.initCapTable(count: capabilities.count)
                    var exported: [UInt32] = []
                    for (index, capability) in capabilities.enumerated() {
                        if let exportID = try encodeCapability(
                            capability, into: CapDescriptor.Builder(table[index]))
                        {
                            exported.append(exportID)
                        }
                    }
                    questionParamExportIDs[id] = exported
                }
            }
            callSent = true
            return id
        } catch {
            pending.removeValue(forKey: id)
            validation.outboundQuestions.remove(id)
            validation.outboundTailQuestions.remove(id)
            if !callSent { try rollbackQuestionParamExports(id) }
            throw error
        }
    }

    /// Returns a capability that addresses a capability in an unanswered call.
    /// Calls issued through it are transmitted immediately as promised-answer targets.
    public func pipeline(
        questionID: UInt32, pointerFields: [UInt16] = []
    ) -> CapabilityClient {
        CapabilityClient(
            target: PromisedAnswerCapabilityTarget(
                questionID: questionID, pointerFields: pointerFields, connection: self))
    }

    /// Inserts the two-party sender/receiver loopback barrier defined by
    /// `rpc.capnp`. Completion proves that all earlier calls to the import have
    /// reached the peer before later calls are sent.
    public func establishOrderingBarrier(for importID: UInt32) async throws {
        guard importReferences[importID] != nil else {
            throw RPCProtocolError.unknownCapability(importID)
        }
        guard nextEmbargoID != UInt32.max else { throw RPCConnectionError.idExhausted }
        let id = nextEmbargoID
        nextEmbargoID += 1
        let waiter = PendingWireQuestion()
        embargoWaiters[id] = waiter
        validation.senderLoopbackEmbargoes.insert(id)
        do {
            try await sendMessage { root in
                let message = try root.initDisembargo()
                try message.initTarget().setImportedCap(importID)
                try message.context.setSenderLoopback(id)
            }
            _ = try await waiter.wait()
        } catch {
            embargoWaiters.removeValue(forKey: id)
            validation.senderLoopbackEmbargoes.remove(id)
            throw error
        }
    }

    fileprivate func callPromised(
        questionID: UInt32, pointerFields: [UInt16],
        method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient] = []
    ) async throws -> CapabilityCallResult {
        guard validation.outboundQuestions.contains(questionID) else {
            throw RPCProtocolError.unknownQuestion(questionID)
        }
        return try await performCall(
            target: .promised(questionID: questionID, pointerFields: pointerFields),
            method: method, params: params, capabilities: capabilities)
    }

    fileprivate func callReceiverAnswer(
        questionID: UInt32, pointerFields: [UInt16],
        method: CapabilityMethodDescriptor, params: StructReader
    ) async throws -> StructReader {
        guard validation.inboundQuestions.contains(questionID) else {
            throw RPCProtocolError.unknownAnswer(questionID)
        }
        let target = try await resolveReceiverAnswer(
            questionID: questionID, pointerFields: pointerFields)
        return try await target.call(method, params: params)
    }

    fileprivate func callReceiverAnswer(
        questionID: UInt32, pointerFields: [UInt16],
        method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        guard validation.inboundQuestions.contains(questionID) else {
            throw RPCProtocolError.unknownAnswer(questionID)
        }
        let target = try await resolveReceiverAnswer(
            questionID: questionID, pointerFields: pointerFields)
        return try await target.call(method, params: params, capabilities: capabilities)
    }

    private func performCall(
        target: WireCallTarget, method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        let id = try allocateQuestion()
        let waiter = PendingWireQuestion()
        pending[id] = waiter
        validation.outboundQuestions.insert(id)
        var receivedReturn = false
        var callSent = false
        do {
            try await sendMessage { root in
                let call = try root.initCall()
                try call.setQuestionId(id)
                let targetBuilder = try call.initTarget()
                switch target {
                case .imported(let importID):
                    try targetBuilder.setImportedCap(importID)
                case .promised(let questionID, let pointerFields):
                    let promised = try targetBuilder.initPromisedAnswer()
                    try promised.setQuestionId(questionID)
                    if !pointerFields.isEmpty {
                        let transform = try promised.initTransform(count: pointerFields.count)
                        for (index, field) in pointerFields.enumerated() {
                            try PromisedAnswer.Op.Builder(transform[index]).setGetPointerField(
                                field)
                        }
                    }
                }
                try call.setInterfaceId(method.interfaceID)
                try call.setMethodId(method.methodID)
                let payload = try call.initParams()
                try payload.content.setStruct(params)
                if !capabilities.isEmpty {
                    let table = try payload.initCapTable(count: capabilities.count)
                    var exported: [UInt32] = []
                    for (index, capability) in capabilities.enumerated() {
                        if let exportID = try encodeCapability(
                            capability, into: CapDescriptor.Builder(table[index]))
                        {
                            exported.append(exportID)
                        }
                    }
                    questionParamExportIDs[id] = exported
                }
            }
            callSent = true
            let bytes = try await withTaskCancellationHandler {
                try await waiter.wait()
            } onCancel: {
                Task { await self.cancelQuestion(id) }
            }
            receivedReturn = true
            let wire = try RPCWireValidator.decode(bytes, maximumWords: maximumMessageWords)
            guard case .return(let result) = try wire.which else {
                throw RPCProtocolError.malformedMessage("expected return")
            }
            switch try result.which {
            case .results(let payload):
                let capabilities = try payload.capTable.map { try importCapability($0) }
                Task { await self.finishQuestion(id, releaseCaps: capabilities.isEmpty) }
                return CapabilityCallResult(
                    results: try payload.content.asStruct(), capabilities: capabilities)
            case .exception(let exception):
                throw CapabilityError.broken(try remoteException(exception))
            case .canceled:
                throw CapabilityError.cancelled
            case .takeFromOtherQuestion(let other):
                guard let tailResult = inboundTailResults[other] else {
                    throw RPCProtocolError.unknownQuestion(other)
                }
                tailAdoptions[id] = tailResult
                let adopted = try await withTaskCancellationHandler {
                    try await tailResult.wait()
                } onCancel: {
                    Task { await self.cancelQuestion(id) }
                }
                tailAdoptions.removeValue(forKey: id)
                Task { await self.finishQuestion(id, releaseCaps: adopted.capabilities.isEmpty) }
                return adopted
            case .resultsSentElsewhere:
                throw RPCProtocolError.malformedMessage("results sent elsewhere")
            case .acceptFromThirdParty:
                throw RPCProtocolError.unsupportedMessageVariant("third-party return")
            case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
            }
        } catch {
            pending.removeValue(forKey: id)
            validation.outboundQuestions.remove(id)
            if !callSent { try rollbackQuestionParamExports(id) }
            if receivedReturn { await finishQuestion(id, releaseCaps: true) }
            throw error
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        receiveTask = nil
        let waiters = Array(pending.values)
        pending.removeAll()
        returnedMessages.removeAll()
        questionParamExportIDs.removeAll()
        inboundTailResults.removeAll()
        let adoptions = Array(tailAdoptions.values)
        tailAdoptions.removeAll()
        tailAnswerQuestions.removeAll()
        cancelledQuestionIDs.removeAll()
        let barriers = Array(embargoWaiters.values)
        embargoWaiters.removeAll()
        let work = Array(answers.values)
        answers.removeAll()
        exports.removeAll()
        exportIDsByTarget.removeAll()
        exportReferences.removeAll()
        importReferences.removeAll()
        promiseResolvers.removeAll()
        promiseClients.removeAll()
        promiseRedirects.removeAll()
        answerCapabilities.removeAll()
        answerResults.removeAll()
        let answerWaiters = Array(answerResultWaiters.values)
        answerResultWaiters.removeAll()
        answerExportIDs.removeAll()
        answerDependents.removeAll()
        finishedAnswers.removeAll()
        validation = RPCWireValidationState()
        streamingTail?.cancel()
        streamingTail = nil
        for task in work { task.cancel() }
        for waiter in waiters { waiter.resume(throwing: RPCConnectionError.disconnected) }
        for adoption in adoptions {
            adoption.resume(with: .failure(RPCConnectionError.disconnected))
        }
        for waiter in answerWaiters {
            waiter.resume(with: .failure(RPCConnectionError.disconnected))
        }
        for barrier in barriers { barrier.resume(throwing: RPCConnectionError.disconnected) }
        await transport.close()
    }

    public var snapshot: TwoPartyConnectionSnapshot {
        TwoPartyConnectionSnapshot(
            questions: pending.count, answers: answers.count,
            imports: importReferences.count, exports: exports.count,
            embargoes: validation.senderLoopbackEmbargoes.count
                + validation.receiverLoopbackEmbargoes.count,
            isClosed: closed, terminalError: terminalError)
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled, let chunk = try await transport.receive() {
                for frame in try decoder.append(chunk) {
                    let message = Message.Reader(
                        try frame.reader(
                            options: ReaderOptions(
                                traversalLimitInWords: maximumMessageWords, nestingLimit: 64)
                        ).rootStruct())
                    try RPCWireValidator.validate(message, state: &validation)
                    try await handle(message, bytes: try MessageFraming.encode(frame.segments))
                }
            }
            try decoder.finish()
            await close()
        } catch is CancellationError {
            // Explicit close owns cleanup.
        } catch {
            await fail(error)
        }
    }

    private func handle(_ message: Message.Reader, bytes: [UInt8]) async throws {
        switch try message.which {
        case .bootstrap(let bootstrap):
            let id = try bootstrap.questionId
            guard let bootstrapTarget else {
                try await sendException(answerID: id, error: CapabilityError.nullCapability)
                return
            }
            let exportID = try export(bootstrapTarget)
            answerCapabilities[id] = bootstrapTarget
            try await sendMessage { root in
                let result = try root.initReturn()
                try result.setAnswerId(id)
                let payload = try result.initResults()
                let descriptors = try payload.initCapTable(count: 1)
                try CapDescriptor.Builder(descriptors[0]).setSenderHosted(exportID)
                try payload.content.setCapability(tableIndex: 0)
            }
        case .call(let call):
            let id = try call.questionId
            answerResultWaiters[id] = PendingTailResult()
            let wireTarget = try decodeTarget(try call.target)
            let interfaceID = try call.interfaceId
            let methodID = try call.methodId
            var method = CapabilityMethodDescriptor(
                interfaceID: interfaceID, methodID: methodID,
                name: "wire", paramStructID: 0, resultStructID: 0,
                isStreaming: false)
            if case .imported(let importID) = wireTarget,
                let lookup = exports[importID]?.target as? any CapabilityMethodLookupTarget,
                let known = lookup.methodDescriptor(interfaceID: interfaceID, methodID: methodID)
            {
                method = known
            }
            let wirePayload = try call.params
            let params = try wirePayload.content.asStruct()
            let parameterCapabilities = try wirePayload.capTable.map { try importCapability($0) }
            let resultsToSelf: Bool
            switch try call.sendResultsTo.which {
            case .caller: resultsToSelf = false
            case .yourself:
                resultsToSelf = true
                inboundTailResults[id] = PendingTailResult()
            case .thirdParty:
                throw RPCProtocolError.unsupportedMessageVariant("third-party results")
            case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
            }
            let isPromisedTarget: Bool
            if case .promised = wireTarget {
                isPromisedTarget = true
            } else {
                isPromisedTarget = false
            }
            let joinsStreamingChain = method.isStreaming || streamingTail != nil || isPromisedTarget
            let preceding = joinsStreamingChain ? streamingTail : nil
            let generation: UInt64?
            if joinsStreamingChain {
                streamingGeneration &+= 1
                generation = streamingGeneration
            } else {
                generation = nil
            }
            let task = Task<Void, any Error> { [weak self] in
                do {
                    try await preceding?.value
                    guard let self else { throw RPCConnectionError.disconnected }
                    let target = try await self.resolveTarget(wireTarget)
                    let result: CapabilityCallResult
                    if let target = target.target as? any CapabilityCallTargetWithCaps {
                        result = try await target.call(
                            method, params: params, capabilities: parameterCapabilities)
                    } else {
                        guard parameterCapabilities.isEmpty else {
                            throw CapabilityError.unserializableCapability
                        }
                        result = CapabilityCallResult(
                            results: try await target.call(method, params: params))
                    }
                    await self.recordAnswerResult(result, for: id)
                    if resultsToSelf {
                        await self.completeInboundTail(id, with: .success(result))
                        try await self.sendResultsSentElsewhere(
                            answerID: id, releaseParamCaps: parameterCapabilities.isEmpty)
                    } else {
                        try await self.sendResults(
                            answerID: id, value: result,
                            releaseParamCaps: parameterCapabilities.isEmpty)
                    }
                } catch let tail as RPCTailCall {
                    await self?.recordTailQuestion(tail.questionID, for: id)
                    await self?.failAnswerResult(
                        CapabilityError.unserializableCapability, for: id)
                    try? await self?.sendTailReturn(
                        answerID: id, from: tail.questionID,
                        releaseParamCaps: parameterCapabilities.isEmpty)
                } catch {
                    await self?.failAnswerResult(error, for: id)
                    if resultsToSelf {
                        await self?.completeInboundTail(id, with: .failure(error))
                        try? await self?.sendResultsSentElsewhere(
                            answerID: id, releaseParamCaps: parameterCapabilities.isEmpty)
                    } else {
                        try? await self?.sendException(
                            answerID: id, error: error,
                            releaseParamCaps: parameterCapabilities.isEmpty)
                    }
                    await self?.answerFinished(id)
                    if let generation { await self?.completeStreamingGeneration(generation) }
                    throw error
                }
                await self?.answerFinished(id)
                if let generation { await self?.completeStreamingGeneration(generation) }
            }
            answers[id] = task
            if joinsStreamingChain { streamingTail = task }
        case .return(let result):
            let id = try result.answerId
            let exportedParams = questionParamExportIDs.removeValue(forKey: id) ?? []
            if try result.releaseParamCaps {
                for (exportID, count) in Dictionary(grouping: exportedParams, by: { $0 }) {
                    try releaseExport(exportID, count: count.count)
                }
            }
            guard let waiter = pending.removeValue(forKey: id) else {
                if cancelledQuestionIDs.remove(id) != nil { return }
                throw RPCProtocolError.unknownQuestion(id)
            }
            returnedMessages[id] = bytes
            waiter.resume(returning: bytes)
        case .finish(let finish):
            let id = try finish.questionId
            answers.removeValue(forKey: id)?.cancel()
            inboundTailResults.removeValue(forKey: id)
            answerResultWaiters.removeValue(forKey: id)?.resume(
                with: .failure(CapabilityError.cancelled))
            if let tailQuestion = tailAnswerQuestions.removeValue(forKey: id) {
                await finishQuestion(tailQuestion, releaseCaps: true)
            }
            let exported = answerExportIDs.removeValue(forKey: id) ?? []
            if try finish.releaseResultCaps {
                for (exportID, count) in Dictionary(grouping: exported, by: { $0 }) {
                    try releaseExport(exportID, count: count.count)
                }
            }
            if answerDependents[id, default: 0] == 0 {
                answerCapabilities.removeValue(forKey: id)
                answerResults.removeValue(forKey: id)
            } else {
                finishedAnswers.insert(id)
            }
        case .release(let release):
            let id = try release.id
            let count = Int(try release.referenceCount)
            try releaseExport(id, count: count)
        case .resolve(let resolve): try handleResolve(resolve)
        case .disembargo(let disembargo): try await handleDisembargo(disembargo)
        case .abort(let exception): throw try remoteException(exception)
        case .unimplemented:
            throw RPCProtocolError.unsupportedMessageVariant("peer reported unimplemented")
        case .obsoleteSave, .obsoleteDelete, .provide, .accept, .join:
            throw RPCProtocolError.unsupportedMessageVariant("three-party RPC")
        case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
        }
    }

    private func allocateQuestion() throws -> UInt32 {
        guard !closed else { throw RPCConnectionError.disconnected }
        guard nextQuestionID != UInt32.max else { throw RPCConnectionError.idExhausted }
        defer { nextQuestionID += 1 }
        return nextQuestionID
    }

    private func export(_ client: CapabilityClient) throws -> UInt32 {
        try exportEntry(client).id
    }

    private func exportEntry(_ client: CapabilityClient) throws -> (id: UInt32, isNew: Bool) {
        let identity = ObjectIdentifier(client.target)
        if let id = exportIDsByTarget[identity] {
            exportReferences[id, default: 0] += 1
            return (id, false)
        }
        guard nextExportID != UInt32.max else { throw RPCConnectionError.idExhausted }
        let id = nextExportID
        nextExportID += 1
        exports[id] = client
        exportIDsByTarget[identity] = id
        exportReferences[id] = 1
        validation.exports.insert(id)
        return (id, true)
    }

    @discardableResult
    private func encodeCapability(
        _ client: CapabilityClient, into descriptor: CapDescriptor.Builder
    ) throws -> UInt32? {
        if let promised = client.target as? PromisedAnswerCapabilityTarget,
            promised.connection === self
        {
            let answer = try descriptor.initReceiverAnswer()
            try answer.setQuestionId(promised.questionID)
            if !promised.pointerFields.isEmpty {
                let transform = try answer.initTransform(count: promised.pointerFields.count)
                for (index, field) in promised.pointerFields.enumerated() {
                    try PromisedAnswer.Op.Builder(transform[index]).setGetPointerField(field)
                }
            }
            return nil
        }
        if let remote = client.target as? RemoteCapabilityTarget, remote.connection === self {
            try descriptor.setReceiverHosted(remote.importID)
            return nil
        }
        if let promise = client.target as? PromiseCapabilityTarget {
            if let resolution = promise.currentResolution {
                if case .capability(let resolved) = resolution {
                    return try encodeCapability(resolved, into: descriptor)
                }
            }
            let entry = try exportEntry(client)
            let id = entry.id
            try descriptor.setSenderPromise(id)
            if entry.isNew {
                promise.observeResolution { [weak self] resolution in
                    Task { await self?.sendPromiseResolution(id: id, resolution: resolution) }
                }
            }
            return id
        }
        let id = try export(client)
        try descriptor.setSenderHosted(id)
        return id
    }

    private func sendPromiseResolution(id: UInt32, resolution: PromiseResolution) async {
        guard exports[id] != nil, !closed else { return }
        do {
            try await sendMessage { root in
                let resolve = try root.initResolve()
                try resolve.setPromiseId(id)
                switch resolution {
                case .capability(let client):
                    try encodeCapability(client, into: resolve.initCap())
                case .exception(let exception):
                    let wire = try resolve.initException()
                    try wire.setReason(exception.reason)
                    try wire.setType(Exception.Type_(rawValue: UInt16(exception.kind.rawValue)))
                }
            }
        } catch {
            await fail(error)
        }
    }

    private func releaseExport(_ id: UInt32, count: Int) throws {
        guard count > 0, let references = exportReferences[id], references >= count,
            let client = exports[id]
        else {
            throw RPCProtocolError.unknownCapability(id)
        }
        if references == count {
            exports.removeValue(forKey: id)
            exportReferences.removeValue(forKey: id)
            exportIDsByTarget.removeValue(forKey: ObjectIdentifier(client.target))
            validation.exports.remove(id)
        } else {
            exportReferences[id] = references - count
        }
    }

    private func rollbackQuestionParamExports(_ questionID: UInt32) throws {
        let exported = questionParamExportIDs.removeValue(forKey: questionID) ?? []
        for (exportID, count) in Dictionary(grouping: exported, by: { $0 }) {
            try releaseExport(exportID, count: count.count)
        }
    }

    private func decodeTarget(_ target: MessageTarget.Reader) throws -> InboundWireTarget {
        switch try target.which {
        case .importedCap(let id): return .imported(id)
        case .promisedAnswer(let answer):
            var fields: [UInt16] = []
            for operation in try answer.transform {
                switch try operation.which {
                case .noop: break
                case .getPointerField(let field): fields.append(field)
                case .unknown: throw RPCProtocolError.invalidTransform
                }
            }
            let id = try answer.questionId
            answerDependents[id, default: 0] += 1
            return .promised(questionID: id, pointerFields: fields)
        case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
        }
    }

    private func resolveTarget(_ target: InboundWireTarget) throws -> CapabilityClient {
        switch target {
        case .imported(let id):
            guard let target = exports[id] else { throw RPCProtocolError.unknownCapability(id) }
            return target
        case .promised(let id, let fields):
            defer { releaseAnswerDependency(id) }
            if fields.isEmpty, let capability = answerCapabilities[id] { return capability }
            guard let result = answerResults[id], !fields.isEmpty else {
                throw RPCProtocolError.unknownAnswer(id)
            }
            var current = result.results
            for (index, field) in fields.enumerated() {
                let pointer = try current.anyPointerField(at: Int(field))
                if index == fields.count - 1 {
                    let tableIndex = Int(try pointer.capabilityTableIndex)
                    guard result.capabilities.indices.contains(tableIndex) else {
                        throw RPCProtocolError.unknownCapability(UInt32(tableIndex))
                    }
                    return result.capabilities[tableIndex]
                }
                current = try pointer.asStruct()
            }
            throw RPCProtocolError.invalidTransform
        }
    }

    private func releaseAnswerDependency(_ id: UInt32) {
        let remaining = max(0, answerDependents[id, default: 1] - 1)
        if remaining == 0 {
            answerDependents.removeValue(forKey: id)
            if finishedAnswers.remove(id) != nil {
                answerCapabilities.removeValue(forKey: id)
                answerResults.removeValue(forKey: id)
            }
        } else {
            answerDependents[id] = remaining
        }
    }

    private func capabilityFromReturn(
        _ message: Message.Reader, questionID: UInt32
    ) throws -> CapabilityClient {
        defer { Task { await self.finishQuestion(questionID, releaseCaps: false) } }
        guard case .return(let result) = try message.which else {
            throw RPCProtocolError.malformedMessage("expected bootstrap return")
        }
        switch try result.which {
        case .results(let payload):
            let index = Int(try payload.content.capabilityTableIndex)
            let descriptors = try payload.capTable
            guard descriptors.indices.contains(index) else {
                throw RPCProtocolError.unknownCapability(UInt32(index))
            }
            return try importCapability(descriptors[index])
        case .exception(let exception):
            throw CapabilityError.broken(try remoteException(exception))
        case .canceled: throw CapabilityError.cancelled
        default: throw RPCProtocolError.malformedMessage("invalid bootstrap return")
        }
    }

    private func importCapability(_ descriptor: CapDescriptor.Reader) throws -> CapabilityClient {
        switch try descriptor.which {
        case .none: return .null
        case .senderHosted(let id):
            importReferences[id, default: 0] += 1
            validation.imports.insert(id)
            return CapabilityClient(
                target: RemoteCapabilityTarget(importID: id, connection: self), tableIndex: id)
        case .senderPromise(let id):
            if let client = promiseClients[id] {
                importReferences[id, default: 0] += 1
                return client
            }
            let promise = CapabilityClient.makePromise()
            promiseResolvers[id] = promise.resolver
            let client = CapabilityClient(
                target: ImportedPromiseCapabilityTarget(
                    importID: id, promised: promise.client, connection: self),
                tableIndex: id)
            promiseClients[id] = client
            importReferences[id] = 1
            validation.imports.insert(id)
            validation.unresolvedPromiseImports.insert(id)
            return client
        case .receiverHosted(let id):
            guard let client = exports[id] else { throw RPCProtocolError.unknownCapability(id) }
            return client
        case .receiverAnswer(let answer):
            let id = try answer.questionId
            return CapabilityClient(
                target: ReceiverAnswerCapabilityTarget(
                    questionID: id, pointerFields: try decodeTransform(answer), connection: self))
        case .thirdPartyHosted:
            throw RPCProtocolError.unsupportedThirdPartyCapability
        case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
        }
    }

    fileprivate func releaseImport(_ id: UInt32) async {
        guard let references = importReferences[id], references > 0, !closed else { return }
        if references == 1 {
            importReferences.removeValue(forKey: id)
            validation.imports.remove(id)
        } else {
            importReferences[id] = references - 1
        }
        try? await sendMessage { root in
            let release = try root.initRelease()
            try release.setId(id)
            try release.setReferenceCount(1)
        }
    }

    private func sendResults(
        answerID: UInt32, value: CapabilityCallResult, releaseParamCaps: Bool
    ) async throws {
        try await sendMessage { root in
            let result = try root.initReturn()
            try result.setAnswerId(answerID)
            try result.setReleaseParamCaps(releaseParamCaps)
            let payload = try result.initResults()
            try payload.content.setStruct(value.results)
            if !value.capabilities.isEmpty {
                let table = try payload.initCapTable(count: value.capabilities.count)
                var exported: [UInt32] = []
                for (index, capability) in value.capabilities.enumerated() {
                    if let id = try encodeCapability(
                        capability, into: CapDescriptor.Builder(table[index]))
                    {
                        exported.append(id)
                    }
                }
                answerExportIDs[answerID] = exported
            }
        }
    }

    private func sendException(
        answerID: UInt32, error: any Error, releaseParamCaps: Bool = true
    ) async throws {
        try await sendMessage { root in
            let result = try root.initReturn()
            try result.setAnswerId(answerID)
            try result.setReleaseParamCaps(releaseParamCaps)
            let exception = try result.initException()
            let remote = Self.wireException(error)
            try exception.setReason(remote.reason)
            try exception.setType(Exception.Type_(rawValue: UInt16(remote.kind.rawValue)))
        }
    }

    private func sendTailReturn(
        answerID: UInt32, from otherQuestionID: UInt32, releaseParamCaps: Bool
    ) async throws {
        try await sendMessage { root in
            let result = try root.initReturn()
            try result.setAnswerId(answerID)
            try result.setReleaseParamCaps(releaseParamCaps)
            try result.setTakeFromOtherQuestion(otherQuestionID)
        }
    }

    private func sendResultsSentElsewhere(
        answerID: UInt32, releaseParamCaps: Bool
    ) async throws {
        try await sendMessage { root in
            let result = try root.initReturn()
            try result.setAnswerId(answerID)
            try result.setReleaseParamCaps(releaseParamCaps)
            try result.setResultsSentElsewhere()
        }
    }

    private func finishQuestion(_ id: UInt32, releaseCaps: Bool) async {
        validation.outboundQuestions.remove(id)
        validation.outboundTailQuestions.remove(id)
        validation.returnedQuestions.remove(id)
        returnedMessages.removeValue(forKey: id)
        guard !closed else { return }
        try? await sendMessage { root in
            let finish = try root.initFinish()
            try finish.setQuestionId(id)
            try finish.setReleaseResultCaps(releaseCaps)
        }
    }

    private func cancelQuestion(_ id: UInt32) async {
        pending.removeValue(forKey: id)?.resume(throwing: CapabilityError.cancelled)
        tailAdoptions.removeValue(forKey: id)?.resume(with: .failure(CapabilityError.cancelled))
        cancelledQuestionIDs.insert(id)
        validation.cancelledOutboundQuestions.insert(id)
        await finishQuestion(id, releaseCaps: true)
    }

    private func answerFinished(_ id: UInt32) { answers.removeValue(forKey: id) }

    private func completeStreamingGeneration(_ generation: UInt64) {
        if streamingGeneration == generation { streamingTail = nil }
    }

    private func recordAnswerResult(_ result: CapabilityCallResult, for id: UInt32) {
        answerResults[id] = result
        answerResultWaiters[id]?.resume(with: .success(result))
    }

    private func failAnswerResult(_ error: any Error, for id: UInt32) {
        answerResultWaiters[id]?.resume(with: .failure(error))
    }

    private func resolveReceiverAnswer(
        questionID: UInt32, pointerFields: [UInt16]
    ) async throws -> CapabilityClient {
        if pointerFields.isEmpty, let capability = answerCapabilities[questionID] {
            return capability
        }
        let result: CapabilityCallResult
        if let completed = answerResults[questionID] {
            result = completed
        } else {
            guard let waiter = answerResultWaiters[questionID] else {
                throw RPCProtocolError.unknownAnswer(questionID)
            }
            result = try await waiter.wait()
        }
        guard !pointerFields.isEmpty else { throw RPCProtocolError.invalidTransform }
        var current = result.results
        for (index, field) in pointerFields.enumerated() {
            let pointer = try current.anyPointerField(at: Int(field))
            if index == pointerFields.count - 1 {
                let tableIndex = Int(try pointer.capabilityTableIndex)
                guard result.capabilities.indices.contains(tableIndex) else {
                    throw RPCProtocolError.unknownCapability(UInt32(tableIndex))
                }
                return result.capabilities[tableIndex]
            }
            current = try pointer.asStruct()
        }
        throw RPCProtocolError.invalidTransform
    }

    private func decodeTransform(_ answer: PromisedAnswer.Reader) throws -> [UInt16] {
        var fields: [UInt16] = []
        for operation in try answer.transform {
            switch try operation.which {
            case .noop: break
            case .getPointerField(let field): fields.append(field)
            case .unknown: throw RPCProtocolError.invalidTransform
            }
        }
        return fields
    }

    private func completeInboundTail(
        _ id: UInt32, with result: Result<CapabilityCallResult, any Error>
    ) {
        inboundTailResults[id]?.resume(with: result)
    }

    private func recordTailQuestion(_ questionID: UInt32, for answerID: UInt32) {
        tailAnswerQuestions[answerID] = questionID
    }

    private func handleResolve(_ resolve: Resolve.Reader) throws {
        let id = try resolve.promiseId
        guard let resolver = promiseResolvers.removeValue(forKey: id) else {
            throw RPCProtocolError.unknownCapability(id)
        }
        switch try resolve.which {
        case .cap(let descriptor):
            if case .senderPromise(let targetID) = try descriptor.which {
                guard targetID != id, !promiseRedirectChain(from: targetID, reaches: id) else {
                    throw RPCProtocolError.promiseResolutionLoop
                }
                promiseRedirects[id] = targetID
            }
            try resolver.resolve(to: importCapability(descriptor))
        case .exception(let exception): try resolver.reject(try remoteException(exception))
        case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
        }
        validation.imports.remove(id)
        validation.unresolvedPromiseImports.remove(id)
        validation.releasedPromiseImports.remove(id)
        promiseClients.removeValue(forKey: id)
    }

    private func promiseRedirectChain(from start: UInt32, reaches target: UInt32) -> Bool {
        var current: UInt32? = start
        var visited: Set<UInt32> = []
        while let id = current, visited.insert(id).inserted {
            if id == target { return true }
            current = promiseRedirects[id]
        }
        return false
    }

    fileprivate func releaseAllImports(_ id: UInt32) async {
        guard let count = importReferences.removeValue(forKey: id), count > 0, !closed else {
            return
        }
        validation.imports.remove(id)
        if validation.unresolvedPromiseImports.remove(id) != nil {
            validation.releasedPromiseImports.insert(id)
        }
        promiseRedirects.removeValue(forKey: id)
        try? await sendMessage { root in
            let release = try root.initRelease()
            try release.setId(id)
            try release.setReferenceCount(UInt32(count))
        }
    }

    private func handleDisembargo(_ disembargo: Disembargo.Reader) async throws {
        switch try disembargo.context.which {
        case .senderLoopback(let id):
            let target = try resolveTarget(decodeTarget(try disembargo.target))
            guard capabilityIsHostedByPeer(target) else {
                throw RPCProtocolError.embargoMismatch(id)
            }
            try await sendMessage { root in
                let response = try root.initDisembargo()
                try response.setTarget(disembargo.target)
                try response.context.setReceiverLoopback(id)
            }
            validation.receiverLoopbackEmbargoes.remove(id)
        case .receiverLoopback(let id):
            guard let waiter = embargoWaiters.removeValue(forKey: id) else {
                throw RPCProtocolError.embargoMismatch(id)
            }
            waiter.resume(returning: [])
        case .accept, .provide:
            throw RPCProtocolError.unsupportedMessageVariant("three-party embargo")
        case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
        }
    }

    private func capabilityIsHostedByPeer(
        _ client: CapabilityClient, visited: Set<ObjectIdentifier> = []
    ) -> Bool {
        let identity = ObjectIdentifier(client.target)
        guard !visited.contains(identity) else { return false }
        if let remote = client.target as? RemoteCapabilityTarget {
            return remote.connection === self
        }
        guard let promise = client.target as? PromiseCapabilityTarget,
            case .capability(let resolved) = promise.currentResolution
        else { return false }
        var visited = visited
        visited.insert(identity)
        return capabilityIsHostedByPeer(resolved, visited: visited)
    }

    private func sendMessage(_ configure: (Message.Builder) throws -> Void) async throws {
        guard !closed else { throw RPCConnectionError.disconnected }
        let builder = try MessageBuilder()
        try configure(try Message.initRoot(in: builder))
        try await transport.send(builder.framedBytes)
    }

    private func fail(_ error: any Error) async {
        terminalError = String(describing: error)
        let waiters = Array(pending.values)
        pending.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
        await close()
    }

    private static func wireException(_ error: any Error) -> RemoteException {
        if let remote = error as? RemoteException { return remote }
        if case CapabilityError.broken(let remote) = error { return remote }
        if error is CancellationError || error as? CapabilityError == .cancelled {
            return RemoteException(kind: .failed, reason: "cancelled")
        }
        return RemoteException(kind: .failed, reason: String(describing: error))
    }

    private func remoteException(_ value: Exception.Reader) throws -> RemoteException {
        let kind =
            RemoteException.Kind(rawValue: UInt8(truncatingIfNeeded: try value.type.rawValue))
            ?? .failed
        return RemoteException(kind: kind, reason: try value.reason)
    }
}
