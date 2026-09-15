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

private final class PendingWireQuestion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[UInt8], any Error>?

    func wait() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func resume(returning value: [UInt8]) {
        lock.withLock { continuation.take() }?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.withLock { continuation.take() }?.resume(throwing: error)
    }
}

private extension Optional {
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}

private final class RemoteCapabilityTarget: CapabilityCallTarget, @unchecked Sendable {
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

    deinit {
        guard let connection else { return }
        let id = importID
        Task { await connection.releaseImport(id) }
    }
}

private final class PromisedAnswerCapabilityTarget: CapabilityCallTarget, @unchecked Sendable {
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
            method: method, params: params)
    }
}

private enum WireCallTarget: Sendable {
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
    private var answers: [UInt32: Task<Void, Never>] = [:]
    private var exports: [UInt32: CapabilityClient] = [:]
    private var importReferences: [UInt32: Int] = [:]
    private var promiseResolvers: [UInt32: CapabilityResolver] = [:]
    private var promiseClients: [UInt32: CapabilityClient] = [:]
    private var answerCapabilities: [UInt32: CapabilityClient] = [:]
    private var streamingTail: Task<Void, Never>?
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
        return try await performCall(
            target: .imported(importID), method: method, params: params)
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

    fileprivate func callPromised(
        questionID: UInt32, pointerFields: [UInt16],
        method: CapabilityMethodDescriptor, params: StructReader
    ) async throws -> StructReader {
        guard validation.outboundQuestions.contains(questionID) else {
            throw RPCProtocolError.unknownQuestion(questionID)
        }
        return try await performCall(
            target: .promised(questionID: questionID, pointerFields: pointerFields),
            method: method, params: params)
    }

    private func performCall(
        target: WireCallTarget, method: CapabilityMethodDescriptor, params: StructReader
    ) async throws -> StructReader {
        let id = try allocateQuestion()
        let waiter = PendingWireQuestion()
        pending[id] = waiter
        validation.outboundQuestions.insert(id)
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
                            try PromisedAnswer.Op.Builder(transform[index]).setGetPointerField(field)
                        }
                    }
                }
                try call.setInterfaceId(method.interfaceID)
                try call.setMethodId(method.methodID)
                let payload = try call.initParams()
                try payload.content.setStruct(params)
            }
            let bytes = try await withTaskCancellationHandler {
                try await waiter.wait()
            } onCancel: {
                Task { await self.cancelQuestion(id) }
            }
            defer { Task { await self.finishQuestion(id, releaseCaps: true) } }
            let wire = try RPCWireValidator.decode(bytes, maximumWords: maximumMessageWords)
            guard case .return(let result) = try wire.which else {
                throw RPCProtocolError.malformedMessage("expected return")
            }
            switch try result.which {
            case .results(let payload): return try payload.content.asStruct()
            case .exception(let exception):
                throw CapabilityError.broken(try remoteException(exception))
            case .canceled: throw CapabilityError.cancelled
            case .takeFromOtherQuestion(let other):
                guard let otherWaiter = pending[other] else {
                    throw RPCProtocolError.unknownQuestion(other)
                }
                let otherBytes = try await otherWaiter.wait()
                let otherMessage = try RPCWireValidator.decode(
                    otherBytes, maximumWords: maximumMessageWords)
                guard case .return(let otherReturn) = try otherMessage.which,
                    case .results(let payload) = try otherReturn.which
                else { throw RPCProtocolError.malformedMessage("invalid tail return") }
                return try payload.content.asStruct()
            case .resultsSentElsewhere:
                throw RPCProtocolError.malformedMessage("results sent elsewhere")
            case .acceptFromThirdParty:
                throw RPCProtocolError.unsupportedMessageVariant("third-party return")
            case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
            }
        } catch {
            pending.removeValue(forKey: id)
            validation.outboundQuestions.remove(id)
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
        let work = Array(answers.values)
        answers.removeAll()
        exports.removeAll()
        importReferences.removeAll()
        promiseResolvers.removeAll()
        promiseClients.removeAll()
        answerCapabilities.removeAll()
        validation = RPCWireValidationState()
        streamingTail?.cancel()
        streamingTail = nil
        for task in work { task.cancel() }
        for waiter in waiters { waiter.resume(throwing: RPCConnectionError.disconnected) }
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
            let target = try resolveTarget(try call.target)
            let method = CapabilityMethodDescriptor(
                interfaceID: try call.interfaceId, methodID: try call.methodId,
                name: "wire", paramStructID: 0, resultStructID: 0,
                isStreaming: false)
            let params = try call.params.content.asStruct()
            let preceding = streamingTail
            let task = Task { [weak self] in
                await preceding?.value
                do {
                    let value = try await target.call(method, params: params)
                    try await self?.sendResults(answerID: id, value: value)
                } catch {
                    try? await self?.sendException(answerID: id, error: error)
                }
                await self?.answerFinished(id)
            }
            answers[id] = task
            streamingTail = task
        case .return(let result):
            let id = try result.answerId
            guard let waiter = pending.removeValue(forKey: id) else {
                throw RPCProtocolError.unknownQuestion(id)
            }
            waiter.resume(returning: bytes)
        case .finish(let finish):
            let id = try finish.questionId
            answers.removeValue(forKey: id)?.cancel()
            answerCapabilities.removeValue(forKey: id)
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
        guard nextExportID != UInt32.max else { throw RPCConnectionError.idExhausted }
        let id = nextExportID
        nextExportID += 1
        exports[id] = client
        validation.exports.insert(id)
        return id
    }

    private func releaseExport(_ id: UInt32, count: Int) throws {
        guard count > 0, exports.removeValue(forKey: id) != nil else {
            throw RPCProtocolError.unknownCapability(id)
        }
        validation.exports.remove(id)
    }

    private func resolveTarget(_ target: MessageTarget.Reader) throws -> CapabilityClient {
        switch try target.which {
        case .importedCap(let id):
            guard let target = exports[id] else { throw RPCProtocolError.unknownCapability(id) }
            return target
        case .promisedAnswer:
            let answer = try target.promisedAnswer
            let id = try answer.questionId
            guard let capability = answerCapabilities[id] else {
                throw RPCProtocolError.unknownAnswer(id)
            }
            for operation in try answer.transform {
                switch try operation.which {
                case .noop: break
                case .getPointerField:
                    throw RPCProtocolError.invalidTransform
                case .unknown: throw RPCProtocolError.invalidTransform
                }
            }
            return capability
        case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
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
            return CapabilityClient(target: RemoteCapabilityTarget(importID: id, connection: self))
        case .senderPromise(let id):
            if let client = promiseClients[id] {
                importReferences[id, default: 0] += 1
                return client
            }
            let promise = CapabilityClient.makePromise()
            promiseResolvers[id] = promise.resolver
            promiseClients[id] = promise.client
            importReferences[id] = 1
            validation.imports.insert(id)
            return promise.client
        case .receiverHosted(let id):
            guard let client = exports[id] else { throw RPCProtocolError.unknownCapability(id) }
            return client
        case .receiverAnswer, .thirdPartyHosted:
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

    private func sendResults(answerID: UInt32, value: StructReader) async throws {
        try await sendMessage { root in
            let result = try root.initReturn()
            try result.setAnswerId(answerID)
            let payload = try result.initResults()
            try payload.content.setStruct(value)
        }
    }

    private func sendException(answerID: UInt32, error: any Error) async throws {
        try await sendMessage { root in
            let result = try root.initReturn()
            try result.setAnswerId(answerID)
            let exception = try result.initException()
            let remote = Self.wireException(error)
            try exception.setReason(remote.reason)
            try exception.setType(Exception.Type_(rawValue: UInt16(remote.kind.rawValue)))
        }
    }

    private func finishQuestion(_ id: UInt32, releaseCaps: Bool) async {
        validation.outboundQuestions.remove(id)
        validation.returnedQuestions.remove(id)
        guard !closed else { return }
        try? await sendMessage { root in
            let finish = try root.initFinish()
            try finish.setQuestionId(id)
            try finish.setReleaseResultCaps(releaseCaps)
        }
    }

    private func cancelQuestion(_ id: UInt32) async {
        pending.removeValue(forKey: id)?.resume(throwing: CapabilityError.cancelled)
        await finishQuestion(id, releaseCaps: true)
    }

    private func answerFinished(_ id: UInt32) { answers.removeValue(forKey: id) }

    private func handleResolve(_ resolve: Resolve.Reader) throws {
        let id = try resolve.promiseId
        guard let resolver = promiseResolvers.removeValue(forKey: id) else {
            throw RPCProtocolError.unknownCapability(id)
        }
        switch try resolve.which {
        case .cap(let descriptor): try resolver.resolve(to: importCapability(descriptor))
        case .exception(let exception): try resolver.reject(try remoteException(exception))
        case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
        }
        validation.imports.remove(id)
        importReferences.removeValue(forKey: id)
        promiseClients.removeValue(forKey: id)
    }

    private func handleDisembargo(_ disembargo: Disembargo.Reader) async throws {
        if case .receiverLoopback(let id) = try disembargo.context.which {
            try await sendMessage { root in
                let response = try root.initDisembargo()
                try response.setTarget(disembargo.target)
                try response.context.setSenderLoopback(id)
            }
        }
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
        let kind = RemoteException.Kind(rawValue: UInt8(truncatingIfNeeded: try value.type.rawValue))
            ?? .failed
        return RemoteException(kind: kind, reason: try value.reason)
    }
}
