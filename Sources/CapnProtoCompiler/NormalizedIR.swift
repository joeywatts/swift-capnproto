import CapnProto
import CapnProtoSchema
import Foundation

/// Returns a stable, source-location-free summary of the wire-relevant compiler IR.
/// It is intended for differential testing of schema frontends.
public func normalizedCompilerIR(_ framedRequest: [UInt8]) throws -> String {
    let request = try Schema.CodeGeneratorRequest(framedBytes: framedRequest)
    var lines: [String] = []
    for file in try request.requestedFiles.sorted(by: { try $0.id < $1.id }) {
        let imports = try file.imports.sorted(by: { try $0.id < $1.id }).map {
            "\(try $0.id):\(try $0.name)"
        }
        lines.append(
            "requested \(try file.id) \(try file.filename) imports[\(imports.joined(separator: ","))]"
        )
    }
    for node in try request.nodes.sorted(by: { try $0.id < $1.id }) {
        let id = try node.id
        let kind = try node.kind
        if kind == .annotation { continue }
        lines.append(
            "node \(id) scope \(try node.scopeID) \(kind) name \(try node.displayName)\(try annotationsSummary(node.annotations))"
        )
        switch kind {
        case .struct:
            lines.append(
                "  size \(try node.dataWordCount) \(try node.pointerCount) union \(try node.discriminantCount) @\(try node.discriminantOffset) group \(try node.isGroup)"
            )
            for field in try node.fields {
                let common =
                    "  field \(try field.name) code \(try field.codeOrder) tag \(try field.discriminantValue)\(try annotationsSummary(field.annotations))"
                switch try field.kind {
                case .slot:
                    lines.append(
                        "\(common) slot \(try field.offset) \(try typeSummary(field.type)) default \(try field.hadExplicitDefault):\(try valueSummary(field.defaultValue))"
                    )
                case .group:
                    lines.append("\(common) group \(try field.groupTypeID)")
                case .unknown(let tag): lines.append("\(common) unknown \(tag)")
                }
            }
        case .enum:
            for value in try node.enumerants {
                lines.append(
                    "  enumerant \(try value.name) code \(try value.codeOrder)\(try annotationsSummary(value.annotations))"
                )
            }
        case .interface:
            for method in try node.methods {
                lines.append(
                    "  method \(try method.name) code \(try method.codeOrder)\(try annotationsSummary(method.annotations)) \(try method.paramStructType)\(try brandSummary(method.paramBrand)) -> \(try method.resultStructType)\(try brandSummary(method.resultBrand))"
                )
            }
            for superclass in try node.superclasses {
                lines.append(
                    "  superclass \(try superclass.id)\(try brandSummary(superclass.brand))")
            }
        case .constant:
            lines.append(
                "  const \(try typeSummary(node.constantType))=\(try valueSummary(node.constantValue))"
            )
        default: break
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

private func annotationsSummary(_ annotations: [Schema.Annotation]) throws -> String {
    guard !annotations.isEmpty else { return "" }
    let values = try annotations.map { annotation in
        let value = try annotation.valueExpression
        return
            "\(try annotation.id):\(try valueSummary(value))\(try brandSummary(annotation.brand))"
    }
    return " annotations[\(values.joined(separator: ","))]"
}

private func valueSummary(_ value: Schema.Value) throws -> String {
    switch try value.kind {
    case .void: return "void"
    case .bool: return "bool:\(try value.boolValue)"
    case .int8: return "int8:\(try value.int8Value)"
    case .int16: return "int16:\(try value.int16Value)"
    case .int32: return "int32:\(try value.int32Value)"
    case .int64: return "int64:\(try value.int64Value)"
    case .uint8: return "uint8:\(try value.uint8Value)"
    case .uint16: return "uint16:\(try value.uint16Value)"
    case .uint32: return "uint32:\(try value.uint32Value)"
    case .uint64: return "uint64:\(try value.uint64Value)"
    case .float32: return "float32:\(try value.float32Value.bitPattern)"
    case .float64: return "float64:\(try value.float64Value.bitPattern)"
    case .text: return "text:\(try value.textValue.debugDescription)"
    case .data: return "data:\(try value.dataValue.map { String(format: "%02x", $0) }.joined())"
    case .enum: return "enum:\(try value.enumValue)"
    case .list, .struct, .anyPointer:
        if try value.anyPointerValue.isNull { return "\(try value.kind):null" }
        let message = try MessageBuilder(firstSegmentWords: 64, allocationStrategy: .growing)
        let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
        try root.anyPointerField(at: 0).set(value.anyPointerValue)
        let framed = try message.framedBytes
        let reader = try MessageFraming.decodePrefix(framed).reader()
        do {
            let canonical = try reader.canonicalized()
            return "\(try value.kind):\(canonical.map { String(format: "%02x", $0) }.joined())"
        } catch {
            return "\(try value.kind):noncanonical"
        }
    case .interface: return "interface"
    case .unknown(let tag): return "unknown:\(tag)"
    }
}

private func typeSummary(_ type: Schema.`Type`) throws -> String {
    switch try type.kind {
    case .list: return "list<\(try typeSummary(type.elementType))>"
    case .enum, .struct, .interface:
        return "\(try type.kind):\(try type.typeID)\(try brandSummary(type.brand))"
    case .anyPointer: return "any:\(try type.anyPointerKind)"
    default: return "\(try type.kind)"
    }
}

private func brandSummary(_ brand: Schema.Brand) throws -> String {
    let scopes = try brand.scopes
    guard !scopes.isEmpty else { return "" }
    let values = try scopes.map { scope -> String in
        if try scope.isInherit { return "\(try scope.scopeID)=inherit" }
        let bindings = try scope.bindings.map { binding -> String in
            try binding.isUnbound ? "_" : typeSummary(binding.type)
        }
        return "\(try scope.scopeID)=[\(bindings.joined(separator: ","))]"
    }
    return "{\(values.joined(separator: ";"))}"
}
