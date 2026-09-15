import Foundation

/// An ordered asynchronous byte-stream transport. A receive returns the next
/// available chunk, or `nil` after an orderly disconnect.
public protocol RPCMessageTransport: Sendable {
    func send(_ bytes: [UInt8]) async throws
    func receive() async throws -> [UInt8]?
    func close() async
}

public enum RPCTransportError: Error, Equatable, Sendable {
    case closed
    case injected(operation: Int)
}

public struct InMemoryTransportConfiguration: Equatable, Sendable {
    public var maximumBufferedChunks: Int
    public var fragmentSize: Int?
    public var coalesceWrites: Bool
    public var failSendAt: Int?
    public var failReceiveAt: Int?
    public var eofReceiveAt: Int?

    public init(
        maximumBufferedChunks: Int = 16,
        fragmentSize: Int? = nil,
        coalesceWrites: Bool = false,
        failSendAt: Int? = nil,
        failReceiveAt: Int? = nil,
        eofReceiveAt: Int? = nil
    ) {
        self.maximumBufferedChunks = maximumBufferedChunks
        self.fragmentSize = fragmentSize
        self.coalesceWrites = coalesceWrites
        self.failSendAt = failSendAt
        self.failReceiveAt = failReceiveAt
        self.eofReceiveAt = eofReceiveAt
    }
}

public struct TransportTraceEvent: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case send, receive, close }
    public let endpoint: Int
    public let direction: Direction
    public let operation: Int
    public let byteCount: Int

    public init(endpoint: Int, direction: Direction, operation: Int, byteCount: Int) {
        self.endpoint = endpoint
        self.direction = direction
        self.operation = operation
        self.byteCount = byteCount
    }
}

public actor TransportTrace {
    private var events: [TransportTraceEvent] = []
    public init() {}
    public func record(_ event: TransportTraceEvent) { events.append(event) }
    public var snapshot: [TransportTraceEvent] { events }
}

private actor ByteMailbox {
    private struct WaitingSend {
        let id: UInt64
        let bytes: [UInt8]
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct WaitingReceive {
        let id: UInt64
        let continuation: CheckedContinuation<[UInt8]?, any Error>
    }

    private let capacity: Int
    private var buffer: [[UInt8]] = []
    private var receivers: [WaitingReceive] = []
    private var senders: [WaitingSend] = []
    private var nextWaiterID: UInt64 = 0
    private var terminalError: (any Error)?
    private var isClosed = false

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func send(_ bytes: [UInt8], coalesce: Bool) async throws {
        if isClosed { throw terminalError ?? RPCTransportError.closed }
        if !receivers.isEmpty {
            receivers.removeFirst().continuation.resume(returning: bytes)
            return
        }
        if coalesce, !buffer.isEmpty {
            buffer[buffer.count - 1].append(contentsOf: bytes)
            return
        }
        if buffer.count < capacity {
            buffer.append(bytes)
            return
        }
        let id = allocateWaiterID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    senders.append(WaitingSend(id: id, bytes: bytes, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSend(id: id) }
        }
    }

    func receive() async throws -> [UInt8]? {
        if !buffer.isEmpty {
            let value = buffer.removeFirst()
            admitWaitingSender()
            return value
        }
        if isClosed {
            if let terminalError { throw terminalError }
            return nil
        }
        let id = allocateWaiterID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    receivers.append(WaitingReceive(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelReceive(id: id) }
        }
    }

    func close(error: (any Error)? = nil) {
        guard !isClosed else { return }
        isClosed = true
        terminalError = error
        let waitingReceivers = receivers
        let waitingSenders = senders
        receivers.removeAll(keepingCapacity: false)
        senders.removeAll(keepingCapacity: false)
        for receiver in waitingReceivers {
            if let error {
                receiver.continuation.resume(throwing: error)
            } else {
                receiver.continuation.resume(returning: nil)
            }
        }
        for sender in waitingSenders {
            sender.continuation.resume(throwing: error ?? RPCTransportError.closed)
        }
    }

    private func admitWaitingSender() {
        guard !senders.isEmpty else { return }
        let sender = senders.removeFirst()
        if !receivers.isEmpty {
            receivers.removeFirst().continuation.resume(returning: sender.bytes)
        } else {
            buffer.append(sender.bytes)
        }
        sender.continuation.resume()
    }

    private func allocateWaiterID() -> UInt64 {
        let result = nextWaiterID
        nextWaiterID &+= 1
        return result
    }

    private func cancelSend(id: UInt64) {
        guard let index = senders.firstIndex(where: { $0.id == id }) else { return }
        senders.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelReceive(id: UInt64) {
        guard let index = receivers.firstIndex(where: { $0.id == id }) else { return }
        receivers.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    var pendingOperationCount: Int { senders.count + receivers.count }
}

private actor TransportWriteLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

public final class InMemoryRPCTransport: RPCMessageTransport, @unchecked Sendable {
    private let endpoint: Int
    private let inbound: ByteMailbox
    private let outbound: ByteMailbox
    private let configuration: InMemoryTransportConfiguration
    private let trace: TransportTrace?
    private let writeLock = TransportWriteLock()
    private let lock = NSLock()
    private var sendOperation = 0
    private var receiveOperation = 0
    private var closed = false

    private init(
        endpoint: Int, inbound: ByteMailbox, outbound: ByteMailbox,
        configuration: InMemoryTransportConfiguration, trace: TransportTrace?
    ) {
        self.endpoint = endpoint
        self.inbound = inbound
        self.outbound = outbound
        self.configuration = configuration
        self.trace = trace
    }

    public static func makePair(
        configuration: InMemoryTransportConfiguration = InMemoryTransportConfiguration(),
        trace: TransportTrace? = nil
    ) -> (InMemoryRPCTransport, InMemoryRPCTransport) {
        let firstInbound = ByteMailbox(capacity: configuration.maximumBufferedChunks)
        let secondInbound = ByteMailbox(capacity: configuration.maximumBufferedChunks)
        return (
            InMemoryRPCTransport(
                endpoint: 0, inbound: firstInbound, outbound: secondInbound,
                configuration: configuration, trace: trace),
            InMemoryRPCTransport(
                endpoint: 1, inbound: secondInbound, outbound: firstInbound,
                configuration: configuration, trace: trace)
        )
    }

    public func send(_ bytes: [UInt8]) async throws {
        await writeLock.acquire()
        do {
            try await sendUnlocked(bytes)
            await writeLock.release()
        } catch {
            await writeLock.release()
            throw error
        }
    }

    private func sendUnlocked(_ bytes: [UInt8]) async throws {
        let operation = lock.withLock { () -> Int in
            let result = sendOperation
            sendOperation += 1
            return result
        }
        if configuration.failSendAt == operation {
            let error = RPCTransportError.injected(operation: operation)
            await outbound.close(error: error)
            throw error
        }
        let chunks = fragments(of: bytes)
        for chunk in chunks {
            try await outbound.send(chunk, coalesce: configuration.coalesceWrites)
        }
        await trace?.record(
            TransportTraceEvent(
                endpoint: endpoint, direction: .send, operation: operation,
                byteCount: bytes.count))
    }

    public func receive() async throws -> [UInt8]? {
        let operation = lock.withLock { () -> Int in
            let result = receiveOperation
            receiveOperation += 1
            return result
        }
        if configuration.failReceiveAt == operation {
            let error = RPCTransportError.injected(operation: operation)
            await inbound.close(error: error)
            throw error
        }
        if configuration.eofReceiveAt == operation {
            await inbound.close()
            return nil
        }
        let value = try await inbound.receive()
        await trace?.record(
            TransportTraceEvent(
                endpoint: endpoint, direction: .receive, operation: operation,
                byteCount: value?.count ?? 0))
        return value
    }

    public func close() async {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        await inbound.close()
        await outbound.close()
        await trace?.record(
            TransportTraceEvent(endpoint: endpoint, direction: .close, operation: 0, byteCount: 0))
    }

    public var pendingOperationCount: Int {
        get async { await inbound.pendingOperationCount + outbound.pendingOperationCount }
    }

    private func fragments(of bytes: [UInt8]) -> [[UInt8]] {
        guard let size = configuration.fragmentSize, size > 0, bytes.count > size else {
            return [bytes]
        }
        return stride(from: 0, to: bytes.count, by: size).map {
            Array(bytes[$0..<min($0 + size, bytes.count)])
        }
    }
}
