import CapnProto
import CapnProtoSchema

/// Namespace for capability RPC support.
public enum CapnProtoRPCRuntime {
    public static let isImplemented = false
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

public protocol CapabilityCallTarget: AnyObject {
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
}

public struct CapabilityClient {
    private let target: any CapabilityCallTarget
    public let tableIndex: UInt32?

    public init(target: any CapabilityCallTarget) {
        self.target = target
        tableIndex = nil
    }

    public init(pointer: AnyPointerReader) {
        target = SerializedCapabilityTarget(pointer: pointer)
        tableIndex = try? pointer.capabilityTableIndex
    }

    public init(tableIndex: UInt32) {
        target = SerializedCapabilityTarget(pointer: nil)
        self.tableIndex = tableIndex
    }

    public func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        try await target.call(method, params: params)
    }
}

public enum CapabilityError: Error, Equatable {
    case unavailableSerializedCapability
    case unserializableCapability
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
