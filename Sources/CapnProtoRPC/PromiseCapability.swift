import CapnProto
import Foundation

extension CapabilityClient {
    public static func makePromise() -> (client: CapabilityClient, resolver: CapabilityResolver) {
        let target = PromiseCapabilityTarget()
        return (CapabilityClient(target: target), CapabilityResolver(target: target))
    }

    /// Starts a call without awaiting its results, enabling generated pipeline
    /// accessors to enqueue calls on capabilities contained in the eventual result.
    public func startCall(
        _ method: CapabilityMethodDescriptor, params: StructReader
    ) -> CapabilityCall {
        CapabilityCall(client: self, method: method, params: params)
    }
}

public struct CapabilityCall: Sendable {
    private final class Storage: @unchecked Sendable {
        let task: Task<StructReader, any Error>

        init(client: CapabilityClient, method: CapabilityMethodDescriptor, params: StructReader) {
            task = Task { try await client.call(method, params: params) }
        }

        deinit { task.cancel() }
    }

    private let storage: Storage

    fileprivate init(
        client: CapabilityClient, method: CapabilityMethodDescriptor, params: StructReader
    ) {
        storage = Storage(client: client, method: method, params: params)
    }

    public func response() async throws -> StructReader {
        do { return try await storage.task.value } catch is CancellationError {
            throw CapabilityError.cancelled
        }
    }

    public func cancel() { storage.task.cancel() }

    /// Creates a promise capability by applying a generated field transform to
    /// the eventual result. Calls on the returned client queue immediately.
    public func pipelineCapability(
        _ transform: @escaping @Sendable (StructReader) throws -> CapabilityClient
    ) -> CapabilityClient {
        let promise = CapabilityClient.makePromise()
        Task {
            do {
                try promise.resolver.resolve(to: transform(try await response()))
            } catch let exception as RemoteException {
                try? promise.resolver.reject(exception)
            } catch {
                try? promise.resolver.reject(
                    RemoteException(kind: .failed, reason: String(describing: error)))
            }
        }
        return promise.client
    }
}

public final class CapabilityResolver: @unchecked Sendable {
    private let target: PromiseCapabilityTarget
    init(target: PromiseCapabilityTarget) { self.target = target }

    public func resolve(to client: CapabilityClient) throws {
        try target.resolve(to: client)
    }

    public func reject(_ exception: RemoteException) throws {
        try target.reject(exception)
    }

    public var pendingCallCount: Int { target.pendingCallCount }
}

private struct PendingCapabilityCall: @unchecked Sendable {
    let sequence: UInt64
    let method: CapabilityMethodDescriptor
    let params: StructReader
    let continuation: CheckedContinuation<StructReader, any Error>
}

private enum PromiseState {
    case unresolved
    case resolved(CapabilityClient)
    case rejected(RemoteException)
}

final class PromiseCapabilityTarget: CapabilityCallTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PromiseState = .unresolved
    private var calls: [PendingCapabilityCall] = []
    private var nextSequence: UInt64 = 0

    var pendingCallCount: Int { lock.withLock { calls.count } }

    func supports(interfaceID: UInt64) -> Bool {
        lock.withLock {
            if case .resolved(let client) = state {
                return client.target.supports(interfaceID: interfaceID)
            }
            return true
        }
    }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        if Task.isCancelled { throw CapabilityError.cancelled }
        let sequence = lock.withLock { () -> UInt64 in
            let value = nextSequence
            nextSequence &+= 1
            return value
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action: PromiseState = lock.withLock {
                    switch state {
                    case .unresolved:
                        if Task.isCancelled { return .rejected(cancelledException) }
                        calls.append(
                            PendingCapabilityCall(
                                sequence: sequence, method: method, params: params,
                                continuation: continuation))
                        return .unresolved
                    case .resolved(let client): return .resolved(client)
                    case .rejected(let exception): return .rejected(exception)
                    }
                }
                switch action {
                case .unresolved:
                    break
                case .resolved(let client):
                    Task {
                        do {
                            continuation.resume(
                                returning: try await client.call(method, params: params))
                        } catch { continuation.resume(throwing: error) }
                    }
                case .rejected(let exception) where exception == cancelledException:
                    continuation.resume(throwing: CapabilityError.cancelled)
                case .rejected(let exception):
                    continuation.resume(throwing: CapabilityError.broken(exception))
                }
            }
        } onCancel: {
            cancel(sequence: sequence)
        }
    }

    private var cancelledException: RemoteException {
        RemoteException(kind: .failed, reason: "cancelled")
    }

    private func cancel(sequence: UInt64) {
        let continuation: CheckedContinuation<StructReader, any Error>? = lock.withLock {
            guard let index = calls.firstIndex(where: { $0.sequence == sequence }) else {
                return nil
            }
            return calls.remove(at: index).continuation
        }
        continuation?.resume(throwing: CapabilityError.cancelled)
    }

    fileprivate func resolve(to client: CapabilityClient) throws {
        if let other = client.target as? PromiseCapabilityTarget {
            guard other !== self, !other.redirects(to: self, visited: []) else {
                throw CapabilityError.promiseResolutionLoop
            }
        }
        let pending: [PendingCapabilityCall] = try lock.withLock {
            guard case .unresolved = state else { throw CapabilityError.promiseAlreadyResolved }
            state = .resolved(client)
            let result = calls.sorted { $0.sequence < $1.sequence }
            calls.removeAll(keepingCapacity: false)
            return result
        }
        guard !pending.isEmpty else { return }
        Task {
            for call in pending {
                do {
                    call.continuation.resume(
                        returning: try await client.call(call.method, params: call.params))
                } catch {
                    call.continuation.resume(throwing: error)
                }
            }
        }
    }

    fileprivate func reject(_ exception: RemoteException) throws {
        let pending: [PendingCapabilityCall] = try lock.withLock {
            guard case .unresolved = state else { throw CapabilityError.promiseAlreadyResolved }
            state = .rejected(exception)
            let result = calls
            calls.removeAll(keepingCapacity: false)
            return result
        }
        for call in pending {
            call.continuation.resume(throwing: CapabilityError.broken(exception))
        }
    }

    private func redirects(to needle: PromiseCapabilityTarget, visited: Set<ObjectIdentifier>)
        -> Bool
    {
        if self === needle { return true }
        let identifier = ObjectIdentifier(self)
        guard !visited.contains(identifier) else { return false }
        var nextVisited = visited
        nextVisited.insert(identifier)
        return lock.withLock {
            guard case .resolved(let client) = state,
                let next = client.target as? PromiseCapabilityTarget
            else { return false }
            return next.redirects(to: needle, visited: nextVisited)
        }
    }
}
