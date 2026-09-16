import CapnProto
import CapnProtoSchema
import Foundation

public struct NativeCompilation: Sendable {
    public let requestBytes: [UInt8]
    public let generatedFiles: [GeneratedSwiftFile]
}

public enum NativeCompilerError: Error, CustomStringConvertible {
    case diagnostics([SourceDiagnostic])
    case unsupported(String)

    public var description: String {
        switch self {
        case .diagnostics(let values): return values.map(\.description).joined(separator: "\n")
        case .unsupported(let detail): return "unsupported schema construct: \(detail)"
        }
    }
}

extension NativeSchemaCompiler {
    public func compile(files: [URL]) throws -> NativeCompilation {
        let schema = resolve(files: files)
        guard schema.diagnostics.isEmpty else {
            throw NativeCompilerError.diagnostics(schema.diagnostics)
        }
        var translator = IRTranslator(
            schema: schema, requestedURLs: files.map(\.standardizedFileURL))
        let requestBytes = try RequestWriter.write(translator.translate())
        let request = try Schema.CodeGeneratorRequest(framedBytes: requestBytes)
        return NativeCompilation(
            requestBytes: requestBytes, generatedFiles: try SwiftGenerator().generate(request))
    }
}

private struct RequestIR {
    var nodes: [NodeIR]
    var lookupNodes: [NodeIR]
    var requestedFiles: [RequestedIR]
}

private struct RequestedIR {
    var id: UInt64
    var filename: String
    var imports: [ResolvedImport]
}

private struct NodeIR {
    enum Payload {
        case file
        case structure(StructIR)
        case enumeration([EnumerantIR])
        case interface(methods: [MethodIR], superclasses: [TypeIR])
        case constant(type: TypeIR, value: ValueSyntax)
        case annotation(type: TypeIR, targets: [String])
    }
    var id: UInt64
    var scopeID: UInt64
    var displayName: String
    var displayNamePrefixLength: UInt32
    var name: String
    var nested: [(String, UInt64)]
    var annotations: [AnnotationIR]
    var parameters: [String]
    var isGeneric: Bool
    var range: SourceRange
    var payload: Payload
}

private struct StructIR {
    var dataWords: UInt16
    var pointerCount: UInt16
    var discriminantCount: UInt16
    var discriminantOffset: UInt32
    var isGroup: Bool
    var fields: [FieldIR]
}

private struct FieldIR {
    enum Payload {
        case slot(offset: UInt32, type: TypeIR, defaultValue: ValueSyntax?, explicit: Bool);
        case group(UInt64)
    }
    var name: String
    var codeOrder: UInt16
    var ordinal: UInt16?
    var discriminant: UInt16?
    var annotations: [AnnotationIR]
    var payload: Payload
    var range: SourceRange
}

private struct MethodIR {
    var syntax: MethodSyntax
    var codeOrder: UInt16
    var annotations: [AnnotationIR]
    var paramID: UInt64
    var resultID: UInt64
    var paramType: TypeIR
    var resultType: TypeIR
}

private struct EnumerantIR {
    var syntax: EnumerantSyntax
    var annotations: [AnnotationIR]
}

private struct AnnotationIR {
    var id: UInt64
    var type: TypeIR
    var value: ValueSyntax
    var brand: [BrandScopeIR]
}

private struct AnnotationDeclarationInfo {
    var file: ResolvedFile
    var path: [String]
    var syntax: AnnotationDeclarationSyntax
}

private indirect enum TypeIR {
    case primitive(UInt16)
    case list(TypeIR)
    case node(
        id: UInt64, kind: ResolvedNode.Kind, arguments: [TypeIR], brand: [BrandScopeIR] = [])
    case parameter(scopeID: UInt64, index: UInt16)
    case implicitParameter(UInt16)
}

private struct BrandScopeIR {
    var scopeID: UInt64
    var bindings: [TypeIR]?
}

private struct IRTranslator {
    let schema: ResolvedSchema
    let requestedURLs: [URL]
    var result: [NodeIR] = []
    var aliases: [IRScope: [String: TypeSyntax]] = [:]
    var genericParameters: [IRScope: [String]] = [:]
    var nodeByKey: [IRNodeKey: ResolvedNode] = [:]
    var annotationByID: [UInt64: AnnotationDeclarationInfo] = [:]
    var fileByID: [UInt64: ResolvedFile] = [:]
    var fileByURL: [URL: ResolvedFile] = [:]

    init(schema: ResolvedSchema, requestedURLs: [URL]) {
        self.schema = schema
        self.requestedURLs = requestedURLs
        for node in schema.nodes {
            nodeByKey[
                IRNodeKey(
                    source: node.sourceName,
                    path: node.qualifiedName.split(separator: ".").map(String.init))] = node
        }
        for file in schema.files {
            collectAnnotationDeclarations(
                file.syntax.declarations, file: file, parentID: file.id, path: [])
        }
        for file in schema.files {
            fileByID[file.id] = file; fileByURL[file.url.standardizedFileURL] = file
        }
        for file in schema.files { collectAliases(file.syntax.declarations, file: file, path: []) }
    }

    mutating func collectAnnotationDeclarations(
        _ declarations: [DeclarationSyntax], file: ResolvedFile, parentID: UInt64,
        path: [String]
    ) {
        for declaration in declarations {
            switch declaration {
            case .annotation(let syntax):
                let id = syntax.id ?? TypeID.child(parent: parentID, name: syntax.name)
                annotationByID[id] = AnnotationDeclarationInfo(
                    file: file, path: path, syntax: syntax)
            case .structure(let syntax):
                let id = syntax.id ?? TypeID.child(parent: parentID, name: syntax.name)
                collectAnnotationDeclarations(
                    nestedDeclarations(syntax.members), file: file, parentID: id,
                    path: path + [syntax.name])
            case .interface(let syntax):
                let id = syntax.id ?? TypeID.child(parent: parentID, name: syntax.name)
                collectAnnotationDeclarations(
                    syntax.members.compactMap {
                        if case .declaration(let value) = $0 { return value }; return nil
                    }, file: file, parentID: id, path: path + [syntax.name])
            default: break
            }
        }
    }

    mutating func translate() throws -> RequestIR {
        for file in schema.files.sorted(by: { $0.sourceName < $1.sourceName }) {
            let nested = topLevelNested(
                file.syntax.declarations, file: file, parentID: file.id, path: [])
            result.append(
                NodeIR(
                    id: file.id, scopeID: 0, displayName: file.sourceName,
                    displayNamePrefixLength: UInt32(file.sourceName.utf8.count),
                    name: file.sourceName,
                    nested: nested,
                    annotations: try resolveAnnotations(
                        file.syntax.declarations.compactMap {
                            if case .application(let value) = $0 { return value }; return nil
                        }, file: file, path: [], parameters: []),
                    parameters: [], isGeneric: false,
                    range: SourceRange(startByte: 0, endByte: 0), payload: .file))
            try translateDeclarations(
                file.syntax.declarations, file: file, parentID: file.id, path: [],
                parameters: [], inheritedGeneric: false)
        }
        if result.contains(where: { node in
            if case .interface(let methods, _) = node.payload {
                return methods.contains { $0.resultID == 0x995f_9a33_77c0_b16e }
            }
            return false
        }), !result.contains(where: { $0.id == 0x995f_9a33_77c0_b16e }) {
            let streamFileID: UInt64 = 9_710_718_097_904_890_872
            result.append(
                NodeIR(
                    id: streamFileID, scopeID: 0, displayName: "capnp/stream.capnp",
                    displayNamePrefixLength: 13, name: "capnp/stream.capnp",
                    nested: [("StreamResult", 0x995f_9a33_77c0_b16e)],
                    annotations: [
                        AnnotationIR(
                            id: 13_386_661_402_618_388_268, type: .primitive(12),
                            value: .string("capnp"), brand: [])
                    ],
                    parameters: [],
                    isGeneric: false, range: SourceRange(startByte: 0, endByte: 0), payload: .file))
            result.append(
                NodeIR(
                    id: 0x995f_9a33_77c0_b16e, scopeID: streamFileID,
                    displayName: "capnp/stream.capnp:StreamResult",
                    displayNamePrefixLength: 19, name: "StreamResult", nested: [], annotations: [],
                    parameters: [],
                    isGeneric: false, range: SourceRange(startByte: 0, endByte: 0),
                    payload: .structure(
                        StructIR(
                            dataWords: 0, pointerCount: 0, discriminantCount: 0,
                            discriminantOffset: 0, isGroup: false, fields: []))))
        }
        let requested = requestedURLs.compactMap { url -> RequestedIR? in
            guard let file = fileByURL[url] else { return nil }
            var imports = file.imports
            let usesStreaming = result.contains { node in
                guard node.displayName.hasPrefix(file.sourceName + ":"),
                    case .interface(let methods, _) = node.payload
                else { return false }
                return methods.contains { $0.resultID == 0x995f_9a33_77c0_b16e }
            }
            if usesStreaming,
                !imports.contains(where: { $0.fileID == 9_710_718_097_904_890_872 })
            {
                imports.append(
                    ResolvedImport(
                        path: "/capnp/stream.capnp", fileID: 9_710_718_097_904_890_872))
            }
            return RequestedIR(
                id: file.id, filename: file.sourceName,
                imports: imports.sorted { $0.path < $1.path })
        }
        return RequestIR(
            nodes: reachableNodes(requestedFileIDs: Set(requested.map(\.id))),
            lookupNodes: result, requestedFiles: requested)
    }

    private func reachableNodes(requestedFileIDs: Set<UInt64>) -> [NodeIR] {
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        var included = Set<UInt64>()
        var pending = result.filter { node in
            var scopeID = node.id
            while let scope = byID[scopeID] {
                if requestedFileIDs.contains(scope.id) { return true }
                guard scope.scopeID != 0 else { break }
                scopeID = scope.scopeID
            }
            return false
        }.map(\.id)

        func addType(_ type: TypeIR, to pending: inout [UInt64]) {
            switch type {
            case .list(let element): addType(element, to: &pending)
            case .node(let id, _, let arguments, let brand):
                pending.append(id)
                for argument in arguments { addType(argument, to: &pending) }
                for scope in brand {
                    if byID[scope.scopeID] != nil { pending.append(scope.scopeID) }
                    for binding in scope.bindings ?? [] { addType(binding, to: &pending) }
                }
            case .parameter(let scopeID, _):
                if byID[scopeID] != nil { pending.append(scopeID) }
            case .primitive, .implicitParameter: break
            }
        }

        func addValue(_ value: ValueSyntax, to pending: inout [UInt64]) {
            switch value {
            case .identifier(let name):
                guard name.components.count > 1 else { return }
                let suffix = name.components.joined(separator: ".")
                if let constant = result.first(where: {
                    guard case .constant = $0.payload else { return false }
                    return $0.displayName.hasSuffix(":" + suffix)
                        || $0.displayName.hasSuffix("." + suffix)
                }), case .constant(let type, let constantValue) = constant.payload {
                    addType(type, to: &pending)
                    addValue(constantValue, to: &pending)
                }
            case .list(let values):
                for item in values { addValue(item, to: &pending) }
            case .tuple(let fields):
                for (_, item) in fields { addValue(item, to: &pending) }
            default: break
            }
        }

        while let id = pending.popLast() {
            guard included.insert(id).inserted, let node = byID[id] else { continue }
            if node.scopeID != 0 { pending.append(node.scopeID) }
            for annotation in node.annotations {
                pending.append(annotation.id)
                addType(annotation.type, to: &pending)
                addValue(annotation.value, to: &pending)
                for scope in annotation.brand {
                    if byID[scope.scopeID] != nil { pending.append(scope.scopeID) }
                    for binding in scope.bindings ?? [] { addType(binding, to: &pending) }
                }
            }
            switch node.payload {
            case .file: break
            case .structure(let structure):
                for field in structure.fields {
                    for annotation in field.annotations { pending.append(annotation.id) }
                    switch field.payload {
                    case .group(let groupID): pending.append(groupID)
                    case .slot(_, let type, let defaultValue, _):
                        addType(type, to: &pending)
                        if let defaultValue { addValue(defaultValue, to: &pending) }
                    }
                }
            case .enumeration(let enumerants):
                for enumerant in enumerants {
                    for annotation in enumerant.annotations { pending.append(annotation.id) }
                }
            case .interface(let methods, let superclasses):
                for superclass in superclasses { addType(superclass, to: &pending) }
                for method in methods {
                    pending.append(method.paramID)
                    pending.append(method.resultID)
                    for annotation in method.annotations { pending.append(annotation.id) }
                }
            case .constant(let type, let value):
                addType(type, to: &pending)
                addValue(value, to: &pending)
            case .annotation(let type, _):
                addType(type, to: &pending)
            }
        }
        return result.filter { included.contains($0.id) }
    }

    mutating func collectAliases(
        _ declarations: [DeclarationSyntax], file: ResolvedFile, path: [String]
    ) {
        for declaration in declarations {
            switch declaration {
            case .using(let value):
                let name = value.name ?? syntaxTypeName(value.target)?.components.last
                if let name {
                    aliases[IRScope(fileID: file.id, path: path), default: [:]][name] = value.target
                }
            case .structure(let value):
                genericParameters[IRScope(fileID: file.id, path: path + [value.name])] =
                    value.parameters
                collectAliases(
                    nestedDeclarations(value.members), file: file, path: path + [value.name])
            case .interface(let value):
                genericParameters[IRScope(fileID: file.id, path: path + [value.name])] =
                    value.parameters
                collectAliases(
                    value.members.compactMap {
                        if case .declaration(let value) = $0 { return value }; return nil
                    }, file: file, path: path + [value.name])
            default: break
            }
        }
    }

    func topLevelNested(
        _ declarations: [DeclarationSyntax], file: ResolvedFile, parentID: UInt64, path: [String]
    ) -> [(String, UInt64)] {
        declarations.compactMap { declaration in
            guard
                let pair = declarationNameAndID(
                    declaration, file: file, parentID: parentID, path: path)
            else { return nil }
            return pair
        }
    }

    mutating func translateDeclarations(
        _ declarations: [DeclarationSyntax], file: ResolvedFile, parentID: UInt64, path: [String],
        parameters: [GenericParameter], inheritedGeneric: Bool
    ) throws {
        for declaration in declarations {
            switch declaration {
            case .application, .using: continue
            case .structure(let syntax):
                let id = syntax.id ?? TypeID.child(parent: parentID, name: syntax.name)
                let local = syntax.parameters.enumerated().map {
                    GenericParameter(name: $0.element, scopeID: id, index: UInt16($0.offset))
                }
                let allParameters = parameters + local
                let nested = topLevelNested(
                    nestedDeclarations(syntax.members), file: file, parentID: id,
                    path: path + [syntax.name])
                let nodeIndex = result.count
                result.append(
                    NodeIR(
                        id: id, scopeID: parentID,
                        displayName: displayName(file: file, path: path + [syntax.name]),
                        displayNamePrefixLength: displayPrefix(
                            file: file, path: path + [syntax.name]), name: syntax.name,
                        nested: nested,
                        annotations: try resolveAnnotations(
                            syntax.annotations, file: file, path: path, parameters: parameters),
                        parameters: syntax.parameters,
                        isGeneric: inheritedGeneric || !syntax.parameters.isEmpty,
                        range: syntax.range,
                        payload: .structure(
                            StructIR(
                                dataWords: 0, pointerCount: 0, discriminantCount: 0,
                                discriminantOffset: 0, isGroup: false, fields: []))))
                let structure = try translateStruct(
                    syntax.members, file: file, parentID: id, path: path + [syntax.name],
                    parameters: allParameters)
                result[nodeIndex].payload = .structure(structure)
                try translateDeclarations(
                    nestedDeclarations(syntax.members), file: file, parentID: id,
                    path: path + [syntax.name], parameters: allParameters,
                    inheritedGeneric: inheritedGeneric || !syntax.parameters.isEmpty)
            case .enumeration(let syntax):
                let id = syntax.id ?? TypeID.child(parent: parentID, name: syntax.name)
                result.append(
                    NodeIR(
                        id: id, scopeID: parentID,
                        displayName: displayName(file: file, path: path + [syntax.name]),
                        displayNamePrefixLength: displayPrefix(
                            file: file, path: path + [syntax.name]), name: syntax.name,
                        nested: [],
                        annotations: try resolveAnnotations(
                            syntax.annotations, file: file, path: path, parameters: parameters),
                        parameters: [], isGeneric: inheritedGeneric,
                        range: syntax.range,
                        payload: .enumeration(
                            try syntax.enumerants.sorted { $0.ordinal < $1.ordinal }.map {
                                EnumerantIR(
                                    syntax: $0,
                                    annotations: try resolveAnnotations(
                                        $0.annotations, file: file,
                                        path: path + [syntax.name], parameters: parameters))
                            }))
                )
            case .interface(let syntax):
                let id = syntax.id ?? TypeID.child(parent: parentID, name: syntax.name)
                let local = syntax.parameters.enumerated().map {
                    GenericParameter(name: $0.element, scopeID: id, index: UInt16($0.offset))
                }
                let allParameters = parameters + local
                let nestedDeclarations = syntax.members.compactMap {
                    if case .declaration(let value) = $0 { return value }; return nil
                }
                let nested = topLevelNested(
                    nestedDeclarations, file: file, parentID: id, path: path + [syntax.name])
                var methods: [MethodIR] = []
                for member in syntax.members {
                    guard case .method(let method) = member else { continue }
                    let codeOrder = UInt16(methods.count)
                    let implicit = method.typeParameters.enumerated().map {
                        GenericParameter(
                            name: $0.element, scopeID: 0, index: UInt16($0.offset), implicit: true)
                    }
                    let methodParams = allParameters + implicit
                    let paramID: UInt64
                    let paramType: TypeIR
                    if method.parameters.count == 1, method.parameters[0].name == "params",
                        case .named = method.parameters[0].type
                    {
                        paramType = try resolveType(
                            method.parameters[0].type, file: file, path: path + [syntax.name],
                            parameters: methodParams)
                        paramID = try nodeID(paramType)
                    } else {
                        paramID = TypeID.method(parent: id, ordinal: method.ordinal, results: false)
                        paramType = .node(
                            id: paramID, kind: .structure, arguments: [],
                            brand: inheritedBrand(parameters: methodParams, syntheticID: paramID))
                        try appendMethodStruct(
                            id: paramID, name: method.name + "Params", values: method.parameters,
                            file: file, path: path + [syntax.name], parameters: methodParams,
                            range: method.range)
                    }
                    let resultID: UInt64
                    let resultType: TypeIR
                    switch method.results {
                    case .stream:
                        resultID = 0x995f_9a33_77c0_b16e
                        resultType = .node(
                            id: resultID, kind: .structure, arguments: [],
                            brand: inheritedBrand(parameters: methodParams, syntheticID: resultID))
                    case .named(let type):
                        resultType = try resolveType(
                            type, file: file, path: path + [syntax.name], parameters: methodParams)
                        resultID = try nodeID(resultType)
                    case .parameters(let values):
                        resultID = TypeID.method(parent: id, ordinal: method.ordinal, results: true)
                        resultType = .node(
                            id: resultID, kind: .structure, arguments: [],
                            brand: inheritedBrand(parameters: methodParams, syntheticID: resultID))
                        try appendMethodStruct(
                            id: resultID, name: method.name + "Results", values: values,
                            file: file, path: path + [syntax.name], parameters: methodParams,
                            range: method.range)
                    }
                    methods.append(
                        MethodIR(
                            syntax: method, codeOrder: codeOrder,
                            annotations: try resolveAnnotations(
                                method.annotations, file: file,
                                path: path + [syntax.name], parameters: methodParams),
                            paramID: paramID, resultID: resultID,
                            paramType: paramType, resultType: resultType))
                }
                let supers = try syntax.superclasses.map {
                    try resolveType(
                        $0, file: file, path: path + [syntax.name], parameters: allParameters)
                }
                result.append(
                    NodeIR(
                        id: id, scopeID: parentID,
                        displayName: displayName(file: file, path: path + [syntax.name]),
                        displayNamePrefixLength: displayPrefix(
                            file: file, path: path + [syntax.name]), name: syntax.name,
                        nested: nested,
                        annotations: try resolveAnnotations(
                            syntax.annotations, file: file, path: path, parameters: parameters),
                        parameters: syntax.parameters,
                        isGeneric: inheritedGeneric || !syntax.parameters.isEmpty,
                        range: syntax.range,
                        payload: .interface(
                            methods: methods.sorted { $0.syntax.ordinal < $1.syntax.ordinal },
                            superclasses: supers)))
                try translateDeclarations(
                    nestedDeclarations, file: file, parentID: id, path: path + [syntax.name],
                    parameters: allParameters,
                    inheritedGeneric: inheritedGeneric || !syntax.parameters.isEmpty)
            case .constant(let syntax):
                let id = TypeID.child(parent: parentID, name: syntax.name)
                result.append(
                    NodeIR(
                        id: id, scopeID: parentID,
                        displayName: displayName(file: file, path: path + [syntax.name]),
                        displayNamePrefixLength: displayPrefix(
                            file: file, path: path + [syntax.name]), name: syntax.name,
                        nested: [],
                        annotations: try resolveAnnotations(
                            syntax.annotations, file: file, path: path, parameters: parameters),
                        parameters: [], isGeneric: inheritedGeneric,
                        range: syntax.range,
                        payload: .constant(
                            type: try resolveType(
                                syntax.type, file: file, path: path, parameters: parameters),
                            value: absoluteEmbeds(syntax.value, relativeTo: file.url))))
            case .annotation(let syntax):
                let id = syntax.id ?? TypeID.child(parent: parentID, name: syntax.name)
                result.append(
                    NodeIR(
                        id: id, scopeID: parentID,
                        displayName: displayName(file: file, path: path + [syntax.name]),
                        displayNamePrefixLength: displayPrefix(
                            file: file, path: path + [syntax.name]), name: syntax.name,
                        nested: [],
                        annotations: try resolveAnnotations(
                            syntax.annotations, file: file, path: path, parameters: parameters),
                        parameters: [], isGeneric: inheritedGeneric,
                        range: syntax.range,
                        payload: .annotation(
                            type: try resolveType(
                                syntax.type, file: file, path: path, parameters: parameters),
                            targets: syntax.targets)))
            }
        }
    }

    mutating func appendMethodStruct(
        id: UInt64, name: String, values: [ParameterSyntax], file: ResolvedFile,
        path: [String], parameters: [GenericParameter], range: SourceRange
    ) throws {
        let ownedParameters = parameters.map { parameter in
            parameter.implicit
                ? GenericParameter(
                    name: parameter.name, scopeID: id, index: parameter.index, implicit: false)
                : parameter
        }
        let fields = values.map {
            FieldSyntax(
                name: $0.name, ordinal: UInt16(values.firstIndex(of: $0)!), type: $0.type,
                defaultValue: $0.defaultValue, annotations: $0.annotations, range: $0.range,
                docComment: nil)
        }
        let structure = try translateStruct(
            fields.map(StructMemberSyntax.field), file: file, parentID: id, path: path,
            parameters: ownedParameters)
        let displayComponent: String
        if name.hasSuffix("Params") {
            displayComponent = String(name.dropLast("Params".count)) + "$Params"
        } else if name.hasSuffix("Results") {
            displayComponent = String(name.dropLast("Results".count)) + "$Results"
        } else {
            displayComponent = name
        }
        result.append(
            NodeIR(
                id: id, scopeID: 0,
                displayName: displayName(file: file, path: path + [displayComponent]),
                displayNamePrefixLength: displayPrefix(
                    file: file, path: path + [displayComponent]), name: name,
                nested: [], annotations: [],
                parameters: parameters.filter(\.implicit).map(\.name),
                isGeneric: !parameters.isEmpty, range: range,
                payload: .structure(structure)))
    }

    mutating func translateStruct(
        _ members: [StructMemberSyntax], file: ResolvedFile, parentID: UInt64, path: [String],
        parameters: [GenericParameter], isGroup: Bool = false
    ) throws -> StructIR {
        let top = TopLayoutScope()
        let root = PlannedStructScope(
            name: path.last ?? file.sourceName, path: path,
            range: SourceRange(startByte: 0, endByte: 0), isGroup: isGroup)
        var events: [PlannedLayoutEvent] = []
        var unions: [UnionLayoutScope] = []
        var codeOrder: UInt16 = 0
        try planMembers(
            members, file: file, path: path, parameters: parameters, output: root,
            layout: top, containingUnion: nil, codeOrder: &codeOrder,
            events: &events, unions: &unions)

        for event in events.sorted(by: {
            $0.ordinal == $1.ordinal ? $0.sequence < $1.sequence : $0.ordinal < $1.ordinal
        }) {
            switch event.action {
            case .field(let field):
                switch storage(field.type) {
                case .void:
                    field.layout.addVoid(); field.offset = 0
                case .pointer:
                    field.offset = UInt32(field.layout.addPointer())
                case .data(let bits):
                    field.offset = UInt32(field.layout.addData(lgSize: bits.trailingZeroBitCount))
                }
            case .union(let union):
                guard union.addDiscriminant() else {
                    throw NativeCompilerError.unsupported(
                        "union ordinal may retroactively unionize at most one field")
                }
            }
        }
        for union in unions { _ = union.addDiscriminant() }

        let dataWords = UInt16(top.dataWordCount)
        let pointerCount = UInt16(top.pointerCount)
        return try materializeScope(
            root, file: file, parentID: parentID, parameters: parameters,
            dataWords: dataWords, pointerCount: pointerCount)
    }

    mutating func planMembers(
        _ members: [StructMemberSyntax], file: ResolvedFile, path: [String],
        parameters: [GenericParameter], output: PlannedStructScope,
        layout: any LayoutScope, containingUnion: UnionLayoutScope?,
        codeOrder: inout UInt16, events: inout [PlannedLayoutEvent],
        unions: inout [UnionLayoutScope]
    ) throws {
        for member in members {
            switch member {
            case .field(let field):
                let type = try resolveType(
                    field.type, file: file, path: path, parameters: parameters)
                let fieldLayout: any LayoutScope
                if let containingUnion {
                    fieldLayout = GroupLayoutScope(parent: containingUnion)
                } else {
                    fieldLayout = layout
                }
                let planned = PlannedField(
                    syntax: field, type: type, codeOrder: codeOrder,
                    discriminant: nil, layout: fieldLayout)
                output.members.append(.field(planned))
                events.append(
                    PlannedLayoutEvent(
                        ordinal: field.ordinal, sequence: events.count, action: .field(planned)))
                codeOrder &+= 1
            case .union(let children, _, _):
                try planUnion(
                    children, explicitOrdinal: nil, name: nil, annotations: [],
                    range: memberRange(member),
                    file: file, path: path, parameters: parameters, output: output,
                    parentLayout: layout, containingUnion: containingUnion,
                    parentCodeOrder: &codeOrder, events: &events, unions: &unions)
            case .group(let group):
                let child = PlannedStructScope(
                    name: group.name, path: path + [group.name], range: group.range,
                    isGroup: true)
                let childLayout: any LayoutScope
                if let containingUnion {
                    childLayout = GroupLayoutScope(parent: containingUnion)
                } else {
                    childLayout = layout
                }
                output.members.append(
                    .group(
                        PlannedGroup(
                            scope: child, codeOrder: codeOrder, ordinal: nil,
                            discriminant: nil, annotations: group.annotations,
                            range: group.range)))
                codeOrder &+= 1
                var childCodeOrder: UInt16 = 0
                try planMembers(
                    group.members, file: file, path: path + [group.name],
                    parameters: parameters, output: child, layout: childLayout,
                    containingUnion: nil, codeOrder: &childCodeOrder,
                    events: &events, unions: &unions)
            case .namedUnion(let group, let explicitOrdinal):
                try planUnion(
                    group.members, explicitOrdinal: explicitOrdinal, name: group.name,
                    annotations: group.annotations,
                    range: group.range, file: file, path: path, parameters: parameters,
                    output: output, parentLayout: layout, containingUnion: containingUnion,
                    parentCodeOrder: &codeOrder, events: &events, unions: &unions)
            case .declaration: break
            }
        }
    }

    mutating func planUnion(
        _ children: [StructMemberSyntax], explicitOrdinal: UInt16?, name: String?,
        annotations: [AnnotationUseSyntax],
        range: SourceRange, file: ResolvedFile, path: [String],
        parameters: [GenericParameter], output parentOutput: PlannedStructScope,
        parentLayout: any LayoutScope, containingUnion outerUnion: UnionLayoutScope?,
        parentCodeOrder: inout UInt16, events: inout [PlannedLayoutEvent],
        unions: inout [UnionLayoutScope]
    ) throws {
        let unionParent: any LayoutScope
        if let outerUnion {
            unionParent = GroupLayoutScope(parent: outerUnion)
        } else {
            unionParent = parentLayout
        }
        let union = UnionLayoutScope(parent: unionParent)
        unions.append(union)

        let unionOutput: PlannedStructScope
        if let name {
            unionOutput = PlannedStructScope(
                name: name, path: path + [name], range: range, isGroup: true)
            unionOutput.union = union
            parentOutput.members.append(
                .group(
                    PlannedGroup(
                        scope: unionOutput, codeOrder: parentCodeOrder,
                        ordinal: explicitOrdinal, discriminant: nil,
                        annotations: annotations, range: range)))
            parentCodeOrder &+= 1
        } else {
            unionOutput = parentOutput
            unionOutput.union = union
        }

        let ordered = children.enumerated().sorted {
            let left = minimumOrdinal($0.element) ?? UInt16.max
            let right = minimumOrdinal($1.element) ?? UInt16.max
            return left == right ? $0.offset < $1.offset : left < right
        }
        var tagByStart: [Int: UInt16] = [:]
        for (tag, value) in ordered.enumerated() {
            tagByStart[memberRange(value.element).startByte] = UInt16(clamping: tag)
        }

        var unionCodeOrder: UInt16 = name == nil ? parentCodeOrder : 0
        for childMember in children {
            let tag = tagByStart[memberRange(childMember).startByte] ?? 0
            switch childMember {
            case .field(let field):
                let type = try resolveType(
                    field.type, file: file, path: unionOutput.path, parameters: parameters)
                let planned = PlannedField(
                    syntax: field, type: type, codeOrder: unionCodeOrder,
                    discriminant: tag, layout: GroupLayoutScope(parent: union))
                unionOutput.members.append(.field(planned))
                events.append(
                    PlannedLayoutEvent(
                        ordinal: field.ordinal, sequence: events.count, action: .field(planned)))
                unionCodeOrder &+= 1
            case .group(let group):
                let child = PlannedStructScope(
                    name: group.name, path: unionOutput.path + [group.name], range: group.range,
                    isGroup: true)
                unionOutput.members.append(
                    .group(
                        PlannedGroup(
                            scope: child, codeOrder: unionCodeOrder, ordinal: nil,
                            discriminant: tag, annotations: group.annotations,
                            range: group.range)))
                unionCodeOrder &+= 1
                var childCodeOrder: UInt16 = 0
                try planMembers(
                    group.members, file: file, path: child.path, parameters: parameters,
                    output: child, layout: GroupLayoutScope(parent: union),
                    containingUnion: nil, codeOrder: &childCodeOrder,
                    events: &events, unions: &unions)
            case .namedUnion(let group, let ordinal):
                try planUnion(
                    group.members, explicitOrdinal: ordinal, name: group.name,
                    annotations: group.annotations,
                    range: group.range, file: file, path: unionOutput.path,
                    parameters: parameters, output: unionOutput,
                    parentLayout: GroupLayoutScope(parent: union), containingUnion: nil,
                    parentCodeOrder: &unionCodeOrder, events: &events, unions: &unions)
                if case .group(var planned) = unionOutput.members.removeLast() {
                    planned.discriminant = tag
                    unionOutput.members.append(.group(planned))
                }
            case .union(let nested, _, let nestedRange):
                try planUnion(
                    nested, explicitOrdinal: nil, name: nil, annotations: [],
                    range: nestedRange,
                    file: file, path: unionOutput.path, parameters: parameters,
                    output: unionOutput, parentLayout: GroupLayoutScope(parent: union),
                    containingUnion: nil, parentCodeOrder: &unionCodeOrder,
                    events: &events, unions: &unions)
            case .declaration: break
            }
        }
        if name == nil { parentCodeOrder = unionCodeOrder }
        if let explicitOrdinal {
            events.append(
                PlannedLayoutEvent(
                    ordinal: explicitOrdinal, sequence: events.count, action: .union(union)))
        }
    }

    mutating func materializeScope(
        _ scope: PlannedStructScope, file: ResolvedFile, parentID: UInt64,
        parameters: [GenericParameter], dataWords: UInt16, pointerCount: UInt16
    ) throws -> StructIR {
        let members = scope.members.enumerated().sorted {
            let left = plannedOrdinal($0.element)
            let right = plannedOrdinal($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }
        var fields: [FieldIR] = []
        for (index, item) in members.enumerated() {
            switch item.element {
            case .field(let field):
                fields.append(
                    FieldIR(
                        name: field.syntax.name, codeOrder: field.codeOrder,
                        ordinal: field.syntax.ordinal, discriminant: field.discriminant,
                        annotations: try resolveAnnotations(
                            field.syntax.annotations, file: file, path: scope.path,
                            parameters: parameters),
                        payload: .slot(
                            offset: field.offset, type: field.type,
                            defaultValue: field.syntax.defaultValue.map {
                                absoluteEmbeds($0, relativeTo: file.url)
                            },
                            explicit: field.syntax.defaultValue != nil),
                        range: field.syntax.range))
            case .group(let group):
                let id = TypeID.group(parent: parentID, index: UInt16(clamping: index))
                let structure = try materializeScope(
                    group.scope, file: file, parentID: id, parameters: parameters,
                    dataWords: dataWords, pointerCount: pointerCount)
                result.append(
                    NodeIR(
                        id: id, scopeID: parentID,
                        displayName: displayName(file: file, path: group.scope.path),
                        displayNamePrefixLength: displayPrefix(file: file, path: group.scope.path),
                        name: group.scope.name, nested: [], annotations: [], parameters: [],
                        isGeneric: !parameters.isEmpty, range: group.range,
                        payload: .structure(structure)))
                fields.append(
                    FieldIR(
                        name: group.scope.name, codeOrder: group.codeOrder,
                        ordinal: group.ordinal, discriminant: group.discriminant,
                        annotations: try resolveAnnotations(
                            group.annotations, file: file, path: scope.path,
                            parameters: parameters),
                        payload: .group(id), range: group.range))
            }
        }
        return StructIR(
            dataWords: dataWords, pointerCount: pointerCount,
            discriminantCount: UInt16(scope.union?.groupCount ?? 0),
            discriminantOffset: UInt32(scope.union?.discriminantOffset ?? 0),
            isGroup: scope.isGroup, fields: fields)
    }

    func resolveType(
        _ syntax: TypeSyntax, file: ResolvedFile, path: [String], parameters: [GenericParameter],
        seen: Set<String> = []
    ) throws -> TypeIR {
        switch syntax {
        case .list(let element):
            return .list(
                try resolveType(element, file: file, path: path, parameters: parameters, seen: seen)
            )
        case .named(let name, let arguments):
            if name.root == .relative, name.components.count == 1 {
                if let tag = primitiveTags[name.components[0]] { return .primitive(tag) }
                if let parameter = parameters.last(where: { $0.name == name.components[0] }) {
                    return parameter.implicit
                        ? .implicitParameter(parameter.index)
                        : .parameter(scopeID: parameter.scopeID, index: parameter.index)
                }
            }
            if name.root == .relative {
                for depth in stride(from: path.count, through: 0, by: -1) {
                    let base = Array(path.prefix(depth))
                    for aliasIndex in name.components.indices {
                        let aliasScope = base + name.components[..<aliasIndex]
                        let aliasName = name.components[aliasIndex]
                        if let target = aliases[IRScope(fileID: file.id, path: Array(aliasScope))]?[
                            aliasName]
                        {
                            let key = "\(file.id):\(aliasScope.joined(separator: ".")):\(aliasName)"
                            guard !seen.contains(key) else {
                                throw NativeCompilerError.unsupported("alias cycle \(aliasName)")
                            }
                            if case .named(let targetName, let targetArguments) = target,
                                targetArguments.isEmpty, targetName.root == .relative,
                                targetName.components.count == 1,
                                let parameterIndex = genericParameters[
                                    IRScope(fileID: file.id, path: Array(aliasScope))]?.firstIndex(
                                        of: targetName.components[0]),
                                parameterIndex < arguments.count
                            {
                                return try resolveType(
                                    arguments[parameterIndex], file: file, path: path,
                                    parameters: parameters, seen: seen.union([key]))
                            }
                            guard case .named(let targetName, let targetArguments) = target else {
                                return try resolveType(
                                    target, file: file, path: Array(aliasScope),
                                    parameters: parameters, seen: seen.union([key]))
                            }
                            let ownerParameters =
                                genericParameters[IRScope(fileID: file.id, path: Array(aliasScope))]
                                ?? []
                            let substitutedArguments = targetArguments.map {
                                substitute(
                                    $0, parameterNames: ownerParameters, arguments: arguments)
                            }
                            let ownerArgumentCount = ownerParameters.count
                            let retainsOwnerArguments =
                                targetName.components.first != aliasScope.last
                            let prefix =
                                retainsOwnerArguments
                                ? Array(arguments.prefix(ownerArgumentCount)) : []
                            let combined = TypeSyntax.named(
                                NameSyntax(
                                    root: targetName.root,
                                    components: targetName.components
                                        + name.components.dropFirst(aliasIndex + 1),
                                    range: name.range),
                                arguments: substitutedArguments.isEmpty
                                    ? arguments : prefix + substitutedArguments)
                            return try resolveType(
                                combined, file: file, path: Array(aliasScope),
                                parameters: parameters, seen: seen.union([key]))
                        }
                    }
                }
            }
            let targetFile: ResolvedFile
            let components: [String]
            switch name.root {
            case .imported(let importPath):
                guard let imported = file.imports.first(where: { $0.path == importPath }),
                    let value = fileByID[imported.fileID]
                else {
                    throw NativeCompilerError.unsupported("unresolved import \(importPath)")
                }
                targetFile = value; components = name.components
            case .absolute:
                targetFile = file; components = name.components
            case .relative:
                targetFile = file
                var found: [String]?
                for depth in stride(from: path.count, through: 0, by: -1) {
                    let candidate = Array(path.prefix(depth)) + name.components
                    if nodeByKey[IRNodeKey(source: file.sourceName, path: candidate)] != nil {
                        found = candidate; break
                    }
                }
                components = found ?? name.components
            }
            guard let node = nodeByKey[IRNodeKey(source: targetFile.sourceName, path: components)]
            else {
                throw NativeCompilerError.unsupported(
                    "unresolved type \(components.joined(separator: "."))")
            }
            let resolvedArguments = try arguments.map {
                try resolveType($0, file: file, path: path, parameters: parameters, seen: seen)
            }
            var brand: [BrandScopeIR] = []
            var argumentIndex = 0
            for depth in 1...components.count {
                let ownerPath = Array(components.prefix(depth))
                let names =
                    genericParameters[
                        IRScope(fileID: targetFile.id, path: ownerPath)] ?? []
                guard !names.isEmpty,
                    let owner = nodeByKey[
                        IRNodeKey(source: targetFile.sourceName, path: ownerPath)]
                else { continue }
                if argumentIndex + names.count <= resolvedArguments.count {
                    brand.append(
                        BrandScopeIR(
                            scopeID: owner.id,
                            bindings: Array(
                                resolvedArguments[argumentIndex..<(argumentIndex + names.count)])))
                    argumentIndex += names.count
                } else if parameters.contains(where: { $0.scopeID == owner.id }),
                    !name.components.contains(ownerPath.last!)
                {
                    brand.append(BrandScopeIR(scopeID: owner.id, bindings: nil))
                }
            }
            return .node(
                id: node.id, kind: node.kind, arguments: resolvedArguments,
                brand: Array(brand.reversed()))
        }
    }

    func nodeID(_ type: TypeIR) throws -> UInt64 {
        guard case .node(let id, .structure, _, _) = type else {
            throw NativeCompilerError.unsupported("method parameter/result type must be a struct")
        }
        return id
    }

    func inheritedBrand(
        parameters: [GenericParameter], syntheticID _: UInt64
    ) -> [BrandScopeIR] {
        var ids: [UInt64] = []
        for parameter in parameters.reversed() {
            if parameter.implicit { continue }
            let id = parameter.scopeID
            if !ids.contains(id) { ids.append(id) }
        }
        return ids.map { BrandScopeIR(scopeID: $0, bindings: nil) }
    }

    func resolveAnnotations(
        _ uses: [AnnotationUseSyntax], file: ResolvedFile, path: [String],
        parameters: [GenericParameter]
    ) throws -> [AnnotationIR] {
        try uses.map { use in
            let reference = try resolveType(
                .named(use.name, arguments: use.brandArguments), file: file, path: path,
                parameters: parameters)
            guard case .node(let id, .annotation, _, let brand) = reference,
                let declaration = annotationByID[id]
            else {
                throw NativeCompilerError.unsupported(
                    "unresolved annotation \(use.name.components.joined(separator: "."))")
            }
            let declarationParameters = parametersForPath(
                file: declaration.file, path: declaration.path)
            let unresolvedType = try resolveType(
                declaration.syntax.type, file: declaration.file, path: declaration.path,
                parameters: declarationParameters)
            var bindings: [UInt64: [TypeIR]] = [:]
            for scope in brand {
                if let values = scope.bindings { bindings[scope.scopeID] = values }
            }
            let type = substituteResolved(unresolvedType, using: bindings)
            return AnnotationIR(
                id: id, type: type,
                value: absoluteEmbeds(
                    use.value ?? RequestWriter.zeroValue(for: type), relativeTo: file.url),
                brand: brand)
        }
    }

    func parametersForPath(file: ResolvedFile, path: [String]) -> [GenericParameter] {
        var result: [GenericParameter] = []
        guard !path.isEmpty else { return result }
        for depth in 1...path.count {
            let ownerPath = Array(path.prefix(depth))
            guard let names = genericParameters[IRScope(fileID: file.id, path: ownerPath)],
                let node = nodeByKey[IRNodeKey(source: file.sourceName, path: ownerPath)]
            else { continue }
            result += names.enumerated().map {
                GenericParameter(name: $0.element, scopeID: node.id, index: UInt16($0.offset))
            }
        }
        return result
    }

    func substituteResolved(
        _ type: TypeIR, using bindings: [UInt64: [TypeIR]]
    ) -> TypeIR {
        switch type {
        case .parameter(let scopeID, let index):
            guard let values = bindings[scopeID], Int(index) < values.count else { return type }
            return values[Int(index)]
        case .list(let element): return .list(substituteResolved(element, using: bindings))
        case .node(let id, let kind, let arguments, let brand):
            return .node(
                id: id, kind: kind,
                arguments: arguments.map { substituteResolved($0, using: bindings) },
                brand: brand.map {
                    BrandScopeIR(
                        scopeID: $0.scopeID,
                        bindings: $0.bindings?.map { substituteResolved($0, using: bindings) })
                })
        default: return type
        }
    }

    func declarationNameAndID(
        _ declaration: DeclarationSyntax, file: ResolvedFile, parentID: UInt64, path: [String]
    ) -> (String, UInt64)? {
        switch declaration {
        case .structure(let value):
            return (value.name, value.id ?? TypeID.child(parent: parentID, name: value.name))
        case .enumeration(let value):
            return (value.name, value.id ?? TypeID.child(parent: parentID, name: value.name))
        case .interface(let value):
            return (value.name, value.id ?? TypeID.child(parent: parentID, name: value.name))
        case .constant(let value):
            return (value.name, TypeID.child(parent: parentID, name: value.name))
        case .annotation(let value):
            return (value.name, value.id ?? TypeID.child(parent: parentID, name: value.name))
        case .application, .using: return nil
        }
    }

    func displayName(file: ResolvedFile, path: [String]) -> String {
        file.sourceName + ":" + path.joined(separator: ".")
    }
    func displayPrefix(file: ResolvedFile, path: [String]) -> UInt32 {
        UInt32((file.sourceName + ":" + path.dropLast().map { $0 + "." }.joined()).utf8.count)
    }

    func absoluteEmbeds(_ value: ValueSyntax, relativeTo sourceURL: URL) -> ValueSyntax {
        switch value {
        case .embed(let path):
            if path.hasPrefix("/") { return .embed(path) }
            return .embed(
                sourceURL.deletingLastPathComponent().appending(path: path).standardizedFileURL.path
            )
        case .list(let values):
            return .list(values.map { absoluteEmbeds($0, relativeTo: sourceURL) })
        case .tuple(let fields):
            return .tuple(fields.map { ($0.0, absoluteEmbeds($0.1, relativeTo: sourceURL)) })
        default: return value
        }
    }
}

private struct GenericParameter {
    var name: String; var scopeID: UInt64; var index: UInt16; var implicit = false
}
private struct IRScope: Hashable { var fileID: UInt64; var path: [String] }
private struct IRNodeKey: Hashable { var source: String; var path: [String] }

private final class PlannedField {
    let syntax: FieldSyntax
    let type: TypeIR
    let codeOrder: UInt16
    let discriminant: UInt16?
    let layout: any LayoutScope
    var offset: UInt32 = 0

    init(
        syntax: FieldSyntax, type: TypeIR, codeOrder: UInt16, discriminant: UInt16?,
        layout: any LayoutScope
    ) {
        self.syntax = syntax
        self.type = type
        self.codeOrder = codeOrder
        self.discriminant = discriminant
        self.layout = layout
    }
}

private struct PlannedGroup {
    let scope: PlannedStructScope
    let codeOrder: UInt16
    let ordinal: UInt16?
    var discriminant: UInt16?
    let annotations: [AnnotationUseSyntax]
    let range: SourceRange
}

private enum PlannedMember {
    case field(PlannedField)
    case group(PlannedGroup)
}

private final class PlannedStructScope {
    let name: String
    let path: [String]
    let range: SourceRange
    let isGroup: Bool
    var members: [PlannedMember] = []
    var union: UnionLayoutScope?

    init(name: String, path: [String], range: SourceRange, isGroup: Bool) {
        self.name = name
        self.path = path
        self.range = range
        self.isGroup = isGroup
    }
}

private struct PlannedLayoutEvent {
    enum Action {
        case field(PlannedField)
        case union(UnionLayoutScope)
    }
    let ordinal: UInt16
    let sequence: Int
    let action: Action
}

private func plannedOrdinal(_ member: PlannedMember) -> UInt16 {
    switch member {
    case .field(let field): return field.syntax.ordinal
    case .group(let group):
        if let ordinal = group.ordinal { return ordinal }
        return group.scope.members.map(plannedOrdinal).min() ?? UInt16.max
    }
}

private func memberRange(_ member: StructMemberSyntax) -> SourceRange {
    switch member {
    case .field(let value): return value.range
    case .group(let value), .namedUnion(let value, _): return value.range
    case .union(_, _, let range): return range
    case .declaration(let declaration):
        switch declaration {
        case .application(let value): return value.range
        case .using(let value): return value.range
        case .structure(let value): return value.range
        case .enumeration(let value): return value.range
        case .interface(let value): return value.range
        case .constant(let value): return value.range
        case .annotation(let value): return value.range
        }
    }
}

private func nestedDeclarations(_ members: [StructMemberSyntax]) -> [DeclarationSyntax] {
    var result: [DeclarationSyntax] = []
    for member in members {
        switch member {
        case .declaration(let value): result.append(value)
        case .group(let value), .namedUnion(let value, _):
            result.append(contentsOf: nestedDeclarations(value.members))
        case .union(let values, _, _): result.append(contentsOf: nestedDeclarations(values))
        case .field: break
        }
    }
    return result
}

private func directFields(_ members: [StructMemberSyntax]) -> [FieldSyntax] {
    members.compactMap {
        if case .field(let value) = $0 { return value }; return nil
    }
}

private func minimumOrdinal(_ member: StructMemberSyntax) -> UInt16? {
    switch member {
    case .field(let value): return value.ordinal
    case .group(let value): return value.members.compactMap(minimumOrdinal).min()
    case .union(let values, _, _): return values.compactMap(minimumOrdinal).min()
    case .namedUnion(let value, let ordinal):
        return ordinal ?? value.members.compactMap(minimumOrdinal).min()
    case .declaration: return nil
    }
}

private func syntaxTypeName(_ type: TypeSyntax) -> NameSyntax? {
    if case .named(let name, _) = type { return name }; return nil
}

private func substitute(
    _ type: TypeSyntax, parameterNames: [String], arguments: [TypeSyntax]
) -> TypeSyntax {
    switch type {
    case .list(let element):
        return .list(substitute(element, parameterNames: parameterNames, arguments: arguments))
    case .named(let name, let nestedArguments):
        if name.root == .relative, name.components.count == 1,
            let index = parameterNames.firstIndex(of: name.components[0]), index < arguments.count
        {
            return arguments[index]
        }
        return .named(
            name,
            arguments: nestedArguments.map {
                substitute($0, parameterNames: parameterNames, arguments: arguments)
            })
    }
}

private let primitiveTags: [String: UInt16] = [
    "Void": 0, "Bool": 1, "Int8": 2, "Int16": 3, "Int32": 4, "Int64": 5,
    "UInt8": 6, "UInt16": 7, "UInt32": 8, "UInt64": 9, "Float32": 10,
    "Float64": 11, "Text": 12, "Data": 13, "AnyPointer": 18, "AnyStruct": 25,
    "AnyList": 26, "Capability": 27,
]

private enum Storage { case void, data(Int), pointer }
private func storage(_ type: TypeIR) -> Storage {
    switch type {
    case .primitive(let tag):
        switch tag {
        case 0: return .void
        case 1: return .data(1)
        case 2, 6: return .data(8)
        case 3, 7: return .data(16)
        case 4, 8, 10: return .data(32)
        case 5, 9, 11: return .data(64)
        default: return .pointer
        }
    case .node(_, let kind, _, _): return kind == .enumeration ? .data(16) : .pointer
    case .list, .parameter, .implicitParameter: return .pointer
    }
}

private protocol LayoutScope: AnyObject {
    func addVoid()
    func addData(lgSize: Int) -> Int
    func addPointer() -> Int
    func tryExpandData(oldLgSize: Int, oldOffset: Int, expansionFactor: Int) -> Bool
}

private final class LayoutHoleSet {
    private(set) var holes = [Int](repeating: 0, count: 6)

    func tryAllocate(_ lgSize: Int) -> Int? {
        guard lgSize < holes.count else { return nil }
        if holes[lgSize] != 0 {
            defer { holes[lgSize] = 0 }
            return holes[lgSize]
        }
        guard let next = tryAllocate(lgSize + 1) else { return nil }
        let result = next * 2
        holes[lgSize] = result + 1
        return result
    }

    func addHolesAtEnd(_ lgSize: Int, _ offset: Int, limit: Int = 6) {
        var size = lgSize
        var position = offset
        while size < limit {
            precondition(holes[size] == 0 && position & 1 == 1)
            holes[size] = position
            size += 1
            position = (position + 1) / 2
        }
    }

    func tryExpand(oldLgSize: Int, oldOffset: Int, expansionFactor: Int) -> Bool {
        if expansionFactor == 0 { return true }
        guard oldLgSize < holes.count, holes[oldLgSize] == oldOffset + 1 else { return false }
        guard
            tryExpand(
                oldLgSize: oldLgSize + 1, oldOffset: oldOffset >> 1,
                expansionFactor: expansionFactor - 1)
        else { return false }
        holes[oldLgSize] = 0
        return true
    }

    func smallestAtLeast(_ size: Int) -> Int? {
        guard size < holes.count else { return nil }
        return (size..<holes.count).first { holes[$0] != 0 }
    }
}

private final class TopLayoutScope: LayoutScope {
    var dataWordCount = 0
    var pointerCount = 0
    private let holes = LayoutHoleSet()

    func addVoid() {}
    func addData(lgSize: Int) -> Int {
        if let hole = holes.tryAllocate(lgSize) { return hole }
        let result = dataWordCount << (6 - lgSize)
        dataWordCount += 1
        holes.addHolesAtEnd(lgSize, result + 1)
        return result
    }
    func addPointer() -> Int { defer { pointerCount += 1 }; return pointerCount }
    func tryExpandData(oldLgSize: Int, oldOffset: Int, expansionFactor: Int) -> Bool {
        holes.tryExpand(
            oldLgSize: oldLgSize, oldOffset: oldOffset, expansionFactor: expansionFactor)
    }
}

private final class UnionDataLocation {
    var lgSize: Int
    var offset: Int
    init(lgSize: Int, offset: Int) { self.lgSize = lgSize; self.offset = offset }

    func tryExpand(to newLgSize: Int, union: UnionLayoutScope) -> Bool {
        if newLgSize <= lgSize { return true }
        guard
            union.parent.tryExpandData(
                oldLgSize: lgSize, oldOffset: offset, expansionFactor: newLgSize - lgSize)
        else { return false }
        offset >>= newLgSize - lgSize
        lgSize = newLgSize
        return true
    }
}

private final class UnionLayoutScope {
    let parent: any LayoutScope
    var groupCount = 0
    var discriminantOffset: Int?
    var dataLocations: [UnionDataLocation] = []
    var pointerLocations: [Int] = []

    init(parent: any LayoutScope) { self.parent = parent }

    func addNewDataLocation(lgSize: Int) -> Int {
        let offset = parent.addData(lgSize: lgSize)
        dataLocations.append(UnionDataLocation(lgSize: lgSize, offset: offset))
        return offset
    }
    func addNewPointerLocation() -> Int {
        let value = parent.addPointer()
        pointerLocations.append(value)
        return value
    }
    func newGroupAddingFirstMember() {
        groupCount += 1
        if groupCount == 2 { _ = addDiscriminant() }
    }
    @discardableResult func addDiscriminant() -> Bool {
        guard discriminantOffset == nil else { return false }
        discriminantOffset = parent.addData(lgSize: 4)
        return true
    }
}

private final class GroupDataLocationUsage {
    var isUsed = false
    var lgSizeUsed = 0
    let holes = LayoutHoleSet()

    convenience init(lgSize: Int) {
        self.init(); isUsed = true; lgSizeUsed = lgSize
    }

    func smallestHoleAtLeast(location: UnionDataLocation, lgSize: Int) -> Int? {
        if !isUsed { return lgSize <= location.lgSize ? location.lgSize : nil }
        if lgSize >= lgSizeUsed { return lgSize < location.lgSize ? lgSize : nil }
        if let result = holes.smallestAtLeast(lgSize) { return result }
        return lgSizeUsed < location.lgSize ? lgSizeUsed : nil
    }

    func allocateFromHole(location: UnionDataLocation, lgSize: Int) -> Int {
        let result: Int
        if !isUsed {
            result = 0; isUsed = true; lgSizeUsed = lgSize
        } else if lgSize >= lgSizeUsed {
            holes.addHolesAtEnd(lgSizeUsed, 1, limit: lgSize)
            lgSizeUsed = lgSize + 1
            result = 1
        } else if let hole = holes.tryAllocate(lgSize) {
            result = hole
        } else {
            result = 1 << (lgSizeUsed - lgSize)
            holes.addHolesAtEnd(lgSize, result + 1, limit: lgSizeUsed)
            lgSizeUsed += 1
        }
        return (location.offset << (location.lgSize - lgSize)) + result
    }

    func tryAllocateByExpanding(
        group: GroupLayoutScope, location: UnionDataLocation, lgSize: Int
    ) -> Int? {
        if !isUsed {
            guard location.tryExpand(to: lgSize, union: group.parent) else { return nil }
            isUsed = true; lgSizeUsed = lgSize
            return location.offset << (location.lgSize - lgSize)
        }
        let newSize = max(lgSizeUsed, lgSize) + 1
        guard
            tryExpandUsage(
                group: group, location: location, desiredUsage: newSize, newHoles: true),
            let result = holes.tryAllocate(lgSize)
        else { return nil }
        return (location.offset << (location.lgSize - lgSize)) + result
    }

    func tryExpand(
        group: GroupLayoutScope, location: UnionDataLocation, oldLgSize: Int,
        oldOffset: Int, expansionFactor: Int
    ) -> Bool {
        if oldOffset == 0 && lgSizeUsed == oldLgSize {
            return tryExpandUsage(
                group: group, location: location,
                desiredUsage: oldLgSize + expansionFactor, newHoles: false)
        }
        return holes.tryExpand(
            oldLgSize: oldLgSize, oldOffset: oldOffset, expansionFactor: expansionFactor)
    }

    private func tryExpandUsage(
        group: GroupLayoutScope, location: UnionDataLocation,
        desiredUsage: Int, newHoles: Bool
    ) -> Bool {
        if desiredUsage > location.lgSize,
            !location.tryExpand(to: desiredUsage, union: group.parent)
        {
            return false
        }
        if newHoles { holes.addHolesAtEnd(lgSizeUsed, 1, limit: desiredUsage) }
        lgSizeUsed = desiredUsage
        return true
    }
}

private final class GroupLayoutScope: LayoutScope {
    let parent: UnionLayoutScope
    var usages: [GroupDataLocationUsage] = []
    var pointerUsage = 0
    var hasMembers = false

    init(parent: UnionLayoutScope) { self.parent = parent }

    private func addMember() {
        guard !hasMembers else { return }
        hasMembers = true
        parent.newGroupAddingFirstMember()
    }
    func addVoid() { addMember(); parent.parent.addVoid() }
    func addData(lgSize: Int) -> Int {
        addMember()
        var bestSize = Int.max
        var bestIndex: Int?
        for index in parent.dataLocations.indices {
            if usages.count == index { usages.append(GroupDataLocationUsage()) }
            if let hole = usages[index].smallestHoleAtLeast(
                location: parent.dataLocations[index], lgSize: lgSize), hole < bestSize
            {
                bestSize = hole; bestIndex = index
            }
        }
        if let bestIndex {
            return usages[bestIndex].allocateFromHole(
                location: parent.dataLocations[bestIndex], lgSize: lgSize)
        }
        for index in parent.dataLocations.indices {
            if let result = usages[index].tryAllocateByExpanding(
                group: self, location: parent.dataLocations[index], lgSize: lgSize)
            {
                return result
            }
        }
        let result = parent.addNewDataLocation(lgSize: lgSize)
        usages.append(GroupDataLocationUsage(lgSize: lgSize))
        return result
    }
    func addPointer() -> Int {
        addMember()
        defer { pointerUsage += 1 }
        if pointerUsage < parent.pointerLocations.count {
            return parent.pointerLocations[pointerUsage]
        }
        return parent.addNewPointerLocation()
    }
    func tryExpandData(oldLgSize: Int, oldOffset: Int, expansionFactor: Int) -> Bool {
        guard oldLgSize + expansionFactor <= 6,
            oldOffset & ((1 << expansionFactor) - 1) == 0
        else { return false }
        for index in usages.indices {
            let location = parent.dataLocations[index]
            if location.lgSize >= oldLgSize,
                oldOffset >> (location.lgSize - oldLgSize) == location.offset
            {
                let localOffset = oldOffset - (location.offset << (location.lgSize - oldLgSize))
                return usages[index].tryExpand(
                    group: self, location: location, oldLgSize: oldLgSize,
                    oldOffset: localOffset, expansionFactor: expansionFactor)
            }
        }
        return false
    }
}

private enum RequestWriter {
    static func write(_ request: RequestIR) throws -> [UInt8] {
        let estimatedWords = max(8_192, request.nodes.count * 512)
        let message = try MessageBuilder(
            firstSegmentWords: estimatedWords, allocationStrategy: .fixedSize)
        let root = try message.initRootStruct(dataWords: 0, pointerCount: 4)
        let nodes = try root.initStructListField(
            at: 0, count: request.nodes.count, dataWords: 6, pointerCount: 6)
        for (index, node) in request.nodes.enumerated() {
            try writeNode(node, to: nodes[index], request: request)
        }
        let requested = try root.initStructListField(
            at: 1, count: request.requestedFiles.count, dataWords: 1, pointerCount: 3)
        for (index, file) in request.requestedFiles.enumerated() {
            let builder = try requested[index]
            try builder.setInteger(atByte: 0, to: file.id)
            _ = try builder.setTextField(at: 0, to: file.filename)
            let imports = try builder.initStructListField(
                at: 1, count: file.imports.count, dataWords: 1, pointerCount: 1)
            for (importIndex, imported) in file.imports.enumerated() {
                let value = try imports[importIndex]
                try value.setInteger(atByte: 0, to: imported.fileID)
                _ = try value.setTextField(at: 0, to: imported.path)
            }
        }
        let version = try root.initStructField(at: 2, dataWords: 1, pointerCount: 0)
        try version.setInteger(atByte: 0, to: UInt16(1))
        try version.setInteger(atByte: 2, to: UInt8(0))
        try version.setInteger(atByte: 3, to: UInt8(0))
        _ = try root.initStructListField(at: 3, count: 0, dataWords: 2, pointerCount: 2)
        return try message.framedBytes
    }

    private static func writeNode(_ node: NodeIR, to builder: StructBuilder, request: RequestIR)
        throws
    {
        try builder.setInteger(atByte: 0, to: node.id)
        _ = try builder.setTextField(at: 0, to: node.displayName)
        try builder.setInteger(atByte: 8, to: node.displayNamePrefixLength)
        try builder.setInteger(atByte: 16, to: node.scopeID)
        try builder.setInteger(atByte: 40, to: UInt32(clamping: node.range.startByte))
        try builder.setInteger(atByte: 44, to: UInt32(clamping: node.range.endByte))
        let nested = try builder.initStructListField(
            at: 1, count: node.nested.count, dataWords: 1, pointerCount: 1)
        for (index, item) in node.nested.enumerated() {
            let value = try nested[index]
            try value.setInteger(atByte: 0, to: item.1)
            _ = try value.setTextField(at: 0, to: item.0)
        }
        try writeAnnotations(node.annotations, to: builder, at: 2, request: request)
        let parameters = try builder.initStructListField(
            at: 5, count: node.parameters.count, dataWords: 0, pointerCount: 1)
        for (index, name) in node.parameters.enumerated() {
            _ = try (try parameters[index]).setTextField(at: 0, to: name)
        }
        try builder.setBool(atBit: 288, to: node.isGeneric)
        switch node.payload {
        case .file:
            try builder.setInteger(atByte: 12, to: UInt16(0))
        case .structure(let structure):
            try builder.setInteger(atByte: 12, to: UInt16(1))
            try builder.setInteger(atByte: 14, to: structure.dataWords)
            try builder.setInteger(atByte: 24, to: structure.pointerCount)
            try builder.setInteger(atByte: 26, to: UInt16(7))
            try builder.setBool(atBit: 224, to: structure.isGroup)
            try builder.setInteger(atByte: 30, to: structure.discriminantCount)
            try builder.setInteger(atByte: 32, to: structure.discriminantOffset)
            let fields = try builder.initStructListField(
                at: 3, count: structure.fields.count, dataWords: 3, pointerCount: 4)
            for (index, field) in structure.fields.enumerated() {
                try writeField(field, to: fields[index], request: request)
            }
        case .enumeration(let enumerants):
            try builder.setInteger(atByte: 12, to: UInt16(2))
            let values = try builder.initStructListField(
                at: 3, count: enumerants.count, dataWords: 1, pointerCount: 2)
            for (index, enumerant) in enumerants.enumerated() {
                let value = try values[index]
                try value.setInteger(atByte: 0, to: UInt16(index))
                _ = try value.setTextField(at: 0, to: enumerant.syntax.name)
                try writeAnnotations(
                    enumerant.annotations, to: value, at: 1, request: request)
            }
        case .interface(let methods, let superclasses):
            try builder.setInteger(atByte: 12, to: UInt16(3))
            let values = try builder.initStructListField(
                at: 3, count: methods.count, dataWords: 3, pointerCount: 5)
            for (index, method) in methods.enumerated() {
                let value = try values[index]
                try value.setInteger(atByte: 0, to: method.codeOrder)
                try value.setInteger(atByte: 8, to: method.paramID)
                try value.setInteger(atByte: 16, to: method.resultID)
                _ = try value.setTextField(at: 0, to: method.syntax.name)
                try writeAnnotations(method.annotations, to: value, at: 1, request: request)
                try writeBrand(
                    brand(of: method.paramType),
                    to: value.initStructField(at: 2, dataWords: 0, pointerCount: 1))
                try writeBrand(
                    brand(of: method.resultType),
                    to: value.initStructField(at: 3, dataWords: 0, pointerCount: 1))
                let implicit = try value.initStructListField(
                    at: 4, count: method.syntax.typeParameters.count, dataWords: 0, pointerCount: 1)
                for (parameterIndex, name) in method.syntax.typeParameters.enumerated() {
                    _ = try (try implicit[parameterIndex]).setTextField(at: 0, to: name)
                }
            }
            let supers = try builder.initStructListField(
                at: 4, count: superclasses.count, dataWords: 1, pointerCount: 1)
            for (index, type) in superclasses.enumerated() {
                let superclass = try supers[index]
                try superclass.setInteger(atByte: 0, to: nodeID(type))
                try writeBrand(
                    brand(of: type),
                    to: superclass.initStructField(at: 0, dataWords: 0, pointerCount: 1))
            }
        case .constant(let type, let value):
            try builder.setInteger(atByte: 12, to: UInt16(4))
            try writeType(type, to: builder.initStructField(at: 3, dataWords: 3, pointerCount: 1))
            try writeValue(
                value, type: type,
                to: builder.initStructField(at: 4, dataWords: 2, pointerCount: 1), request: request)
        case .annotation(let type, let targets):
            try builder.setInteger(atByte: 12, to: UInt16(5))
            try writeType(type, to: builder.initStructField(at: 3, dataWords: 3, pointerCount: 1))
            let targetBits = [
                "file", "const", "enum", "enumerant", "struct", "field", "union", "group",
                "interface", "method", "param", "annotation",
            ]
            for (index, target) in targetBits.enumerated() {
                try builder.setBool(atBit: 112 + index, to: targets.contains(target))
            }
        }
    }

    private static func writeField(_ field: FieldIR, to builder: StructBuilder, request: RequestIR)
        throws
    {
        _ = try builder.setTextField(at: 0, to: field.name)
        try builder.setInteger(atByte: 0, to: field.codeOrder)
        try builder.setInteger(atByte: 2, to: field.discriminant ?? UInt16.max, default: UInt16.max)
        try writeAnnotations(field.annotations, to: builder, at: 1, request: request)
        if let ordinal = field.ordinal {
            try builder.setInteger(atByte: 10, to: UInt16(1))
            try builder.setInteger(atByte: 12, to: ordinal)
        }
        switch field.payload {
        case .group(let id):
            try builder.setInteger(atByte: 8, to: UInt16(1))
            try builder.setInteger(atByte: 16, to: id)
        case .slot(let offset, let type, let defaultValue, let explicit):
            try builder.setInteger(atByte: 8, to: UInt16(0))
            try builder.setInteger(atByte: 4, to: offset)
            try writeType(type, to: builder.initStructField(at: 2, dataWords: 3, pointerCount: 1))
            try writeValue(
                defaultValue ?? zeroValue(for: type), type: type,
                to: builder.initStructField(at: 3, dataWords: 2, pointerCount: 1), request: request)
            try builder.setBool(atBit: 128, to: explicit)
        }
    }

    private static func writeType(_ type: TypeIR, to builder: StructBuilder) throws {
        switch type {
        case .primitive(let tag):
            if tag <= 18 {
                try builder.setInteger(atByte: 0, to: tag)
            } else {
                try builder.setInteger(atByte: 0, to: UInt16(18))
                try builder.setInteger(atByte: 8, to: UInt16(0))
                try builder.setInteger(
                    atByte: 10, to: tag == 25 ? UInt16(1) : tag == 26 ? UInt16(2) : UInt16(3))
            }
        case .list(let element):
            try builder.setInteger(atByte: 0, to: UInt16(14))
            try writeType(
                element, to: builder.initStructField(at: 0, dataWords: 3, pointerCount: 1))
        case .node(let id, let kind, _, let brand):
            let tag: UInt16 = kind == .enumeration ? 15 : kind == .structure ? 16 : 17
            try builder.setInteger(atByte: 0, to: tag)
            try builder.setInteger(atByte: 8, to: id)
            try writeBrand(
                brand, to: builder.initStructField(at: 0, dataWords: 0, pointerCount: 1))
        case .parameter(let scopeID, let index):
            try builder.setInteger(atByte: 0, to: UInt16(18))
            try builder.setInteger(atByte: 8, to: UInt16(1))
            try builder.setInteger(atByte: 10, to: index)
            try builder.setInteger(atByte: 16, to: scopeID)
        case .implicitParameter(let index):
            try builder.setInteger(atByte: 0, to: UInt16(18))
            try builder.setInteger(atByte: 8, to: UInt16(2))
            try builder.setInteger(atByte: 10, to: index)
        }
    }

    private static func writeAnnotations(
        _ annotations: [AnnotationIR], to builder: StructBuilder, at pointerIndex: Int,
        request: RequestIR
    ) throws {
        let values = try builder.initStructListField(
            at: pointerIndex, count: annotations.count, dataWords: 1, pointerCount: 2)
        for (index, annotation) in annotations.enumerated() {
            let value = try values[index]
            try value.setInteger(atByte: 0, to: annotation.id)
            try writeValue(
                annotation.value, type: annotation.type,
                to: value.initStructField(at: 0, dataWords: 2, pointerCount: 1),
                request: request)
            try writeBrand(
                annotation.brand,
                to: value.initStructField(at: 1, dataWords: 0, pointerCount: 1))
        }
    }

    private static func brand(of type: TypeIR) -> [BrandScopeIR] {
        guard case .node(_, _, _, let scopes) = type else { return [] }
        return scopes
    }

    private static func writeBrand(_ brand: [BrandScopeIR], to builder: StructBuilder) throws {
        let scopes = try builder.initStructListField(
            at: 0, count: brand.count, dataWords: 2, pointerCount: 1)
        for (index, scope) in brand.enumerated() {
            let value = try scopes[index]
            try value.setInteger(atByte: 0, to: scope.scopeID)
            if let bindings = scope.bindings {
                try value.setInteger(atByte: 8, to: UInt16(0))
                let list = try value.initStructListField(
                    at: 0, count: bindings.count, dataWords: 1, pointerCount: 2)
                for (bindingIndex, type) in bindings.enumerated() {
                    let binding = try list[bindingIndex]
                    try binding.setInteger(atByte: 0, to: UInt16(1))
                    try writeType(
                        type,
                        to: binding.initStructField(at: 0, dataWords: 3, pointerCount: 1))
                }
            } else {
                try value.setInteger(atByte: 8, to: UInt16(1))
            }
        }
    }

    private static func writeValue(
        _ value: ValueSyntax, type: TypeIR, to builder: StructBuilder, request: RequestIR
    ) throws {
        if case .identifier(let name) = value,
            let constant = lookupConstant(name, request: request)
        {
            try writeValue(constant.value, type: type, to: builder, request: request)
            return
        }
        let tag = valueTag(type)
        try builder.setInteger(atByte: 0, to: tag)
        switch (tag, value) {
        case (1, .identifier(let name)):
            try builder.setBool(atBit: 16, to: name.components.last == "true")
        case (2, .integer(let number)):
            try builder.setInteger(atByte: 2, to: Int8(truncatingIfNeeded: number))
        case (2, .negativeInteger(let number)):
            try builder.setInteger(atByte: 2, to: -Int8(clamping: number))
        case (3, .integer(let number)):
            try builder.setInteger(atByte: 2, to: Int16(truncatingIfNeeded: number))
        case (3, .negativeInteger(let number)):
            try builder.setInteger(atByte: 2, to: -Int16(clamping: number))
        case (4, .integer(let number)):
            try builder.setInteger(atByte: 4, to: Int32(truncatingIfNeeded: number))
        case (4, .negativeInteger(let number)):
            try builder.setInteger(atByte: 4, to: -Int32(clamping: number))
        case (5, .integer(let number)):
            try builder.setInteger(atByte: 8, to: Int64(truncatingIfNeeded: number))
        case (5, .negativeInteger(let number)):
            try builder.setInteger(atByte: 8, to: -Int64(clamping: number))
        case (6, .integer(let number)):
            try builder.setInteger(atByte: 2, to: UInt8(truncatingIfNeeded: number))
        case (7, .integer(let number)):
            try builder.setInteger(atByte: 2, to: UInt16(truncatingIfNeeded: number))
        case (8, .integer(let number)):
            try builder.setInteger(atByte: 4, to: UInt32(truncatingIfNeeded: number))
        case (9, .integer(let number)): try builder.setInteger(atByte: 8, to: number)
        case (10, .float(let number)): try builder.setFloat32(atByte: 4, to: Float(number))
        case (10, .integer(let number)): try builder.setFloat32(atByte: 4, to: Float(number))
        case (11, .float(let number)): try builder.setFloat64(atByte: 8, to: number)
        case (11, .integer(let number)): try builder.setFloat64(atByte: 8, to: Double(number))
        case (12, .string(let text)): _ = try builder.setTextField(at: 0, to: text)
        case (13, .data(let bytes)): _ = try builder.setDataField(at: 0, to: bytes)
        case (15, .integer(let number)):
            try builder.setInteger(atByte: 2, to: UInt16(truncatingIfNeeded: number))
        case (15, .identifier(let name)):
            if case .node(let id, _, _, _) = type,
                let node = request.nodes.first(where: { $0.id == id }),
                case .enumeration(let values) = node.payload,
                let index = values.firstIndex(where: { $0.syntax.name == name.components.last })
            {
                try builder.setInteger(atByte: 2, to: UInt16(index))
            }
        case (12...14, _), (16, _), (18, _):
            try writePointerValue(
                value, type: type, to: builder.anyPointerField(at: 0), request: request)
        default: break
        }
    }

    private static func writePointerValue(
        _ value: ValueSyntax, type: TypeIR, to pointer: AnyPointerBuilder, request: RequestIR,
        bindings: [UInt64: [TypeIR]] = [:]
    ) throws {
        if case .void = value { return }
        if case .identifier(let name) = value,
            let constant = lookupConstant(name, request: request)
        {
            try writePointerValue(
                constant.value, type: constant.type, to: pointer, request: request,
                bindings: bindings)
            return
        }
        if case .embed(let path) = value {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            switch type {
            case .primitive(12): try pointer.setText(String(decoding: bytes, as: UTF8.self))
            case .primitive(13): try pointer.setData(bytes)
            case .node(_, .structure, _, _):
                let frame = try MessageFraming.decodePrefix(bytes)
                try pointer.setStruct(try frame.reader().rootStruct())
            default: break
            }
            return
        }
        switch type {
        case .primitive(12):
            if case .string(let text) = value { try pointer.setText(text) }
        case .primitive(13):
            switch value {
            case .data(let bytes): try pointer.setData(bytes)
            case .string(let text): try pointer.setData(Array(text.utf8))
            default: break
            }
        case .list(let element):
            guard case .list(let values) = value else { return }
            if case .node(let id, .structure, _, _) = element,
                let structure = lookupStructure(id: id, request: request)
            {
                let list = try pointer.initStructList(
                    count: values.count, dataWords: Int(structure.dataWords),
                    pointerCount: Int(structure.pointerCount))
                for (index, item) in values.enumerated() {
                    try populateStruct(
                        item, structure: structure, to: list[index], request: request,
                        bindings: merging(
                            bindings, with: typeBindings(for: element, request: request)))
                }
            } else {
                let list = try pointer.initList(
                    elementSize: listElementSize(element), count: values.count)
                for (index, item) in values.enumerated() {
                    try writeListElement(
                        item, type: element, to: list, index: index, request: request,
                        bindings: bindings)
                }
            }
        case .node(let id, .structure, _, _):
            guard let structure = lookupStructure(id: id, request: request) else { return }
            let target = try pointer.initStruct(
                dataWords: Int(structure.dataWords), pointerCount: Int(structure.pointerCount))
            try populateStruct(
                value, structure: structure, to: target, request: request,
                bindings: merging(
                    bindings, with: typeBindings(for: type, request: request)))
        default: break
        }
    }

    private static func populateStruct(
        _ value: ValueSyntax, structure: StructIR, to builder: StructBuilder, request: RequestIR,
        bindings: [UInt64: [TypeIR]] = [:]
    ) throws {
        let assignments: [(String, ValueSyntax)]
        switch value {
        case .tuple(let values): assignments = values
        default:
            guard let first = structure.fields.first else { return }
            assignments = [(first.name, value)]
        }
        for (name, item) in assignments {
            guard let field = structure.fields.first(where: { $0.name == name }) else { continue }
            if let discriminant = field.discriminant {
                try builder.setInteger(
                    atByte: Int(structure.discriminantOffset) * 2, to: discriminant)
            }
            switch field.payload {
            case .group(let id):
                if let group = lookupStructure(id: id, request: request) {
                    try populateStruct(
                        item, structure: group, to: builder, request: request, bindings: bindings)
                }
            case .slot(let offset, let type, let defaultValue, _):
                try writeSlot(
                    item, type: substitute(type, using: bindings), offset: offset,
                    to: builder, defaultValue: defaultValue, request: request,
                    bindings: bindings)
            }
        }
    }

    private static func writeSlot(
        _ value: ValueSyntax, type: TypeIR, offset: UInt32, to builder: StructBuilder,
        defaultValue: ValueSyntax?, request: RequestIR, bindings: [UInt64: [TypeIR]] = [:]
    ) throws {
        let byte = Int(offset)
        switch type {
        case .primitive(0): break
        case .primitive(1):
            try builder.setBool(
                atBit: Int(offset), to: bool(value), default: defaultValue.map(bool) ?? false)
        case .primitive(2):
            try builder.setInteger(
                atByte: byte, to: Int8(truncatingIfNeeded: signed(value)),
                default: Int8(truncatingIfNeeded: defaultValue.map(signed) ?? 0))
        case .primitive(3):
            try builder.setInteger(
                atByte: byte * 2, to: Int16(truncatingIfNeeded: signed(value)),
                default: Int16(truncatingIfNeeded: defaultValue.map(signed) ?? 0))
        case .primitive(4):
            try builder.setInteger(
                atByte: byte * 4, to: Int32(truncatingIfNeeded: signed(value)),
                default: Int32(truncatingIfNeeded: defaultValue.map(signed) ?? 0))
        case .primitive(5):
            try builder.setInteger(
                atByte: byte * 8, to: signed(value), default: defaultValue.map(signed) ?? 0)
        case .primitive(6):
            try builder.setInteger(
                atByte: byte, to: UInt8(truncatingIfNeeded: unsigned(value)),
                default: UInt8(truncatingIfNeeded: defaultValue.map(unsigned) ?? 0))
        case .primitive(7):
            try builder.setInteger(
                atByte: byte * 2, to: UInt16(truncatingIfNeeded: unsigned(value)),
                default: UInt16(truncatingIfNeeded: defaultValue.map(unsigned) ?? 0))
        case .primitive(8):
            try builder.setInteger(
                atByte: byte * 4, to: UInt32(truncatingIfNeeded: unsigned(value)),
                default: UInt32(truncatingIfNeeded: defaultValue.map(unsigned) ?? 0))
        case .primitive(9):
            try builder.setInteger(
                atByte: byte * 8, to: unsigned(value), default: defaultValue.map(unsigned) ?? 0)
        case .primitive(10):
            try builder.setFloat32(
                atByte: byte * 4, to: Float(floating(value)),
                default: Float(defaultValue.map(floating) ?? 0))
        case .primitive(11):
            try builder.setFloat64(
                atByte: byte * 8, to: floating(value),
                default: defaultValue.map(floating) ?? 0)
        case .node(let id, .enumeration, _, _):
            try builder.setInteger(
                atByte: byte * 2, to: enumValue(value, id: id, request: request),
                default: defaultValue.map { enumValue($0, id: id, request: request) } ?? 0)
        case .primitive(12), .primitive(13), .primitive(18), .list,
            .node(_, .structure, _, _), .parameter, .implicitParameter:
            try writePointerValue(
                value, type: type, to: builder.anyPointerField(at: byte), request: request,
                bindings: bindings)
        default: break
        }
    }

    private static func writeListElement(
        _ value: ValueSyntax, type: TypeIR, to list: ListBuilder, index: Int, request: RequestIR,
        bindings: [UInt64: [TypeIR]] = [:]
    ) throws {
        switch type {
        case .primitive(0): break
        case .primitive(1): try list.setBool(at: index, to: bool(value))
        case .primitive(2):
            try list.setInteger(at: index, to: Int8(truncatingIfNeeded: signed(value)))
        case .primitive(3):
            try list.setInteger(at: index, to: Int16(truncatingIfNeeded: signed(value)))
        case .primitive(4):
            try list.setInteger(at: index, to: Int32(truncatingIfNeeded: signed(value)))
        case .primitive(5): try list.setInteger(at: index, to: signed(value))
        case .primitive(6):
            try list.setInteger(at: index, to: UInt8(truncatingIfNeeded: unsigned(value)))
        case .primitive(7):
            try list.setInteger(at: index, to: UInt16(truncatingIfNeeded: unsigned(value)))
        case .primitive(8):
            try list.setInteger(at: index, to: UInt32(truncatingIfNeeded: unsigned(value)))
        case .primitive(9): try list.setInteger(at: index, to: unsigned(value))
        case .primitive(10): try list.setFloat32(at: index, to: Float(floating(value)))
        case .primitive(11): try list.setFloat64(at: index, to: floating(value))
        case .primitive(12):
            if case .string(let text) = value { try list.setText(at: index, to: text) }
        case .primitive(13):
            if case .data(let bytes) = value {
                try list.setData(at: index, to: bytes)
            } else if case .string(let text) = value {
                try list.setData(at: index, to: Array(text.utf8))
            }
        case .node(let id, .enumeration, _, _):
            try list.setInteger(at: index, to: enumValue(value, id: id, request: request))
        case .list, .node(_, .structure, _, _):
            try writePointerValue(
                value, type: type, to: list.anyPointer(at: index), request: request,
                bindings: bindings)
        default: break
        }
    }

    private static func lookupStructure(id: UInt64, request: RequestIR) -> StructIR? {
        guard let node = request.nodes.first(where: { $0.id == id }),
            case .structure(let structure) = node.payload
        else { return nil }
        return structure
    }

    private static func lookupConstant(
        _ name: NameSyntax, request: RequestIR
    ) -> (type: TypeIR, value: ValueSyntax)? {
        guard name.components.count > 1 else { return nil }
        let suffix = name.components.joined(separator: ".")
        guard
            let node = request.lookupNodes.first(where: {
                $0.displayName.hasSuffix(":" + suffix) || $0.displayName.hasSuffix("." + suffix)
            }), case .constant(let type, let value) = node.payload
        else { return nil }
        return (type, value)
    }

    private static func typeBindings(
        for type: TypeIR, request: RequestIR
    ) -> [UInt64: [TypeIR]] {
        guard case .node(let id, _, let arguments, _) = type, !arguments.isEmpty else { return [:] }
        var scopeIDs: [UInt64] = []
        if let structure = lookupStructure(id: id, request: request) {
            for field in structure.fields {
                guard case .slot(_, let fieldType, _, _) = field.payload else { continue }
                collectParameterScopes(fieldType, into: &scopeIDs)
            }
        }
        if scopeIDs.isEmpty { scopeIDs = [id] }
        var result: [UInt64: [TypeIR]] = [:]
        var argumentIndex = 0
        for scopeID in scopeIDs {
            let indices = structureParameterIndices(
                scopeID: scopeID, structureID: id, request: request)
            let count = (indices.max().map(Int.init) ?? -1) + 1
            guard count > 0, argumentIndex + count <= arguments.count else { continue }
            result[scopeID] = Array(arguments[argumentIndex..<(argumentIndex + count)])
            argumentIndex += count
        }
        if result.isEmpty { result[id] = arguments }
        return result
    }

    private static func merging(
        _ outer: [UInt64: [TypeIR]], with inner: [UInt64: [TypeIR]]
    ) -> [UInt64: [TypeIR]] {
        outer.merging(inner) { _, new in new }
    }

    private static func collectParameterScopes(_ type: TypeIR, into result: inout [UInt64]) {
        switch type {
        case .parameter(let scopeID, _):
            if !result.contains(scopeID) { result.append(scopeID) }
        case .list(let element): collectParameterScopes(element, into: &result)
        case .node(_, _, let arguments, _):
            for argument in arguments { collectParameterScopes(argument, into: &result) }
        default: break
        }
    }

    private static func structureParameterIndices(
        scopeID: UInt64, structureID: UInt64, request: RequestIR
    ) -> [UInt16] {
        guard let structure = lookupStructure(id: structureID, request: request) else { return [] }
        var result: [UInt16] = []
        func collect(_ type: TypeIR) {
            switch type {
            case .parameter(let candidate, let index) where candidate == scopeID:
                result.append(index)
            case .list(let element): collect(element)
            case .node(_, _, let arguments, _): arguments.forEach(collect)
            default: break
            }
        }
        for field in structure.fields {
            if case .slot(_, let type, _, _) = field.payload { collect(type) }
        }
        return result
    }

    private static func substitute(
        _ type: TypeIR, using bindings: [UInt64: [TypeIR]]
    ) -> TypeIR {
        switch type {
        case .parameter(let scopeID, let index):
            guard let values = bindings[scopeID], Int(index) < values.count else { return type }
            return values[Int(index)]
        case .list(let element): return .list(substitute(element, using: bindings))
        case .node(let id, let kind, let arguments, let brand):
            return .node(
                id: id, kind: kind,
                arguments: arguments.map { substitute($0, using: bindings) },
                brand: brand.map {
                    BrandScopeIR(
                        scopeID: $0.scopeID,
                        bindings: $0.bindings?.map { substitute($0, using: bindings) })
                })
        default: return type
        }
    }

    private static func enumValue(_ value: ValueSyntax, id: UInt64, request: RequestIR) -> UInt16 {
        if case .integer(let number) = value { return UInt16(truncatingIfNeeded: number) }
        guard case .identifier(let name) = value,
            let node = request.nodes.first(where: { $0.id == id }),
            case .enumeration(let values) = node.payload,
            let index = values.firstIndex(where: { $0.syntax.name == name.components.last })
        else { return 0 }
        return UInt16(index)
    }

    private static func listElementSize(_ type: TypeIR) -> ListElementSize {
        switch storage(type) {
        case .void: return .void
        case .pointer: return .pointer
        case .data(1): return .bit
        case .data(8): return .byte
        case .data(16): return .twoBytes
        case .data(32): return .fourBytes
        default: return .eightBytes
        }
    }

    private static func bool(_ value: ValueSyntax) -> Bool {
        if case .identifier(let name) = value { return name.components.last == "true" }
        return false
    }

    private static func unsigned(_ value: ValueSyntax) -> UInt64 {
        if case .integer(let number) = value { return number }
        return 0
    }

    private static func signed(_ value: ValueSyntax) -> Int64 {
        switch value {
        case .integer(let number): return Int64(bitPattern: number)
        case .negativeInteger(let number): return -Int64(clamping: number)
        default: return 0
        }
    }

    private static func floating(_ value: ValueSyntax) -> Double {
        switch value {
        case .float(let number): return number
        case .integer(let number): return Double(number)
        case .negativeInteger(let number): return -Double(number)
        case .identifier(let name):
            switch name.components.last {
            case "inf": return .infinity
            case "nan": return .nan
            default: return 0
            }
        default: return 0
        }
    }

    private static func valueTag(_ type: TypeIR) -> UInt16 {
        switch type {
        case .primitive(let tag): return min(tag, 18)
        case .list: return 14
        case .node(_, let kind, _, _):
            return kind == .enumeration ? 15 : kind == .structure ? 16 : 17
        case .parameter, .implicitParameter: return 18
        }
    }

    fileprivate static func zeroValue(for type: TypeIR) -> ValueSyntax {
        switch valueTag(type) {
        case 1:
            return .identifier(
                NameSyntax(
                    root: .relative, components: ["false"],
                    range: SourceRange(startByte: 0, endByte: 0)))
        case 10, 11: return .float(0)
        case 12: return .string("")
        case 13: return .data([])
        case 14, 16...18: return .void
        default: return .integer(0)
        }
    }

    private static func nodeID(_ type: TypeIR) throws -> UInt64 {
        guard case .node(let id, _, _, _) = type else {
            throw NativeCompilerError.unsupported("expected node type")
        }
        return id
    }
}
