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
            let compatibility = SchemaLoader.compatibility(of: node, with: current)
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
        try load(request.nodes)
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
        case let (.structure(cd, cp, _, _, cdc, cdo, cf),
                  .structure(ed, ep, _, _, edc, edo, ef)):
            let common = min(cf.count, ef.count)
            let shared = (0..<common).allSatisfy { fieldsWireCompatible(cf[$0], ef[$0]) }
            let unionOK = cdc == edc && (cdc == 0 || cdo == edo)
            let canRead = shared && unionOK && cd >= ed && cp >= ep && cf.count >= ef.count
            let canWrite = shared && unionOK && ed >= cd && ep >= cp && ef.count >= cf.count
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
            }
            let supers = Set(cs) == Set(es)
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
}

private func fieldsWireCompatible(_ lhs: SchemaField, _ rhs: SchemaField) -> Bool {
    guard lhs.discriminantValue == rhs.discriminantValue else { return false }
    switch (lhs.storage, rhs.storage) {
    case let (.slot(lo, lt, _), .slot(ro, rt, _)): return lo == ro && lt == rt
    case let (.group(l), .group(r)): return l == r
    default: return false
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
