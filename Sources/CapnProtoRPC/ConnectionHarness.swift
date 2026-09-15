import Foundation

public enum RPCConnectionError: Error, Equatable, Sendable {
    case disconnected
    case idExhausted
}

public final class RPCQuestion: @unchecked Sendable {
    public let id: UInt32
    private weak var state: RPCConnectionState?

    fileprivate init(id: UInt32, state: RPCConnectionState) {
        self.id = id
        self.state = state
    }

    public func complete() { state?.finishQuestion(id, cancelled: false) }
    public func cancel() { state?.finishQuestion(id, cancelled: true) }

    public func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            do {
                let value = try await operation()
                complete()
                return value
            } catch {
                cancel()
                throw error
            }
        } onCancel: {
            cancel()
        }
    }

    deinit { cancel() }
}

public final class RPCAnswer: @unchecked Sendable {
    public let id: UInt32
    private weak var state: RPCConnectionState?

    fileprivate init(id: UInt32, state: RPCConnectionState) {
        self.id = id
        self.state = state
    }

    public func complete() { state?.finishAnswer(id, cancelled: false) }
    public func cancel() { state?.finishAnswer(id, cancelled: true) }
    deinit { cancel() }
}

/// Transport-independent question/answer and capability lifetime state. This is
/// shared by deterministic transcripts now and the wire protocol in Milestone 6.
public final class RPCConnectionState: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let questions: Int
        public let answers: Int
        public let imports: CapabilityTable.Snapshot
        public let exports: CapabilityTable.Snapshot
        public let isDisconnected: Bool
    }

    private let lock = NSLock()
    private var nextQuestionID: UInt32 = 0
    private var nextAnswerID: UInt32 = 0
    private var questions: [UInt32: @Sendable () -> Void] = [:]
    private var answers: [UInt32: @Sendable () -> Void] = [:]
    private var disconnected = false

    public let imports = CapabilityTable()
    public let exports = CapabilityTable()

    public init() {}

    public func beginQuestion(
        onCancel: @escaping @Sendable () -> Void = {}
    ) throws -> RPCQuestion {
        let id = try lock.withLock {
            guard !disconnected else { throw RPCConnectionError.disconnected }
            guard nextQuestionID != UInt32.max else { throw RPCConnectionError.idExhausted }
            let id = nextQuestionID
            nextQuestionID += 1
            questions[id] = onCancel
            return id
        }
        return RPCQuestion(id: id, state: self)
    }

    public func beginAnswer(
        onCancel: @escaping @Sendable () -> Void = {}
    ) throws -> RPCAnswer {
        let id = try lock.withLock {
            guard !disconnected else { throw RPCConnectionError.disconnected }
            guard nextAnswerID != UInt32.max else { throw RPCConnectionError.idExhausted }
            let id = nextAnswerID
            nextAnswerID += 1
            answers[id] = onCancel
            return id
        }
        return RPCAnswer(id: id, state: self)
    }

    fileprivate func finishQuestion(_ id: UInt32, cancelled: Bool) {
        let callback = lock.withLock { questions.removeValue(forKey: id) }
        if cancelled { callback?() }
    }

    fileprivate func finishAnswer(_ id: UInt32, cancelled: Bool) {
        let callback = lock.withLock { answers.removeValue(forKey: id) }
        if cancelled { callback?() }
    }

    public func disconnect() {
        let callbacks: [@Sendable () -> Void] = lock.withLock {
            guard !disconnected else { return [] }
            disconnected = true
            let result = Array(questions.values) + Array(answers.values)
            questions.removeAll(keepingCapacity: false)
            answers.removeAll(keepingCapacity: false)
            return result
        }
        imports.removeAll()
        exports.removeAll()
        for callback in callbacks { callback() }
    }

    public var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                questions: questions.count, answers: answers.count,
                imports: imports.snapshot, exports: exports.snapshot,
                isDisconnected: disconnected)
        }
    }
}

/// Couples the deterministic transport to its lifetime state for transcript tests.
public final class RPCConnectionHarness: @unchecked Sendable {
    public let transport: any RPCMessageTransport
    public let state: RPCConnectionState

    public init(transport: any RPCMessageTransport, state: RPCConnectionState = .init()) {
        self.transport = transport
        self.state = state
    }

    public func send(_ bytes: [UInt8]) async throws { try await transport.send(bytes) }
    public func receive() async throws -> [UInt8]? { try await transport.receive() }

    public func disconnect() async {
        state.disconnect()
        await transport.close()
    }
}
