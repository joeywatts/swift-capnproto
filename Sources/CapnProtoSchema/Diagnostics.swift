import CapnProto
import Foundation

public struct DiagnosticOptions: Equatable, Sendable {
    public var maximumDepth: Int
    public var maximumListElements: Int

    public init(maximumDepth: Int = 16, maximumListElements: Int = 256) {
        self.maximumDepth = max(0, maximumDepth)
        self.maximumListElements = max(0, maximumListElements)
    }
}

public enum DynamicDiagnostics {
    public static func describe(
        _ value: DynamicValue, options: DiagnosticOptions = DiagnosticOptions()
    ) throws -> String {
        try describe(value, options: options, depth: 0)
    }

    public static func describe(
        _ reader: DynamicStructReader, options: DiagnosticOptions = DiagnosticOptions()
    ) throws -> String {
        try describe(.structure(reader), options: options, depth: 0)
    }

    /// Lets generated readers use the exact same normalization path through their raw view.
    public static func describe(
        _ raw: StructReader, schema: SchemaNode, registry: SchemaRegistry,
        options: DiagnosticOptions = DiagnosticOptions()
    ) throws -> String {
        try describe(
            DynamicStructReader(raw, schema: schema, registry: registry), options: options)
    }

    public static func describe(
        schema: SchemaNode, options: DiagnosticOptions = DiagnosticOptions()
    ) -> String {
        var result = "\(schema.kindName) \(schema.displayName) @\(hexSchemaID(schema.id))"
        switch schema.kind {
        case .file: break
        case .structure(let data, let pointers, _, let isGroup, let discriminants, _, let fields):
            result += " (dataWords = \(data), pointers = \(pointers)"
            if isGroup { result += ", group" }
            if discriminants > 0 { result += ", unionFields = \(discriminants)" }
            result += ") {"
            let shown = fields.prefix(options.maximumListElements).map {
                "\($0.name): \(describe(type: $0.storage))"
            }
            result += shown.joined(separator: ", ")
            if fields.count > shown.count { result += shown.isEmpty ? "..." : ", ..." }
            result += "}"
        case .enumeration(let values):
            let shown = values.prefix(options.maximumListElements).map(\.name)
            result += " {" + shown.joined(separator: ", ")
            if values.count > shown.count { result += shown.isEmpty ? "..." : ", ..." }
            result += "}"
        case .interface(let methods, let superclasses):
            if !superclasses.isEmpty {
                result += " : " + superclasses.map(hexSchemaID).joined(separator: ", ")
            }
            let shown = methods.prefix(options.maximumListElements).map {
                "\($0.name)(@\(hexSchemaID($0.paramStructType))) -> @\(hexSchemaID($0.resultStructType))"
            }
            result += " {" + shown.joined(separator: ", ")
            if methods.count > shown.count { result += shown.isEmpty ? "..." : ", ..." }
            result += "}"
        case .constant(let type, _): result += ": \(describe(type: type))"
        case .annotation(let type, let targets):
            result += ": \(describe(type: type)) ["
                + targets.map(\.rawValue).sorted().joined(separator: ", ") + "]"
        }
        return result
    }

    private static func describe(
        _ value: DynamicValue, options: DiagnosticOptions, depth: Int
    ) throws -> String {
        switch value {
        case .void: return "void"
        case .bool(let value): return value ? "true" : "false"
        case .int8(let value): return String(value)
        case .int16(let value): return String(value)
        case .int32(let value): return String(value)
        case .int64(let value): return String(value)
        case .uint8(let value): return String(value)
        case .uint16(let value): return String(value)
        case .uint32(let value): return String(value)
        case .uint64(let value): return String(value)
        case .float32(let value): return floatingDescription(value)
        case .float64(let value): return floatingDescription(value)
        case .text(let value): return escaped(value)
        case .data(let bytes):
            return "0x\"" + bytes.map { String(format: "%02x", $0) }.joined() + "\""
        case .enumeration(let value): return value.name ?? "unknown(\(value.rawValue))"
        case .capability(.some(let index)): return "<capability \(index)>"
        case .capability(nil): return "<null capability>"
        case .anyPointer(let value):
            if value.isNull { return "null" }
            if let index = try? value.capabilityTableIndex { return "<capability \(index)>" }
            return "<any-pointer>"
        case .list(let list):
            guard depth < options.maximumDepth else { return "..." }
            let limit = min(list.count, options.maximumListElements)
            var values = [String]()
            values.reserveCapacity(limit + (limit < list.count ? 1 : 0))
            for index in 0..<limit {
                values.append(try describe(
                    list.value(at: index), options: options, depth: depth + 1))
            }
            if limit < list.count { values.append("...") }
            return "[" + values.joined(separator: ", ") + "]"
        case .structure(let reader):
            guard depth < options.maximumDepth else { return "..." }
            guard case .structure(_, _, _, _, _, _, let fields) = reader.schema.kind else {
                return "()"
            }
            let active = try reader.activeUnionField()?.name
            let eligible = fields.filter {
                $0.discriminantValue == nil || $0.name == active
            }.sorted {
                if $0.codeOrder != $1.codeOrder { return $0.codeOrder < $1.codeOrder }
                return $0.name < $1.name
            }
            let limit = eligible.count
            var values = [String]()
            values.reserveCapacity(limit + (limit < eligible.count ? 1 : 0))
            for field in eligible.prefix(limit) {
                let value = try reader.value(of: field)
                values.append("\(field.name) = " + (try describe(
                    value, options: options, depth: depth + 1)))
            }
            return "(" + values.joined(separator: ", ") + ")"
        }
    }

    private static func floatingDescription<T: BinaryFloatingPoint>(_ value: T) -> String {
        if value.isNaN { return "nan" }
        if value == .infinity { return "inf" }
        if value == -.infinity { return "-inf" }
        if value == 0, value.sign == .minus { return "-0" }
        return String(describing: value)
    }

    private static func escaped(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0a: result += "\\n"
            case 0x0c: result += "\\f"
            case 0x0d: result += "\\r"
            case 0..<0x20, 0x7f:
                result += String(format: "\\u{%x}", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func describe(type storage: SchemaField.Storage) -> String {
        switch storage {
        case .group(let id): return "group @\(hexSchemaID(id))"
        case .slot(_, let type, _): return describe(type: type)
        }
    }

    private static func describe(type: SchemaType) -> String {
        switch type {
        case .void: "Void"
        case .bool: "Bool"
        case .int8: "Int8"
        case .int16: "Int16"
        case .int32: "Int32"
        case .int64: "Int64"
        case .uint8: "UInt8"
        case .uint16: "UInt16"
        case .uint32: "UInt32"
        case .uint64: "UInt64"
        case .float32: "Float32"
        case .float64: "Float64"
        case .text: "Text"
        case .data: "Data"
        case .list(let element): "List(\(describe(type: element)))"
        case .enumeration(let id, _): "enum @\(hexSchemaID(id))"
        case .structure(let id, _): "struct @\(hexSchemaID(id))"
        case .interface(let id, _): "interface @\(hexSchemaID(id))"
        case .anyPointer(let constraint): "AnyPointer(\(constraint))"
        }
    }
}

private func hexSchemaID(_ id: Schema.ID) -> String {
    "0x" + String(id, radix: 16, uppercase: false)
}
