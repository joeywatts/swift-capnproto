import CapnProto
import CapnProtoSchema

/// Namespace for the capability and transport-independent RPC runtime.
public enum CapnProtoRPCRuntime {
    public static let isImplemented = true
}

public struct CapabilityMethodDescriptor: Equatable, Hashable, Sendable {
    public let interfaceID: UInt64
    public let methodID: UInt16
    public let name: String
    public let paramStructID: UInt64
    public let resultStructID: UInt64
    public let isStreaming: Bool

    public init(
        interfaceID: UInt64, methodID: UInt16, name: String,
        paramStructID: UInt64, resultStructID: UInt64, isStreaming: Bool
    ) {
        self.interfaceID = interfaceID
        self.methodID = methodID
        self.name = name
        self.paramStructID = paramStructID
        self.resultStructID = resultStructID
        self.isStreaming = isStreaming
    }
}

/// A wire-compatible exception classification. The description is safe to forward
/// to another vat; `detail` is deliberately kept separate for local diagnostics.
public struct RemoteException: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: UInt8, Equatable, Sendable {
        case failed
        case overloaded
        case disconnected
        case unimplemented
    }

    public let kind: Kind
    public let reason: String
    public let detail: String?

    public init(kind: Kind, reason: String, detail: String? = nil) {
        self.kind = kind
        self.reason = reason
        self.detail = detail
    }

    public var description: String { reason }
}

public enum CapabilityError: Error, Equatable, Sendable {
    case unavailableSerializedCapability
    case unserializableCapability
    case nullCapability
    case broken(RemoteException)
    case unsupportedInterface(UInt64)
    case unknownMethod(interfaceID: UInt64, methodID: UInt16)
    case promiseAlreadyResolved
    case promiseResolutionLoop
    case cancelled
}

/// Type-erased call target used by generated clients and the wire RPC layer.
public protocol CapabilityCallTarget: AnyObject {
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    func supports(interfaceID: UInt64) -> Bool
}

public struct CapabilityCallResult: @unchecked Sendable {
    public let results: StructReader
    public let capabilities: [CapabilityClient]

    public init(results: StructReader, capabilities: [CapabilityClient] = []) {
        self.results = results
        self.capabilities = capabilities
    }
}

/// Optional extension implemented by wire targets and services that exchange
/// capability-table entries alongside their content struct.
public protocol CapabilityCallTargetWithCaps: CapabilityCallTarget {
    func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult
}

/// Supplies schema method metadata to the wire dispatcher. This is used to
/// apply streaming flow control without serializing unrelated ordinary calls.
public protocol CapabilityMethodLookupTarget: CapabilityCallTarget {
    func methodDescriptor(interfaceID: UInt64, methodID: UInt16)
        -> CapabilityMethodDescriptor?
}

extension CapabilityCallTarget {
    public func supports(interfaceID: UInt64) -> Bool { true }
}

/// A lightweight request context for local dispatchers which want descriptor and
/// cancellation state in one value.
public struct CapabilityRequestContext {
    public let method: CapabilityMethodDescriptor
    public let params: StructReader

    public init(method: CapabilityMethodDescriptor, params: StructReader) {
        self.method = method
        self.params = params
    }

    public var isCancelled: Bool { Task.isCancelled }
    public func throwIfCancelled() throws {
        if Task.isCancelled { throw CapabilityError.cancelled }
    }
}

/// Owns result storage for the duration of a local call. The returned reader
/// retains an immutable snapshot, so it remains valid after dispatch returns.
public struct CapabilityResponseContext {
    private let message: MessageBuilder
    public let results: StructBuilder

    public init(dataWords: Int, pointerCount: Int) throws {
        let message = try MessageBuilder()
        self.message = message
        results = try message.initRootStruct(dataWords: dataWords, pointerCount: pointerCount)
    }

    public func finish() throws -> StructReader {
        try message.asReader().rootStruct()
    }
}

/// A local target backed by a generated or hand-written dispatch closure.
public final class LocalCapabilityTarget: CapabilityMethodLookupTarget, @unchecked Sendable {
    public typealias Handler = (CapabilityRequestContext) async throws -> StructReader

    private let interfaceIDs: Set<UInt64>
    private let methods: [CapabilityMethodDescriptor]
    private let handler: Handler

    public init(
        interfaceIDs: Set<UInt64>, methods: [CapabilityMethodDescriptor] = [],
        handler: @escaping Handler
    ) {
        self.interfaceIDs = interfaceIDs
        self.methods = methods
        self.handler = handler
    }

    public func methodDescriptor(interfaceID: UInt64, methodID: UInt16)
        -> CapabilityMethodDescriptor?
    {
        methods.first { $0.interfaceID == interfaceID && $0.methodID == methodID }
    }

    public func supports(interfaceID: UInt64) -> Bool {
        interfaceIDs.contains(interfaceID)
    }

    public func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        guard supports(interfaceID: method.interfaceID) else {
            throw CapabilityError.unsupportedInterface(method.interfaceID)
        }
        if Task.isCancelled { throw CapabilityError.cancelled }
        return try await handler(CapabilityRequestContext(method: method, params: params))
    }

}

public struct CapabilityClient: @unchecked Sendable {
    let target: any CapabilityCallTarget
    public let tableIndex: UInt32?

    public init(target: any CapabilityCallTarget, tableIndex: UInt32? = nil) {
        self.target = target
        self.tableIndex = tableIndex
    }

    public init(pointer: AnyPointerReader) {
        target = SerializedCapabilityTarget(pointer: pointer)
        tableIndex = try? pointer.capabilityTableIndex
    }

    public init(tableIndex: UInt32) {
        target = SerializedCapabilityTarget(pointer: nil)
        self.tableIndex = tableIndex
    }

    public static var null: CapabilityClient { CapabilityClient(target: NullCapabilityTarget()) }

    public static func broken(_ exception: RemoteException) -> CapabilityClient {
        CapabilityClient(target: BrokenCapabilityTarget(exception: exception))
    }

    public func cast(to interfaceID: UInt64) throws -> CapabilityClient {
        guard target.supports(interfaceID: interfaceID) else {
            throw CapabilityError.unsupportedInterface(interfaceID)
        }
        return self
    }

    public func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        if Task.isCancelled { throw CapabilityError.cancelled }
        do {
            return try await target.call(method, params: params)
        } catch is CancellationError {
            throw CapabilityError.cancelled
        }
    }

    public func call(
        _ method: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        if let target = target as? any CapabilityCallTargetWithCaps {
            return try await target.call(method, params: params, capabilities: capabilities)
        }
        guard capabilities.isEmpty else { throw CapabilityError.unserializableCapability }
        return CapabilityCallResult(results: try await call(method, params: params))
    }

}

private final class SerializedCapabilityTarget: CapabilityCallTarget {
    private let pointer: AnyPointerReader?

    init(pointer: AnyPointerReader?) {
        self.pointer = pointer
    }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        _ = pointer
        _ = method
        _ = params
        throw CapabilityError.unavailableSerializedCapability
    }
}

private final class NullCapabilityTarget: CapabilityCallTarget {
    func supports(interfaceID: UInt64) -> Bool { false }
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        throw CapabilityError.nullCapability
    }
}

private final class BrokenCapabilityTarget: CapabilityCallTarget {
    let exception: RemoteException
    init(exception: RemoteException) { self.exception = exception }

    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        throw CapabilityError.broken(exception)
    }
}
