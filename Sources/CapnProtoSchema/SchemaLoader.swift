import CapnProto

public struct SchemaCompatibility: Equatable, Sendable {
    public var canReadExisting: Bool
    public var canWriteExisting: Bool
    public var isEquivalent: Bool
}

public struct SchemaLoader {
    public private(set) var registry = SchemaRegistry()

    public init() {}

    @discardableResult
    public mutating func load(_ proto: Schema.Node) throws -> SchemaNode {
        try load(SchemaNode(proto: proto))
    }

    /// Loads a runtime-created schema as well as schemas decoded from `schema.capnp`.
    @discardableResult
    public mutating func load(_ node: SchemaNode) throws -> SchemaNode {
        if let current = registry.schema(id: node.id) {
            let compatibility = compatibilityConsideringGroups(of: node, with: current)
            guard compatibility.canReadExisting || compatibility.canWriteExisting else {
                throw SchemaError.incompatibleReplacement(node.id)
            }
            if isAtLeastAsNew(node, as: current) {
                try registry.insert(node, replacing: true)
                return node
            }
            return current
        }
        try registry.insert(node)
        return node
    }

    @discardableResult
    public mutating func load(_ protos: [Schema.Node]) throws -> [SchemaNode] {
        var result = [SchemaNode]()
        result.reserveCapacity(protos.count)
        for proto in protos { result.append(try load(proto)) }
        return result
    }

    @discardableResult
    public mutating func load(request: Schema.CodeGeneratorRequest) throws -> [SchemaNode] {
        let decoded = try request.nodes.map(SchemaNode.init)
        let ordered = decoded.sorted { isGroup($0) && !isGroup($1) }
        for node in ordered { try load(node) }
        var loaded = try decoded.map { node in
            guard let loaded = registry.schema(id: node.id) else {
                throw SchemaError.missingSchema(node.id)
            }
            return loaded
        }
        for requestedFile in try request.requestedFiles {
            let id = try requestedFile.id
            guard var file = registry.schema(id: id) else { throw SchemaError.missingSchema(id) }
            file.importIDs = Set(try requestedFile.imports.map { try $0.id })
            let updated = try load(file)
            if let index = loaded.firstIndex(where: { $0.id == id }) { loaded[index] = updated }
        }
        return loaded
    }

    public func finish() throws { try registry.validateGraph() }

    public static func compatibility(
        of candidate: SchemaNode, with existing: SchemaNode
    ) -> SchemaCompatibility {
        guard candidate.id == existing.id else {
            return .init(canReadExisting: false, canWriteExisting: false, isEquivalent: false)
        }
        switch (candidate.kind, existing.kind) {
        case (.file, .file):
            return .init(canReadExisting: true, canWriteExisting: true, isEquivalent: true)
        case let (
            .structure(cd, cp, _, _, cdc, cdo, cf),
            .structure(ed, ep, _, _, edc, edo, ef)
        ):
            let common = min(cf.count, ef.count)
            let shared = (0..<common).allSatisfy { fieldsWireCompatible(cf[$0], ef[$0]) }
            let sharedUnion = (cdc == 0 && edc == 0) || (cdc > 0 && edc > 0 && cdo == edo)
            let unionRead = sharedUnion && cdc >= edc
            let unionWrite = sharedUnion && edc >= cdc
            let canRead = shared && unionRead && cd >= ed && cp >= ep && cf.count >= ef.count
            let canWrite = shared && unionWrite && ed >= cd && ep >= cp && ef.count >= cf.count
            return .init(
                canReadExisting: canRead, canWriteExisting: canWrite,
                isEquivalent: canRead && canWrite)
        case let (.enumeration(c), .enumeration(e)):
            let common = min(c.count, e.count)
            let shared = (0..<common).allSatisfy { c[$0].name == e[$0].name }
            return .init(
                canReadExisting: shared && c.count >= e.count,
                canWriteExisting: shared && e.count >= c.count,
                isEquivalent: shared && c.count == e.count)
        case let (.interface(cm, cs), .interface(em, es)):
            let common = min(cm.count, em.count)
            let shared = (0..<common).allSatisfy {
                cm[$0].name == em[$0].name
                    && cm[$0].paramStructType == em[$0].paramStructType
                    && cm[$0].resultStructType == em[$0].resultStructType
                    && cm[$0].paramBrand == em[$0].paramBrand
                    && cm[$0].resultBrand == em[$0].resultBrand
            }
            let supers = cs == es
            return .init(
                canReadExisting: shared && supers && cm.count >= em.count,
                canWriteExisting: shared && supers && em.count >= cm.count,
                isEquivalent: shared && supers && cm.count == em.count)
        case (.constant(let ct, _), .constant(let et, _)),
            (.annotation(let ct, _), .annotation(let et, _)):
            let equal = ct == et
            return .init(canReadExisting: equal, canWriteExisting: equal, isEquivalent: equal)
        default:
            return .init(canReadExisting: false, canWriteExisting: false, isEquivalent: false)
        }
    }

    private func compatibilityConsideringGroups(
        of candidate: SchemaNode, with existing: SchemaNode
    ) -> SchemaCompatibility {
        guard case let .structure(cd, cp, _, _, _, _, candidateFields) = candidate.kind,
            case let .structure(ed, ep, _, _, _, _, existingFields) = existing.kind,
            let flattenedCandidate = flatten(candidateFields),
            let flattenedExisting = flatten(existingFields)
        else { return Self.compatibility(of: candidate, with: existing) }

        let reads = fields(flattenedExisting, areContainedIn: flattenedCandidate)
        let writes = fields(flattenedCandidate, areContainedIn: flattenedExisting)
        let canRead = reads && cd >= ed && cp >= ep
        let canWrite = writes && ed >= cd && ep >= cp
        return .init(
            canReadExisting: canRead, canWriteExisting: canWrite,
            isEquivalent: canRead && canWrite)
    }

    private func flatten(_ fields: [SchemaField], inheritedTag: UInt16? = nil)
        -> [SchemaField]?
    {
        var result: [SchemaField] = []
        for var field in fields {
            let tag = field.discriminantValue ?? inheritedTag
            switch field.storage {
            case .slot:
                field.discriminantValue = tag
                result.append(field)
            case .group(let typeID):
                guard let group = registry.schema(id: typeID),
                    case .structure(_, _, _, _, _, _, let children) = group.kind,
                    let flattened = flatten(children, inheritedTag: tag)
                else { return nil }
                result.append(contentsOf: flattened)
            }
        }
        return result
    }
}

private func isGroup(_ node: SchemaNode) -> Bool {
    guard case .structure(_, _, _, let value, _, _, _) = node.kind else { return false }
    return value
}

private func fields(_ subset: [SchemaField], areContainedIn superset: [SchemaField]) -> Bool {
    var remaining = superset
    for field in subset {
        guard let index = remaining.firstIndex(where: { fieldsEvolutionCompatible(field, $0) })
        else { return false }
        remaining.remove(at: index)
    }
    return true
}

private func fieldsEvolutionCompatible(_ lhs: SchemaField, _ rhs: SchemaField) -> Bool {
    let tagsMatch =
        lhs.discriminantValue == rhs.discriminantValue
        || lhs.discriminantValue == 0 && rhs.discriminantValue == nil
        || lhs.discriminantValue == nil && rhs.discriminantValue == 0
    guard tagsMatch else { return false }
    switch (lhs.storage, rhs.storage) {
    case let (.slot(lo, lt, ld), .slot(ro, rt, rd)):
        return lo == ro && typesWireCompatible(lt, rt) && defaultsWireCompatible(ld, rd)
    default: return false
    }
}

private func fieldsWireCompatible(_ lhs: SchemaField, _ rhs: SchemaField) -> Bool {
    guard lhs.discriminantValue == rhs.discriminantValue else { return false }
    switch (lhs.storage, rhs.storage) {
    case let (.slot(lo, lt, ld), .slot(ro, rt, rd)):
        return lo == ro && typesWireCompatible(lt, rt) && defaultsWireCompatible(ld, rd)
    case let (.group(l), .group(r)): return l == r
    default: return false
    }
}

private func typesWireCompatible(_ lhs: SchemaType, _ rhs: SchemaType) -> Bool {
    if lhs == rhs { return true }
    switch (lhs, rhs) {
    case (.list(let old), .list(.structure)), (.list(.structure), .list(let old)):
        switch old {
        case .void, .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64,
            .float32, .float64, .text, .data, .list, .enumeration, .structure, .interface,
            .anyPointer:
            return true
        case .bool: return false
        }
    default: return false
    }
}

private func defaultsWireCompatible(_ lhs: SchemaDefaultValue, _ rhs: SchemaDefaultValue) -> Bool {
    switch (lhs, rhs) {
    case (.void, .void), (.interface, .interface): true
    case let (.bool(l), .bool(r)): l == r
    case let (.int8(l), .int8(r)): l == r
    case let (.int16(l), .int16(r)): l == r
    case let (.int32(l), .int32(r)): l == r
    case let (.int64(l), .int64(r)): l == r
    case let (.uint8(l), .uint8(r)): l == r
    case let (.uint16(l), .uint16(r)): l == r
    case let (.uint32(l), .uint32(r)): l == r
    case let (.uint64(l), .uint64(r)): l == r
    case let (.float32(l), .float32(r)): l.bitPattern == r.bitPattern
    case let (.float64(l), .float64(r)): l.bitPattern == r.bitPattern
    case let (.text(l), .text(r)): l == r
    case let (.data(l), .data(r)): l == r
    case let (.enumeration(l), .enumeration(r)): l == r
    case let (.list(l), .list(r)): canonicalDefault(l) == canonicalDefault(r)
    case let (.structure(l), .structure(r)): canonicalDefault(l) == canonicalDefault(r)
    case let (.anyPointer(l), .anyPointer(r)): canonicalDefault(l) == canonicalDefault(r)
    default: false
    }
}

private func canonicalDefault(_ value: StructReader) -> [UInt8]? {
    try? MessageBuilder(firstSegmentWords: 64, allocationStrategy: .growing)
        .settingRoot(value).framedBytes
}

private func canonicalDefault(_ value: ListReader) -> [UInt8]? {
    do {
        let message = try MessageBuilder(firstSegmentWords: 64, allocationStrategy: .growing)
        try message.setRoot(copying: value)
        return try message.framedBytes
    } catch { return nil }
}

private func canonicalDefault(_ value: AnyPointerReader) -> [UInt8]? {
    if value.isNull { return [] }
    if let capability = try? value.capabilityTableIndex {
        return [3] + withUnsafeBytes(of: capability.littleEndian, Array.init)
    }
    if let structure = try? value.asStruct() { return canonicalDefault(structure) }
    if let list = try? value.asList() { return canonicalDefault(list) }
    return nil
}

private extension MessageBuilder {
    func settingRoot(_ value: StructReader) throws -> MessageBuilder {
        _ = try setRoot(copying: value)
        return self
    }
}

private func isAtLeastAsNew(_ lhs: SchemaNode, as rhs: SchemaNode) -> Bool {
    switch (lhs.kind, rhs.kind) {
    case let (.structure(ld, lp, _, _, _, _, lf), .structure(rd, rp, _, _, _, _, rf)):
        return ld >= rd && lp >= rp && lf.count >= rf.count
    case let (.enumeration(l), .enumeration(r)): return l.count >= r.count
    case let (.interface(l, _), .interface(r, _)): return l.count >= r.count
    default: return true
    }
}
