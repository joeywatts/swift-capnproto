import CapnProto

public enum SchemaError: Error, Equatable, CustomStringConvertible {
    case duplicateID(Schema.ID)
    case duplicateName(String)
    case missingSchema(Schema.ID)
    case invalidNode(Schema.ID, String)
    case kindMismatch(expected: String, actual: String)
    case incompatibleReplacement(Schema.ID)
    case unknownNodeKind(UInt16)
    case unknownTypeKind(UInt16)

    public var description: String {
        switch self {
        case .duplicateID(let id): "duplicate schema ID \(hexID(id))"
        case .duplicateName(let name): "duplicate schema name '\(name)'"
        case .missingSchema(let id): "missing schema \(hexID(id))"
        case .invalidNode(let id, let reason): "invalid schema \(hexID(id)): \(reason)"
        case .kindMismatch(let expected, let actual):
            "schema kind mismatch: expected \(expected), got \(actual)"
        case .incompatibleReplacement(let id):
            "schema \(hexID(id)) cannot be replaced by an incompatible definition"
        case .unknownNodeKind(let tag): "unknown schema node kind \(tag)"
        case .unknownTypeKind(let tag): "unknown schema type kind \(tag)"
        }
    }
}

public enum AnyPointerConstraint: Equatable, Sendable {
    case any, `struct`, list, capability
    case parameter(scopeID: Schema.ID, index: UInt16)
    case implicitMethodParameter(index: UInt16)
}

public indirect enum SchemaType: Equatable, Sendable {
    case void, bool, int8, int16, int32, int64
    case uint8, uint16, uint32, uint64
    case float32, float64, text, data
    case list(SchemaType)
    case enumeration(id: Schema.ID, brand: SchemaBrand)
    case structure(id: Schema.ID, brand: SchemaBrand)
    case interface(id: Schema.ID, brand: SchemaBrand)
    case anyPointer(AnyPointerConstraint)
}

public struct SchemaBrand: Equatable, Sendable {
    public var scopes: [SchemaBrandScope]
    public init(scopes: [SchemaBrandScope] = []) { self.scopes = scopes }
}

public struct SchemaBrandScope: Equatable, Sendable {
    public enum Binding: Equatable, Sendable {
        case inherit
        case bindings([SchemaBrandBinding])
    }

    public var scopeID: Schema.ID
    public var binding: Binding

    public init(scopeID: Schema.ID, binding: Binding) {
        self.scopeID = scopeID
        self.binding = binding
    }
}

public enum SchemaBrandBinding: Equatable, Sendable {
    case unbound
    case type(SchemaType)
}

public enum SchemaDefaultValue {
    case void, bool(Bool)
    case int8(Int8), int16(Int16), int32(Int32), int64(Int64)
    case uint8(UInt8), uint16(UInt16), uint32(UInt32), uint64(UInt64)
    case float32(Float), float64(Double), text(String), data([UInt8])
    case list(ListReader), enumeration(UInt16), structure(StructReader)
    case interface, anyPointer(AnyPointerReader)
}

public struct SchemaAnnotation {
    public var id: Schema.ID
    public var brand: SchemaBrand
    public var value: SchemaDefaultValue

    public init(id: Schema.ID, brand: SchemaBrand = SchemaBrand(), value: SchemaDefaultValue) {
        self.id = id
        self.brand = brand
        self.value = value
    }
}

public struct SchemaField {
    public enum Storage {
        case slot(offset: UInt32, type: SchemaType, defaultValue: SchemaDefaultValue)
        case group(typeID: Schema.ID)
    }

    public var name: String
    public var codeOrder: UInt16
    public var discriminantValue: UInt16?
    public var storage: Storage
    public var hadExplicitDefault: Bool
    public var annotations: [SchemaAnnotation]

    public init(
        name: String, codeOrder: UInt16, discriminantValue: UInt16? = nil,
        storage: Storage, hadExplicitDefault: Bool = false,
        annotations: [SchemaAnnotation] = []
    ) {
        self.name = name
        self.codeOrder = codeOrder
        self.discriminantValue = discriminantValue
        self.storage = storage
        self.hadExplicitDefault = hadExplicitDefault
        self.annotations = annotations
    }
}

public struct SchemaEnumerant {
    public var name: String
    public var codeOrder: UInt16
    public var annotations: [SchemaAnnotation]

    public init(name: String, codeOrder: UInt16, annotations: [SchemaAnnotation] = []) {
        self.name = name
        self.codeOrder = codeOrder
        self.annotations = annotations
    }
}

public struct SchemaMethod {
    public var name: String
    public var codeOrder: UInt16
    public var paramStructType: Schema.ID
    public var resultStructType: Schema.ID
    public var isStreaming: Bool
    public var implicitParameters: [String]
    public var paramBrand: SchemaBrand
    public var resultBrand: SchemaBrand
    public var annotations: [SchemaAnnotation]

    public init(
        name: String, codeOrder: UInt16, paramStructType: Schema.ID,
        resultStructType: Schema.ID, isStreaming: Bool = false,
        implicitParameters: [String] = [], paramBrand: SchemaBrand = SchemaBrand(),
        resultBrand: SchemaBrand = SchemaBrand(), annotations: [SchemaAnnotation] = []
    ) {
        self.name = name
        self.codeOrder = codeOrder
        self.paramStructType = paramStructType
        self.resultStructType = resultStructType
        self.isStreaming = isStreaming
        self.implicitParameters = implicitParameters
        self.paramBrand = paramBrand
        self.resultBrand = resultBrand
        self.annotations = annotations
    }
}

public struct SchemaSuperclass: Equatable, Sendable {
    public var id: Schema.ID
    public var brand: SchemaBrand

    public init(id: Schema.ID, brand: SchemaBrand = SchemaBrand()) {
        self.id = id
        self.brand = brand
    }
}

public enum AnnotationTarget: String, CaseIterable, Hashable, Sendable {
    case file, constant, enumeration, enumerant, structure, field
    case union, group, interface, method, parameter, annotation
}

public enum SchemaNodeKind {
    case file
    case structure(
        dataWordCount: UInt16, pointerCount: UInt16,
        preferredListEncoding: Schema.ElementSize, isGroup: Bool,
        discriminantCount: UInt16, discriminantOffset: UInt32,
        fields: [SchemaField])
    case enumeration([SchemaEnumerant])
    case interface(methods: [SchemaMethod], superclasses: [SchemaSuperclass])
    case constant(type: SchemaType, value: SchemaDefaultValue)
    case annotation(type: SchemaType, targets: Set<AnnotationTarget>)
}

public struct SchemaNode {
    public var id: Schema.ID
    public var displayName: String
    public var displayNamePrefixLength: UInt32
    public var scopeID: Schema.ID
    public var parameters: [String]
    public var isGeneric: Bool
    public var nestedNodes: [String: Schema.ID]
    public var importIDs: Set<Schema.ID>
    public var annotations: [SchemaAnnotation]
    public var kind: SchemaNodeKind

    public init(
        id: Schema.ID, displayName: String, displayNamePrefixLength: UInt32 = 0,
        scopeID: Schema.ID = 0, parameters: [String] = [], isGeneric: Bool = false,
        nestedNodes: [String: Schema.ID] = [:], annotations: [SchemaAnnotation] = [],
        importIDs: Set<Schema.ID> = [], kind: SchemaNodeKind
    ) {
        self.id = id
        self.displayName = displayName
        self.displayNamePrefixLength = displayNamePrefixLength
        self.scopeID = scopeID
        self.parameters = parameters
        self.isGeneric = isGeneric
        self.nestedNodes = nestedNodes
        self.importIDs = importIDs
        self.annotations = annotations
        self.kind = kind
    }

    public var unqualifiedName: String {
        let bytes = Array(displayName.utf8)
        let prefix = min(Int(displayNamePrefixLength), bytes.count)
        return String(decoding: bytes[prefix...], as: UTF8.self)
    }

    public var kindName: String {
        switch kind {
        case .file: "file"
        case .structure: "struct"
        case .enumeration: "enum"
        case .interface: "interface"
        case .constant: "constant"
        case .annotation: "annotation"
        }
    }

    public func field(named name: String) -> SchemaField? {
        guard case .structure(_, _, _, _, _, _, let fields) = kind else { return nil }
        return fields.first { $0.name == name }
    }

    public func enumerant(named name: String) -> SchemaEnumerant? {
        guard case .enumeration(let values) = kind else { return nil }
        return values.first { $0.name == name }
    }

    public func method(named name: String) -> SchemaMethod? {
        guard case .interface(let methods, _) = kind else { return nil }
        return methods.first { $0.name == name }
    }

    public var dependencyIDs: Set<Schema.ID> {
        var result = Set<Schema.ID>()
        result.formUnion(importIDs)
        if scopeID != 0 { result.insert(scopeID) }
        result.formUnion(nestedNodes.values)
        func add(_ type: SchemaType) {
            switch type {
            case .list(let element): add(element)
            case .enumeration(let id, let brand), .structure(let id, let brand),
                .interface(let id, let brand):
                result.insert(id)
                for scope in brand.scopes {
                    if scope.scopeID != 0 { result.insert(scope.scopeID) }
                    if case .bindings(let bindings) = scope.binding {
                        for binding in bindings {
                            if case .type(let type) = binding { add(type) }
                        }
                    }
                }
            case .anyPointer(.parameter(let id, _)): result.insert(id)
            default: break
            }
        }
        switch kind {
        case .structure(_, _, _, _, _, _, let fields):
            for field in fields {
                switch field.storage {
                case .slot(_, let type, _): add(type)
                case .group(let id): result.insert(id)
                }
            }
        case .interface(let methods, let supers):
            result.formUnion(supers.map(\.id))
            for method in methods {
                result.insert(method.paramStructType)
                result.insert(method.resultStructType)
            }
        case .constant(let type, _), .annotation(let type, _): add(type)
        default: break
        }
        for annotation in annotations { result.insert(annotation.id) }
        result.remove(id)
        return result
    }

    /// Dependencies required for dynamic use. Lexical parents and `nestedNodes`
    /// are optional because compiler requests may omit nested constants and the
    /// loader supports loading children before their parents.
    public var requiredDependencyIDs: Set<Schema.ID> {
        var result = importIDs
        func add(_ type: SchemaType) {
            switch type {
            case .list(let element): add(element)
            case .enumeration(let id, let brand), .structure(let id, let brand),
                .interface(let id, let brand):
                result.insert(id)
                for scope in brand.scopes {
                    if case .bindings(let bindings) = scope.binding {
                        for binding in bindings {
                            if case .type(let type) = binding { add(type) }
                        }
                    }
                }
            case .anyPointer(.parameter(let id, _)): result.insert(id)
            default: break
            }
        }
        switch kind {
        case .structure(_, _, _, _, _, _, let fields):
            for field in fields {
                switch field.storage {
                case .slot(_, let type, _): add(type)
                case .group(let id): result.insert(id)
                }
                for annotation in field.annotations { result.insert(annotation.id) }
            }
        case .interface(let methods, let supers):
            result.formUnion(supers.map(\.id))
            for method in methods {
                result.insert(method.paramStructType)
                result.insert(method.resultStructType)
                for annotation in method.annotations { result.insert(annotation.id) }
            }
        case .constant(let type, _), .annotation(let type, _): add(type)
        default: break
        }
        for annotation in annotations { result.insert(annotation.id) }
        result.remove(id)
        return result
    }
}

public struct SchemaRegistry {
    private var nodesByID: [Schema.ID: SchemaNode] = [:]
    private var idsByName: [String: Schema.ID] = [:]

    public init() {}
    public var count: Int { nodesByID.count }
    public var nodes: [SchemaNode] { nodesByID.values.sorted { $0.id < $1.id } }

    public func schema(id: Schema.ID) -> SchemaNode? { nodesByID[id] }
    public func schema(named name: String) -> SchemaNode? {
        idsByName[name].flatMap { nodesByID[$0] }
    }

    public func requireSchema(id: Schema.ID) throws -> SchemaNode {
        guard let node = nodesByID[id] else { throw SchemaError.missingSchema(id) }
        return node
    }

    public func dependency(_ id: Schema.ID, of owner: SchemaNode) throws -> SchemaNode {
        guard id == owner.id || owner.dependencyIDs.contains(id) else {
            throw SchemaError.invalidNode(owner.id, "\(hexID(id)) is not a dependency")
        }
        return try requireSchema(id: id)
    }

    mutating func insert(_ node: SchemaNode, replacing: Bool = false) throws {
        try validateNode(node)
        if let priorID = idsByName[node.displayName], priorID != node.id {
            throw SchemaError.duplicateName(node.displayName)
        }
        if nodesByID[node.id] != nil, !replacing {
            throw SchemaError.duplicateID(node.id)
        } else if let old = nodesByID[node.id] {
            idsByName.removeValue(forKey: old.displayName)
        }
        nodesByID[node.id] = node
        idsByName[node.displayName] = node.id
    }

    public func validateGraph() throws {
        for node in nodesByID.values {
            for dependency in node.requiredDependencyIDs where nodesByID[dependency] == nil {
                throw SchemaError.invalidNode(
                    node.id, "required dependency \(hexID(dependency)) is not loaded")
            }
            for (name, childID) in node.nestedNodes {
                guard let child = schema(id: childID) else { continue }
                guard child.scopeID == node.id else {
                    throw SchemaError.invalidNode(node.id, "nested node '\(name)' has wrong scope")
                }
            }
        }
    }
}

extension SchemaNode {
    init(proto: Schema.Node) throws {
        id = try proto.id
        displayName = try proto.displayName
        displayNamePrefixLength = try proto.displayNamePrefixLength
        scopeID = try proto.scopeID
        parameters = try proto.parameters.map { try $0.name }
        isGeneric = try proto.isGeneric
        nestedNodes = try uniqueDictionary(proto.nestedNodes.map { (try $0.name, try $0.id) })
        importIDs = []
        annotations = try proto.annotations.map(SchemaAnnotation.init)
        switch try proto.kind {
        case .file: kind = .file
        case .struct:
            guard let encoding = try proto.preferredListEncoding else {
                throw SchemaError.invalidNode(id, "unknown preferred list encoding")
            }
            kind = try .structure(
                dataWordCount: proto.dataWordCount, pointerCount: proto.pointerCount,
                preferredListEncoding: encoding, isGroup: proto.isGroup,
                discriminantCount: proto.discriminantCount,
                discriminantOffset: proto.discriminantOffset,
                fields: proto.fields.map(SchemaField.init))
        case .enum:
            kind = try .enumeration(
                proto.enumerants.map {
                    SchemaEnumerant(
                        name: try $0.name, codeOrder: try $0.codeOrder,
                        annotations: try $0.annotations.map(SchemaAnnotation.init))
                })
        case .interface:
            kind = try .interface(
                methods: proto.methods.map {
                    SchemaMethod(
                        name: try $0.name, codeOrder: try $0.codeOrder,
                        paramStructType: try $0.paramStructType,
                        resultStructType: try $0.resultStructType,
                        isStreaming: try $0.isStreaming,
                        implicitParameters: try $0.implicitParameters.map { try $0.name },
                        paramBrand: try SchemaBrand($0.paramBrand),
                        resultBrand: try SchemaBrand($0.resultBrand),
                        annotations: try $0.annotations.map(SchemaAnnotation.init))
                },
                superclasses: proto.superclasses.map {
                    try SchemaSuperclass(id: $0.id, brand: SchemaBrand($0.brand))
                })
        case .constant:
            kind = try .constant(
                type: SchemaType(proto.constantType), value: SchemaDefaultValue(proto.constantValue)
            )
        case .annotation:
            var targets = Set<AnnotationTarget>()
            for (index, target) in AnnotationTarget.allCases.enumerated()
            where try proto.value.bool(atBit: 112 + index) { targets.insert(target) }
            kind = try .annotation(type: SchemaType(proto.constantType), targets: targets)
        case .unknown(let tag): throw SchemaError.unknownNodeKind(tag)
        }
        try validateNode(self)
    }
}

extension SchemaType {
    init(_ proto: Schema.`Type`) throws {
        switch try proto.kind {
        case .void: self = .void
        case .bool: self = .bool
        case .int8: self = .int8
        case .int16: self = .int16
        case .int32: self = .int32
        case .int64: self = .int64
        case .uint8: self = .uint8
        case .uint16: self = .uint16
        case .uint32: self = .uint32
        case .uint64: self = .uint64
        case .float32: self = .float32
        case .float64: self = .float64
        case .text: self = .text
        case .data: self = .data
        case .list: self = try .list(SchemaType(proto.elementType))
        case .enum: self = try .enumeration(id: proto.typeID, brand: SchemaBrand(proto.brand))
        case .struct: self = try .structure(id: proto.typeID, brand: SchemaBrand(proto.brand))
        case .interface: self = try .interface(id: proto.typeID, brand: SchemaBrand(proto.brand))
        case .anyPointer:
            switch try proto.anyPointerKind {
            case .anyKind: self = .anyPointer(.any)
            case .struct: self = .anyPointer(.struct)
            case .list: self = .anyPointer(.list)
            case .capability: self = .anyPointer(.capability)
            case .parameter(let id, let index):
                self = .anyPointer(.parameter(scopeID: id, index: index))
            case .implicitMethodParameter(let index):
                self = .anyPointer(.implicitMethodParameter(index: index))
            case .unknown(let tag): throw SchemaError.unknownTypeKind(tag)
            }
        case .unknown(let tag): throw SchemaError.unknownTypeKind(tag)
        }
    }
}

extension SchemaBrand {
    init(_ proto: Schema.Brand) throws {
        scopes = try proto.scopes.map {
            if try $0.isInherit {
                return SchemaBrandScope(scopeID: try $0.scopeID, binding: .inherit)
            }
            return try SchemaBrandScope(
                scopeID: $0.scopeID,
                binding: .bindings(
                    $0.bindings.map {
                        try $0.isUnbound ? .unbound : .type(SchemaType($0.type))
                    }))
        }
    }
}

extension SchemaDefaultValue {
    init(_ proto: Schema.Value) throws {
        switch try proto.kind {
        case .void: self = .void
        case .bool: self = try .bool(proto.boolValue)
        case .int8: self = try .int8(proto.int8Value)
        case .int16: self = try .int16(proto.int16Value)
        case .int32: self = try .int32(proto.int32Value)
        case .int64: self = try .int64(proto.int64Value)
        case .uint8: self = try .uint8(proto.uint8Value)
        case .uint16: self = try .uint16(proto.uint16Value)
        case .uint32: self = try .uint32(proto.uint32Value)
        case .uint64: self = try .uint64(proto.uint64Value)
        case .float32: self = try .float32(proto.float32Value)
        case .float64: self = try .float64(proto.float64Value)
        case .text: self = try .text(proto.textValue)
        case .data: self = try .data(proto.dataValue)
        case .list: self = try .list(proto.listValue)
        case .enum: self = try .enumeration(proto.enumValue)
        case .struct: self = try .structure(proto.structValue)
        case .interface: self = .interface
        case .anyPointer: self = try .anyPointer(proto.anyPointerValue)
        case .unknown(let tag): throw SchemaError.unknownTypeKind(tag)
        }
    }
}

extension SchemaAnnotation {
    init(_ proto: Schema.Annotation) throws {
        id = try proto.id
        brand = try SchemaBrand(proto.brand)
        value = try SchemaDefaultValue(proto.valueExpression)
    }
}

extension SchemaField {
    init(_ proto: Schema.Field) throws {
        name = try proto.name
        codeOrder = try proto.codeOrder
        let tag = try proto.discriminantValue
        discriminantValue = tag == Schema.Field.noDiscriminant ? nil : tag
        hadExplicitDefault = try proto.hadExplicitDefault
        annotations = try proto.annotations.map(SchemaAnnotation.init)
        switch try proto.kind {
        case .slot:
            storage = try .slot(
                offset: proto.offset, type: SchemaType(proto.type),
                defaultValue: SchemaDefaultValue(proto.defaultValue))
        case .group: storage = try .group(typeID: proto.groupTypeID)
        case .unknown(let tag): throw SchemaError.invalidNode(0, "unknown field kind \(tag)")
        }
    }
}

private func validateNode(_ node: SchemaNode) throws {
    guard node.id != 0 else { throw SchemaError.invalidNode(node.id, "ID must be nonzero") }
    guard Int(node.displayNamePrefixLength) <= node.displayName.utf8.count else {
        throw SchemaError.invalidNode(node.id, "display-name prefix is out of bounds")
    }
    try requireUnique(node.parameters, nodeID: node.id, label: "parameter")
    switch node.kind {
    case .structure(let dataWords, let pointers, _, _, let count, let offset, let fields):
        try requireUnique(fields.map(\.name), nodeID: node.id, label: "field")
        try requireUnique(fields.map(\.codeOrder), nodeID: node.id, label: "field code order")
        guard count == 0 || count >= 2 else {
            throw SchemaError.invalidNode(node.id, "a union cannot contain exactly one field")
        }
        if count > 0, UInt64(offset) * 2 + 2 > UInt64(dataWords) * 8 {
            throw SchemaError.invalidNode(node.id, "union discriminant is outside the data section")
        }
        var tags = Set<UInt16>()
        for field in fields {
            if let tag = field.discriminantValue {
                guard tag < count, tags.insert(tag).inserted else {
                    throw SchemaError.invalidNode(
                        node.id, "invalid or duplicate union discriminant")
                }
            }
            guard case .slot(let offset, let type, _) = field.storage else { continue }
            if let bits = scalarBitWidth(type) {
                let end = UInt64(offset) * UInt64(bits) + UInt64(bits)
                guard end <= UInt64(dataWords) * 64 else {
                    throw SchemaError.invalidNode(
                        node.id, "field '\(field.name)' is outside data section")
                }
            } else if isPointerType(type), offset >= UInt32(pointers) {
                throw SchemaError.invalidNode(
                    node.id, "field '\(field.name)' is outside pointer section")
            }
        }
    case .enumeration(let values):
        try requireUnique(values.map(\.name), nodeID: node.id, label: "enumerant")
        try requireUnique(values.map(\.codeOrder), nodeID: node.id, label: "enumerant code order")
    case .interface(let methods, _):
        try requireUnique(methods.map(\.name), nodeID: node.id, label: "method")
        try requireUnique(methods.map(\.codeOrder), nodeID: node.id, label: "method code order")
        guard methods.allSatisfy({ $0.paramStructType != 0 && $0.resultStructType != 0 }) else {
            throw SchemaError.invalidNode(node.id, "method types must have nonzero IDs")
        }
    default: break
    }
}

private func requireUnique<T: Hashable>(_ values: [T], nodeID: Schema.ID, label: String) throws {
    guard Set(values).count == values.count else {
        throw SchemaError.invalidNode(nodeID, "duplicate \(label)")
    }
}

private func uniqueDictionary(_ pairs: [(String, Schema.ID)]) throws -> [String: Schema.ID] {
    var result: [String: Schema.ID] = [:]
    for (name, id) in pairs {
        guard result.updateValue(id, forKey: name) == nil else {
            throw SchemaError.duplicateName(name)
        }
    }
    return result
}

private func scalarBitWidth(_ type: SchemaType) -> Int? {
    switch type {
    case .void: 0
    case .bool: 1
    case .int8, .uint8: 8
    case .int16, .uint16, .enumeration: 16
    case .int32, .uint32, .float32: 32
    case .int64, .uint64, .float64: 64
    default: nil
    }
}

private func isPointerType(_ type: SchemaType) -> Bool {
    switch type {
    case .text, .data, .list, .structure, .interface, .anyPointer: true
    default: false
    }
}

private func hexID(_ id: Schema.ID) -> String {
    "0x" + String(id, radix: 16, uppercase: false)
}
