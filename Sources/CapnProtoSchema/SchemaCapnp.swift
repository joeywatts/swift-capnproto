import CapnProto

/// Reviewed bootstrap bindings for the pinned Cap'n Proto `schema.capnp`.
///
/// These bindings are intentionally hand-written: they are the seed used to decode
/// `CodeGeneratorRequest` before `capnpc-swift` can generate the same APIs itself.
/// Regeneration and comparison are documented in `Documentation/SchemaBootstrap.md`.
public enum Schema {
    public typealias ID = UInt64

    public enum NodeKind: Equatable, Sendable {
        case file
        case `struct`
        case `enum`
        case interface
        case constant
        case annotation
        case unknown(UInt16)

        init(_ value: UInt16) {
            switch value {
            case 0: self = .file
            case 1: self = .struct
            case 2: self = .enum
            case 3: self = .interface
            case 4: self = .constant
            case 5: self = .annotation
            default: self = .unknown(value)
            }
        }
    }

    public enum FieldKind: Equatable, Sendable {
        case slot
        case group
        case unknown(UInt16)

        init(_ value: UInt16) {
            switch value {
            case 0: self = .slot
            case 1: self = .group
            default: self = .unknown(value)
            }
        }
    }

    public enum TypeKind: Equatable, Sendable {
        case void, bool, int8, int16, int32, int64
        case uint8, uint16, uint32, uint64
        case float32, float64, text, data, list, `enum`, `struct`, interface, anyPointer
        case unknown(UInt16)

        init(_ value: UInt16) {
            switch value {
            case 0: self = .void
            case 1: self = .bool
            case 2: self = .int8
            case 3: self = .int16
            case 4: self = .int32
            case 5: self = .int64
            case 6: self = .uint8
            case 7: self = .uint16
            case 8: self = .uint32
            case 9: self = .uint64
            case 10: self = .float32
            case 11: self = .float64
            case 12: self = .text
            case 13: self = .data
            case 14: self = .list
            case 15: self = .enum
            case 16: self = .struct
            case 17: self = .interface
            case 18: self = .anyPointer
            default: self = .unknown(value)
            }
        }
    }

    public enum ElementSize: UInt16, Sendable {
        case empty = 0
        case bit = 1
        case byte = 2
        case twoBytes = 3
        case fourBytes = 4
        case eightBytes = 5
        case pointer = 6
        case inlineComposite = 7
    }

    public enum AnyPointerKind: Equatable, Sendable {
        case anyKind
        case `struct`
        case list
        case capability
        case parameter(scopeID: ID, index: UInt16)
        case implicitMethodParameter(index: UInt16)
        case unknown(UInt16)
    }

    public struct CodeGeneratorRequest {
        private let root: StructReader
        private let sourceWordCount: Int

        public init(reader: MessageReader) throws {
            root = try reader.rootStruct()
            var words = 0
            for index in 0..<reader.segmentCount {
                words += try reader.segment(index).wordCount
            }
            sourceWordCount = words
        }

        public init(framedBytes: [UInt8], options: ReaderOptions = ReaderOptions()) throws {
            let frame = try MessageFraming.decodePrefix(framedBytes)
            guard frame.byteCount == framedBytes.count else {
                throw CapnProtoError.invalidFrame
            }
            root = try frame.reader(options: options).rootStruct()
            sourceWordCount = frame.segments.reduce(0) { $0 + $1.count / 8 }
        }

        public var nodes: [Node] {
            get throws { try structList(root.listField(at: 0), Node.init) }
        }

        public var requestedFiles: [RequestedFile] {
            get throws { try structList(root.listField(at: 1), RequestedFile.init) }
        }

        public var capnpVersion: CapnpVersion {
            get throws { CapnpVersion(try root.structField(at: 2)) }
        }

        public var sourceInfoCount: Int {
            get throws { try root.listField(at: 3).count }
        }

        /// Deep-copies the complete request graph, including fields this bootstrap
        /// layer does not interpret, into a fresh message.
        public func reencodedBytes() throws -> [UInt8] {
            // Compiler requests contain many small objects and occasionally
            // shared default-value subgraphs. Fixed-size segments avoid
            // pathological geometric over-allocation while copying them.
            guard sourceWordCount <= Int.max / 2 else {
                throw CapnProtoError.arithmeticOverflow
            }
            let message = try MessageBuilder(
                firstSegmentWords: max(4096, sourceWordCount * 2),
                allocationStrategy: .fixedSize)
            _ = try message.setRoot(copying: root)
            return try message.framedBytes
        }
    }

    public struct CapnpVersion: Equatable {
        private let value: StructReader
        init(_ value: StructReader) { self.value = value }

        public var major: UInt16 { get throws { try value.integer(atByte: 0) } }
        public var minor: UInt8 { get throws { try value.integer(atByte: 2) } }
        public var micro: UInt8 { get throws { try value.integer(atByte: 3) } }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            do {
                return try lhs.major == rhs.major && lhs.minor == rhs.minor
                    && lhs.micro == rhs.micro
            } catch {
                return false
            }
        }
    }

    public struct Node {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }

        public var id: ID { get throws { try value.integer(atByte: 0) } }
        public var displayName: String { get throws { try text(value, 0) } }
        public var displayNamePrefixLength: UInt32 {
            get throws { try value.integer(atByte: 8) }
        }
        public var scopeID: ID { get throws { try value.integer(atByte: 16) } }
        public var kind: NodeKind {
            get throws { NodeKind(try value.integer(atByte: 12)) }
        }
        public var nestedNodes: [NestedNode] {
            get throws { try structList(value.listField(at: 1), NestedNode.init) }
        }
        public var parameters: [Parameter] {
            get throws { try structList(value.listField(at: 5), Parameter.init) }
        }
        public var isGeneric: Bool { get throws { try value.bool(atBit: 288) } }
        public var startByte: UInt32 { get throws { try value.integer(atByte: 40) } }
        public var endByte: UInt32 { get throws { try value.integer(atByte: 44) } }

        public var dataWordCount: UInt16 { get throws { try value.integer(atByte: 14) } }
        public var pointerCount: UInt16 { get throws { try value.integer(atByte: 24) } }
        public var preferredListEncoding: ElementSize? {
            get throws { ElementSize(rawValue: try value.integer(atByte: 26)) }
        }
        public var isGroup: Bool { get throws { try value.bool(atBit: 224) } }
        public var discriminantCount: UInt16 { get throws { try value.integer(atByte: 30) } }
        public var discriminantOffset: UInt32 { get throws { try value.integer(atByte: 32) } }
        public var fields: [Field] {
            get throws { try structList(value.listField(at: 3), Field.init) }
        }
        public var enumerants: [Enumerant] {
            get throws { try structList(value.listField(at: 3), Enumerant.init) }
        }
        public var methods: [Method] {
            get throws { try structList(value.listField(at: 3), Method.init) }
        }
        public var superclasses: [Superclass] {
            get throws { try structList(value.listField(at: 4), Superclass.init) }
        }
        public var constantType: Type { get throws { Type(try value.structField(at: 3)) } }
        public var constantValue: Value { get throws { Value(try value.structField(at: 4)) } }
    }

    public struct Parameter {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }
        public var name: String { get throws { try text(value, 0) } }
    }

    public struct NestedNode {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }
        public var name: String { get throws { try text(value, 0) } }
        public var id: ID { get throws { try value.integer(atByte: 0) } }
    }

    public struct Field {
        public static let noDiscriminant = UInt16.max
        let value: StructReader
        init(_ value: StructReader) { self.value = value }

        public var name: String { get throws { try text(value, 0) } }
        public var codeOrder: UInt16 { get throws { try value.integer(atByte: 0) } }
        public var discriminantValue: UInt16 {
            get throws { try value.integer(atByte: 2, default: Self.noDiscriminant) }
        }
        public var kind: FieldKind { get throws { FieldKind(try value.integer(atByte: 8)) } }
        public var offset: UInt32 { get throws { try value.integer(atByte: 4) } }
        public var type: Type { get throws { Type(try value.structField(at: 2)) } }
        public var defaultValue: Value { get throws { Value(try value.structField(at: 3)) } }
        public var hadExplicitDefault: Bool { get throws { try value.bool(atBit: 128) } }
        public var groupTypeID: ID { get throws { try value.integer(atByte: 16) } }
    }

    public struct Enumerant {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }
        public var name: String { get throws { try text(value, 0) } }
        public var codeOrder: UInt16 { get throws { try value.integer(atByte: 0) } }
    }

    public struct Method {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }
        public var name: String { get throws { try text(value, 0) } }
        public var codeOrder: UInt16 { get throws { try value.integer(atByte: 0) } }
        public var paramStructType: ID { get throws { try value.integer(atByte: 8) } }
        public var resultStructType: ID { get throws { try value.integer(atByte: 16) } }
    }

    public struct Superclass {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }
        public var id: ID { get throws { try value.integer(atByte: 0) } }
    }

    public struct `Type` {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }
        public var kind: TypeKind { get throws { TypeKind(try value.integer(atByte: 0)) } }
        public var elementType: Type { get throws { Type(try value.structField(at: 0)) } }
        public var typeID: ID { get throws { try value.integer(atByte: 8) } }
        public var anyPointerKind: AnyPointerKind {
            get throws {
                switch try value.integer(atByte: 8, as: UInt16.self) {
                case 0:
                    switch try value.integer(atByte: 10, as: UInt16.self) {
                    case 0: return .anyKind
                    case 1: return .struct
                    case 2: return .list
                    case 3: return .capability
                    case let tag: return .unknown(tag)
                    }
                case 1:
                    return .parameter(
                        scopeID: try value.integer(atByte: 16),
                        index: try value.integer(atByte: 10))
                case 2:
                    return .implicitMethodParameter(index: try value.integer(atByte: 10))
                case let tag: return .unknown(tag)
                }
            }
        }
    }

    public struct Value {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }
        public var kind: TypeKind { get throws { TypeKind(try value.integer(atByte: 0)) } }
        public var boolValue: Bool { get throws { try value.bool(atBit: 16) } }
        public var int8Value: Int8 { get throws { try value.integer(atByte: 2) } }
        public var int16Value: Int16 { get throws { try value.integer(atByte: 2) } }
        public var int32Value: Int32 { get throws { try value.integer(atByte: 4) } }
        public var int64Value: Int64 { get throws { try value.integer(atByte: 8) } }
        public var uint8Value: UInt8 { get throws { try value.integer(atByte: 2) } }
        public var uint16Value: UInt16 { get throws { try value.integer(atByte: 2) } }
        public var uint32Value: UInt32 { get throws { try value.integer(atByte: 4) } }
        public var uint64Value: UInt64 { get throws { try value.integer(atByte: 8) } }
        public var float32Value: Float { get throws { try value.float32(atByte: 4) } }
        public var float64Value: Double { get throws { try value.float64(atByte: 8) } }
        public var textValue: String { get throws { try text(value, 0) } }
        public var dataValue: [UInt8] { get throws { try value.dataField(at: 0).bytes } }
        public var enumValue: UInt16 { get throws { try value.integer(atByte: 2) } }
        public var structValue: StructReader { get throws { try value.structField(at: 0) } }
        public var listValue: ListReader { get throws { try value.listField(at: 0) } }
    }

    public struct RequestedFile {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }
        public var id: ID { get throws { try value.integer(atByte: 0) } }
        public var filename: String { get throws { try text(value, 0) } }
        public var imports: [Import] {
            get throws { try structList(value.listField(at: 1), Import.init) }
        }
    }

    public struct Import {
        let value: StructReader
        init(_ value: StructReader) { self.value = value }
        public var id: ID { get throws { try value.integer(atByte: 0) } }
        public var name: String { get throws { try text(value, 0) } }
    }
}

private func structList<T>(_ list: ListReader, _ transform: (StructReader) -> T) throws -> [T] {
    var result = [T]()
    result.reserveCapacity(list.count)
    for index in 0..<list.count {
        result.append(transform(try list.structElement(at: index)))
    }
    return result
}

private func text(_ value: StructReader, _ pointer: Int) throws -> String {
    guard let result = try value.textField(at: pointer).string else {
        throw CapnProtoError.invalidText
    }
    return result
}
