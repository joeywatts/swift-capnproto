import CapnProto

public struct DynamicEnum: Equatable {
    public let rawValue: UInt16
    public let schema: SchemaNode

    public var name: String? {
        guard case .enumeration(let values) = schema.kind,
            values.indices.contains(Int(rawValue))
        else { return nil }
        return values[Int(rawValue)].name
    }

    public init(rawValue: UInt16, schema: SchemaNode) throws {
        guard case .enumeration = schema.kind else {
            throw SchemaError.kindMismatch(expected: "enum", actual: schema.kindName)
        }
        self.rawValue = rawValue
        self.schema = schema
    }

    public static func == (lhs: DynamicEnum, rhs: DynamicEnum) -> Bool {
        lhs.rawValue == rhs.rawValue && lhs.schema.id == rhs.schema.id
    }
}

public indirect enum DynamicValue {
    case void, bool(Bool)
    case int8(Int8), int16(Int16), int32(Int32), int64(Int64)
    case uint8(UInt8), uint16(UInt16), uint32(UInt32), uint64(UInt64)
    case float32(Float), float64(Double)
    case text(String), data([UInt8])
    case list(DynamicListReader), structure(DynamicStructReader)
    case enumeration(DynamicEnum), capability(UInt32?)
    case anyPointer(AnyPointerReader)
}

public struct DynamicStructReader {
    public let raw: StructReader
    public let schema: SchemaNode
    public let registry: SchemaRegistry

    public init(_ raw: StructReader, schema: SchemaNode, registry: SchemaRegistry) throws {
        guard case .structure = schema.kind else {
            throw SchemaError.kindMismatch(expected: "struct", actual: schema.kindName)
        }
        self.raw = raw
        self.schema = schema
        self.registry = registry
    }

    public func value(named name: String) throws -> DynamicValue {
        guard let field = schema.field(named: name) else {
            throw SchemaError.invalidNode(schema.id, "unknown field '\(name)'")
        }
        return try value(of: field)
    }

    public func value(of field: SchemaField) throws -> DynamicValue {
        if let expected = field.discriminantValue, try unionDiscriminant() != expected {
            throw SchemaError.invalidNode(schema.id, "union field '\(field.name)' is not active")
        }
        switch field.storage {
        case .group(let id):
            return .structure(
                try DynamicStructReader(
                    raw, schema: registry.requireSchema(id: id), registry: registry))
        case .slot(let offset, let type, let defaultValue):
            return try read(type, offset: offset, defaultValue: defaultValue)
        }
    }

    public func activeUnionField() throws -> SchemaField? {
        guard case .structure(_, _, _, _, let count, _, let fields) = schema.kind,
            count > 0
        else { return nil }
        let tag = try unionDiscriminant()
        return fields.first { $0.discriminantValue == tag }
    }

    public func asTyped<T>(_ transform: (StructReader) throws -> T) rethrows -> T {
        try transform(raw)
    }

    private func unionDiscriminant() throws -> UInt16 {
        guard case .structure(_, _, _, _, let count, let offset, _) = schema.kind,
            count > 0
        else { return 0 }
        return try raw.discriminant(atByte: Int(offset) * 2)
    }

    private func read(
        _ type: SchemaType, offset: UInt32, defaultValue: SchemaDefaultValue
    ) throws -> DynamicValue {
        let index = Int(offset)
        switch type {
        case .void: return .void
        case .bool:
            return .bool(try raw.bool(atBit: index, default: defaultValue.bool ?? false))
        case .int8:
            return .int8(try raw.integer(atByte: index, default: defaultValue.int8 ?? 0))
        case .int16:
            return .int16(try raw.integer(atByte: index * 2, default: defaultValue.int16 ?? 0))
        case .int32:
            return .int32(try raw.integer(atByte: index * 4, default: defaultValue.int32 ?? 0))
        case .int64:
            return .int64(try raw.integer(atByte: index * 8, default: defaultValue.int64 ?? 0))
        case .uint8:
            return .uint8(try raw.integer(atByte: index, default: defaultValue.uint8 ?? 0))
        case .uint16:
            return .uint16(try raw.integer(atByte: index * 2, default: defaultValue.uint16 ?? 0))
        case .uint32:
            return .uint32(try raw.integer(atByte: index * 4, default: defaultValue.uint32 ?? 0))
        case .uint64:
            return .uint64(try raw.integer(atByte: index * 8, default: defaultValue.uint64 ?? 0))
        case .float32:
            return .float32(
                try raw.float32(
                    atByte: index * 4, default: defaultValue.float32 ?? 0))
        case .float64:
            return .float64(
                try raw.float64(
                    atByte: index * 8, default: defaultValue.float64 ?? 0))
        case .enumeration(let id, _):
            let rawValue: UInt16 = try raw.integer(
                atByte: index * 2, default: defaultValue.enumeration ?? 0)
            return .enumeration(
                try DynamicEnum(
                    rawValue: rawValue, schema: registry.requireSchema(id: id)))
        case .text:
            if try !raw.hasPointer(at: index), case .text(let value) = defaultValue {
                return .text(value)
            }
            guard let string = try raw.textField(at: index).string else {
                throw CapnProtoError.invalidText
            }
            return .text(string)
        case .data:
            if try !raw.hasPointer(at: index), case .data(let value) = defaultValue {
                return .data(value)
            }
            return .data(try raw.dataField(at: index).bytes)
        case .list(let element):
            let list: ListReader
            if try !raw.hasPointer(at: index), case .list(let value) = defaultValue {
                list = value
            } else {
                list = try raw.listField(at: index)
            }
            return .list(DynamicListReader(raw: list, elementType: element, registry: registry))
        case .structure(let id, _):
            let value: StructReader
            if try !raw.hasPointer(at: index), case .structure(let defaultReader) = defaultValue {
                value = defaultReader
            } else {
                value = try raw.structField(at: index)
            }
            return .structure(
                try DynamicStructReader(
                    value, schema: registry.requireSchema(id: id), registry: registry))
        case .interface:
            let pointer = try raw.anyPointerField(at: index)
            return .capability(pointer.isNull ? nil : try pointer.capabilityTableIndex)
        case .anyPointer:
            if try !raw.hasPointer(at: index), case .anyPointer(let value) = defaultValue {
                return .anyPointer(value)
            }
            return .anyPointer(try raw.anyPointerField(at: index))
        }
    }
}

public struct DynamicListReader {
    public let raw: ListReader
    public let elementType: SchemaType
    public let registry: SchemaRegistry
    public var count: Int { raw.count }

    public init(raw: ListReader, elementType: SchemaType, registry: SchemaRegistry) {
        self.raw = raw
        self.elementType = elementType
        self.registry = registry
    }

    public func value(at index: Int) throws -> DynamicValue {
        switch elementType {
        case .void: return .void
        case .bool: return .bool(try raw.bool(at: index))
        case .int8: return .int8(try raw.integer(at: index))
        case .int16: return .int16(try raw.integer(at: index))
        case .int32: return .int32(try raw.integer(at: index))
        case .int64: return .int64(try raw.integer(at: index))
        case .uint8: return .uint8(try raw.integer(at: index))
        case .uint16: return .uint16(try raw.integer(at: index))
        case .uint32: return .uint32(try raw.integer(at: index))
        case .uint64: return .uint64(try raw.integer(at: index))
        case .float32: return .float32(try raw.float32(at: index))
        case .float64: return .float64(try raw.float64(at: index))
        case .text:
            guard let value = try raw.textPointerElement(at: index).string else {
                throw CapnProtoError.invalidText
            }
            return .text(value)
        case .data: return .data(try raw.dataPointerElement(at: index).bytes)
        case .list(let nested):
            return .list(
                DynamicListReader(
                    raw: try raw.pointerElement(at: index), elementType: nested, registry: registry)
            )
        case .enumeration(let id, _):
            let value: UInt16 = try raw.integer(at: index)
            return .enumeration(
                try DynamicEnum(
                    rawValue: value, schema: registry.requireSchema(id: id)))
        case .structure(let id, _):
            return .structure(
                try DynamicStructReader(
                    raw.elementSize == .inlineComposite
                        ? raw.structElement(at: index) : raw.structPointerElement(at: index),
                    schema: registry.requireSchema(id: id), registry: registry))
        case .interface:
            let pointer = try raw.anyPointerElement(at: index)
            return .capability(pointer.isNull ? nil : try pointer.capabilityTableIndex)
        case .anyPointer: return .anyPointer(try raw.anyPointerElement(at: index))
        }
    }
}

public struct DynamicMessageBuilder {
    public let message: MessageBuilder
    public let schema: SchemaNode
    public let registry: SchemaRegistry

    public init(
        schema: SchemaNode, registry: SchemaRegistry, firstSegmentWords: Int = 1024,
        allocationStrategy: AllocationStrategy = .growing
    ) throws {
        guard case .structure = schema.kind else {
            throw SchemaError.kindMismatch(expected: "struct", actual: schema.kindName)
        }
        message = try MessageBuilder(
            firstSegmentWords: firstSegmentWords, allocationStrategy: allocationStrategy)
        self.schema = schema
        self.registry = registry
    }

    public func initRoot() throws -> DynamicStructBuilder {
        guard case .structure(let data, let pointers, _, _, _, _, _) = schema.kind else {
            throw SchemaError.kindMismatch(expected: "struct", actual: schema.kindName)
        }
        return try DynamicStructBuilder(
            message.initRootStruct(dataWords: Int(data), pointerCount: Int(pointers)),
            schema: schema, registry: registry)
    }

    public var framedBytes: [UInt8] { get throws { try message.framedBytes } }
    public func reader(options: ReaderOptions = ReaderOptions()) throws -> DynamicStructReader {
        try DynamicStructReader(
            message.asReader(options: options).rootStruct(), schema: schema, registry: registry)
    }
}

public struct DynamicStructBuilder {
    public let raw: StructBuilder
    public let schema: SchemaNode
    public let registry: SchemaRegistry

    public init(_ raw: StructBuilder, schema: SchemaNode, registry: SchemaRegistry) throws {
        guard case .structure = schema.kind else {
            throw SchemaError.kindMismatch(expected: "struct", actual: schema.kindName)
        }
        self.raw = raw
        self.schema = schema
        self.registry = registry
    }

    public func set(_ value: DynamicValue, named name: String) throws {
        guard let field = schema.field(named: name) else {
            throw SchemaError.invalidNode(schema.id, "unknown field '\(name)'")
        }
        try set(value, field: field)
    }

    public func set(_ value: DynamicValue, field: SchemaField) throws {
        if let tag = field.discriminantValue { try selectUnion(tag: tag) }
        switch field.storage {
        case .group(let id):
            guard case .structure(let source) = value else {
                throw dynamicMismatch(expected: "struct", value)
            }
            let groupSchema = try registry.requireSchema(id: id)
            let target = try DynamicStructBuilder(raw, schema: groupSchema, registry: registry)
            guard case .structure(_, _, _, _, _, _, let fields) = groupSchema.kind else { return }
            let active = try source.activeUnionField()?.name
            for childField in fields
            where childField.discriminantValue == nil || childField.name == active {
                try target.set(source.value(of: childField), field: childField)
            }
        case .slot(let offset, let type, let defaultValue):
            try write(value, type: type, offset: Int(offset), defaultValue: defaultValue)
        }
    }

    public func group(named name: String) throws -> DynamicStructBuilder {
        guard let field = schema.field(named: name), case .group(let id) = field.storage else {
            throw SchemaError.invalidNode(schema.id, "'\(name)' is not a group")
        }
        if let tag = field.discriminantValue { try selectUnion(tag: tag) }
        return try DynamicStructBuilder(
            raw, schema: registry.requireSchema(id: id), registry: registry)
    }

    public func initStruct(named name: String) throws -> DynamicStructBuilder {
        guard let field = schema.field(named: name),
            case .slot(let offset, .structure(let id, _), _) = field.storage
        else {
            throw SchemaError.invalidNode(schema.id, "'\(name)' is not a struct field")
        }
        if let tag = field.discriminantValue { try selectUnion(tag: tag) }
        let child = try registry.requireSchema(id: id)
        guard case .structure(let data, let pointers, _, _, _, _, _) = child.kind else {
            throw SchemaError.kindMismatch(expected: "struct", actual: child.kindName)
        }
        return try DynamicStructBuilder(
            raw.initStructField(at: Int(offset), dataWords: Int(data), pointerCount: Int(pointers)),
            schema: child, registry: registry)
    }

    public func initList(named name: String, count: Int) throws -> DynamicListBuilder {
        guard let field = schema.field(named: name),
            case .slot(let offset, .list(let element), _) = field.storage
        else {
            throw SchemaError.invalidNode(schema.id, "'\(name)' is not a list field")
        }
        if let tag = field.discriminantValue { try selectUnion(tag: tag) }
        if case .structure(let id, _) = element {
            let child = try registry.requireSchema(id: id)
            guard case .structure(let data, let pointers, _, _, _, _, _) = child.kind else {
                throw SchemaError.kindMismatch(expected: "struct", actual: child.kindName)
            }
            return DynamicListBuilder(
                backing: .structures(
                    try raw.initStructListField(
                        at: Int(offset), count: count, dataWords: Int(data),
                        pointerCount: Int(pointers))),
                elementType: element, registry: registry)
        }
        return DynamicListBuilder(
            backing: .plain(
                try raw.initListField(
                    at: Int(offset), elementSize: listElementSize(element), count: count)),
            elementType: element, registry: registry)
    }

    public func asTyped<T>(_ transform: (StructBuilder) throws -> T) rethrows -> T {
        try transform(raw)
    }

    private func selectUnion(tag: UInt16) throws {
        guard case .structure(_, _, _, _, let count, let offset, let fields) = schema.kind,
            count > 0
        else { return }
        for field in fields where field.discriminantValue != nil {
            try clear(field.storage)
        }
        try raw.setDiscriminant(atByte: Int(offset) * 2, to: tag)
    }

    private func clear(_ storage: SchemaField.Storage) throws {
        switch storage {
        case .slot(let fieldOffset, let type, _):
            if type == .bool {
                try raw.clearData(atBit: Int(fieldOffset))
            } else if let bits = dynamicScalarBitWidth(type), bits > 0 {
                let start = Int(fieldOffset) * bits / 8
                try raw.clearData(inByteRange: start..<(start + bits / 8))
            } else if dynamicIsPointer(type) {
                try raw.clearPointer(at: Int(fieldOffset))
            }
        case .group(let id):
            let group = try registry.requireSchema(id: id)
            guard case .structure(_, _, _, _, _, _, let fields) = group.kind else { return }
            for field in fields { try clear(field.storage) }
        }
    }

    private func write(
        _ value: DynamicValue, type: SchemaType, offset: Int,
        defaultValue: SchemaDefaultValue
    ) throws {
        switch (type, value) {
        case (.void, .void): break
        case (.bool, .bool(let value)):
            try raw.setBool(atBit: offset, to: value, default: defaultValue.bool ?? false)
        case (.int8, .int8(let value)):
            try raw.setInteger(atByte: offset, to: value, default: defaultValue.int8 ?? 0)
        case (.int16, .int16(let value)):
            try raw.setInteger(atByte: offset * 2, to: value, default: defaultValue.int16 ?? 0)
        case (.int32, .int32(let value)):
            try raw.setInteger(atByte: offset * 4, to: value, default: defaultValue.int32 ?? 0)
        case (.int64, .int64(let value)):
            try raw.setInteger(atByte: offset * 8, to: value, default: defaultValue.int64 ?? 0)
        case (.uint8, .uint8(let value)):
            try raw.setInteger(atByte: offset, to: value, default: defaultValue.uint8 ?? 0)
        case (.uint16, .uint16(let value)):
            try raw.setInteger(atByte: offset * 2, to: value, default: defaultValue.uint16 ?? 0)
        case (.uint32, .uint32(let value)):
            try raw.setInteger(atByte: offset * 4, to: value, default: defaultValue.uint32 ?? 0)
        case (.uint64, .uint64(let value)):
            try raw.setInteger(atByte: offset * 8, to: value, default: defaultValue.uint64 ?? 0)
        case (.float32, .float32(let value)):
            try raw.setFloat32(atByte: offset * 4, to: value, default: defaultValue.float32 ?? 0)
        case (.float64, .float64(let value)):
            try raw.setFloat64(atByte: offset * 8, to: value, default: defaultValue.float64 ?? 0)
        case (.enumeration(let id, _), .enumeration(let value)) where value.schema.id == id:
            try raw.setInteger(
                atByte: offset * 2, to: value.rawValue,
                default: defaultValue.enumeration ?? 0)
        case (.text, .text(let value)): _ = try raw.setTextField(at: offset, to: value)
        case (.data, .data(let value)): _ = try raw.setDataField(at: offset, to: value)
        case (.structure(let id, _), .structure(let value)) where value.schema.id == id:
            try raw.setStructField(at: offset, copying: value.raw)
        case (.list, .list(let value)): try raw.setListField(at: offset, copying: value.raw)
        case (.interface, .capability(.some(let index))):
            try raw.setCapabilityField(at: offset, tableIndex: index)
        case (.interface, .capability(nil)): try raw.clearPointer(at: offset)
        case (.anyPointer, .anyPointer(let value)):
            try raw.anyPointerField(at: offset).set(value)
        case (.anyPointer(.any), .structure(let value)),
            (.anyPointer(.struct), .structure(let value)):
            try raw.anyPointerField(at: offset).setStruct(value.raw)
        case (.anyPointer(.any), .list(let value)), (.anyPointer(.list), .list(let value)):
            try raw.anyPointerField(at: offset).setList(value.raw)
        case (.anyPointer(.any), .capability(.some(let value))),
            (.anyPointer(.capability), .capability(.some(let value))):
            try raw.anyPointerField(at: offset).setCapability(tableIndex: value)
        case (.anyPointer, .capability(nil)): try raw.anyPointerField(at: offset).clear()
        default: throw dynamicMismatch(expected: String(describing: type), value)
        }
    }
}

public struct DynamicListBuilder {
    enum Backing { case plain(ListBuilder), structures(StructListBuilder) }
    let backing: Backing
    public let elementType: SchemaType
    public let registry: SchemaRegistry

    public var count: Int {
        switch backing {
        case .plain(let value): value.count;
        case .structures(let value): value.count
        }
    }

    public func set(_ value: DynamicValue, at index: Int) throws {
        switch (elementType, value, backing) {
        case (.bool, .bool(let value), .plain(let list)): try list.setBool(at: index, to: value)
        case (.int8, .int8(let value), .plain(let list)): try list.setInteger(at: index, to: value)
        case (.int16, .int16(let value), .plain(let list)):
            try list.setInteger(at: index, to: value)
        case (.int32, .int32(let value), .plain(let list)):
            try list.setInteger(at: index, to: value)
        case (.int64, .int64(let value), .plain(let list)):
            try list.setInteger(at: index, to: value)
        case (.uint8, .uint8(let value), .plain(let list)):
            try list.setInteger(at: index, to: value)
        case (.uint16, .uint16(let value), .plain(let list)):
            try list.setInteger(at: index, to: value)
        case (.uint32, .uint32(let value), .plain(let list)):
            try list.setInteger(at: index, to: value)
        case (.uint64, .uint64(let value), .plain(let list)):
            try list.setInteger(at: index, to: value)
        case (.float32, .float32(let value), .plain(let list)):
            try list.setFloat32(at: index, to: value)
        case (.float64, .float64(let value), .plain(let list)):
            try list.setFloat64(at: index, to: value)
        case (.text, .text(let value), .plain(let list)): try list.setText(at: index, to: value)
        case (.data, .data(let value), .plain(let list)): try list.setData(at: index, to: value)
        case (.enumeration, .enumeration(let value), .plain(let list)):
            try list.setInteger(at: index, to: value.rawValue)
        case (.interface, .capability(.some(let value)), .plain(let list)):
            try list.setCapability(at: index, tableIndex: value)
        case (.structure(let id, _), .structure(let value), .structures(let list))
        where id == value.schema.id:
            try list[index].copyContent(from: value.raw)
        case (.anyPointer, .anyPointer(let value), .plain(let list)):
            try list.anyPointer(at: index).set(value)
        case (.void, .void, _): break
        default: throw dynamicMismatch(expected: String(describing: elementType), value)
        }
    }

    public func structElement(at index: Int) throws -> DynamicStructBuilder {
        guard case .structure(let id, _) = elementType, case .structures(let list) = backing else {
            throw SchemaError.kindMismatch(expected: "struct list", actual: "list")
        }
        return try DynamicStructBuilder(
            list[index], schema: registry.requireSchema(id: id), registry: registry)
    }

    public func initList(at index: Int, count: Int) throws -> DynamicListBuilder {
        guard case .list(let nested) = elementType, case .plain(let list) = backing else {
            throw SchemaError.kindMismatch(expected: "list of lists", actual: "list")
        }
        if case .structure(let id, _) = nested {
            let child = try registry.requireSchema(id: id)
            guard case .structure(let data, let pointers, _, _, _, _, _) = child.kind else {
                throw SchemaError.kindMismatch(expected: "struct", actual: child.kindName)
            }
            return DynamicListBuilder(
                backing: .structures(
                    try list.initStructList(
                        at: index, count: count, dataWords: Int(data),
                        pointerCount: Int(pointers))),
                elementType: nested, registry: registry)
        }
        return DynamicListBuilder(
            backing: .plain(
                try list.initList(
                    at: index, elementSize: listElementSize(nested), count: count)),
            elementType: nested, registry: registry)
    }
}

private extension SchemaDefaultValue {
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var int8: Int8? { if case .int8(let value) = self { value } else { nil } }
    var int16: Int16? { if case .int16(let value) = self { value } else { nil } }
    var int32: Int32? { if case .int32(let value) = self { value } else { nil } }
    var int64: Int64? { if case .int64(let value) = self { value } else { nil } }
    var uint8: UInt8? { if case .uint8(let value) = self { value } else { nil } }
    var uint16: UInt16? { if case .uint16(let value) = self { value } else { nil } }
    var uint32: UInt32? { if case .uint32(let value) = self { value } else { nil } }
    var uint64: UInt64? { if case .uint64(let value) = self { value } else { nil } }
    var float32: Float? { if case .float32(let value) = self { value } else { nil } }
    var float64: Double? { if case .float64(let value) = self { value } else { nil } }
    var enumeration: UInt16? {
        if case .enumeration(let value) = self { value } else { nil }
    }
}

private func listElementSize(_ type: SchemaType) -> ListElementSize {
    switch type {
    case .void: .void
    case .bool: .bit
    case .int8, .uint8: .byte
    case .int16, .uint16, .enumeration: .twoBytes
    case .int32, .uint32, .float32: .fourBytes
    case .int64, .uint64, .float64: .eightBytes
    case .structure: .inlineComposite
    default: .pointer
    }
}

private func dynamicScalarBitWidth(_ type: SchemaType) -> Int? {
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

private func dynamicIsPointer(_ type: SchemaType) -> Bool {
    switch type {
    case .text, .data, .list, .structure, .interface, .anyPointer: true
    default: false
    }
}

private func dynamicMismatch(expected: String, _ value: DynamicValue) -> SchemaError {
    .kindMismatch(expected: expected, actual: String(describing: value))
}
