import Foundation

public struct CompilerConfiguration: Equatable, Sendable {
    public var importPaths: [URL]
    public var requireFileID: Bool
    public var sourcePrefix: URL?
    public var maximumSourceBytes: Int
    public var maximumFiles: Int

    public init(
        importPaths: [URL] = [], requireFileID: Bool = true, sourcePrefix: URL? = nil,
        maximumSourceBytes: Int = 16 * 1024 * 1024, maximumFiles: Int = 1_024
    ) {
        self.importPaths = importPaths
        self.requireFileID = requireFileID
        self.sourcePrefix = sourcePrefix
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumFiles = maximumFiles
    }
}

public struct ResolvedSchema: Sendable {
    public let files: [ResolvedFile]
    public let nodes: [ResolvedNode]
    public let diagnostics: [SourceDiagnostic]
}

public struct ResolvedFile: Sendable {
    public let sourceName: String
    public let url: URL
    public let id: UInt64
    public let syntax: SchemaFileSyntax
    public let imports: [ResolvedImport]
}

public struct ResolvedImport: Equatable, Sendable {
    public let path: String
    public let fileID: UInt64
}

public struct ResolvedNode: Sendable {
    public enum Kind: String, Sendable {
        case structure, enumeration, interface, constant, annotation
    }
    public let id: UInt64
    public let scopeID: UInt64
    public let name: String
    public let qualifiedName: String
    public let sourceName: String
    public let kind: Kind
    public let range: SourceRange
}

public final class NativeSchemaCompiler: @unchecked Sendable {
    public let configuration: CompilerConfiguration
    private let fileManager: FileManager

    public init(
        configuration: CompilerConfiguration = CompilerConfiguration(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public func resolve(files entryFiles: [URL]) -> ResolvedSchema {
        var loader = Loader(configuration: configuration, fileManager: fileManager)
        for url in entryFiles {
            let standardized = url.standardizedFileURL
            let displayName: String
            if let prefix = configuration.sourcePrefix?.standardizedFileURL,
                standardized.path.hasPrefix(prefix.path + "/")
            {
                displayName = String(standardized.path.dropFirst(prefix.path.count + 1))
            } else {
                displayName = url.lastPathComponent
            }
            loader.load(standardized, displayName: displayName)
        }
        loader.buildNodes()
        loader.validateReferences()
        return ResolvedSchema(
            files: loader.files.values.sorted { $0.sourceName < $1.sourceName },
            nodes: loader.nodes.sorted { $0.id < $1.id }, diagnostics: loader.diagnostics)
    }
}

private struct Loader {
    let configuration: CompilerConfiguration
    let fileManager: FileManager
    var files: [URL: ResolvedFile] = [:]
    var diagnostics: [SourceDiagnostic] = []
    var nodes: [ResolvedNode] = []
    var symbols: [SymbolKey: ResolvedNode] = [:]
    var aliases: [ScopeKey: [String: TypeSyntax]] = [:]
    var scopeParameters: [ScopeKey: Set<String>] = [:]
    var annotationTargets: [UInt64: Set<String>] = [:]

    mutating func load(_ url: URL, displayName: String) {
        let url = url.standardizedFileURL
        if let existing = files[url] {
            if displayName.count < existing.sourceName.count {
                files[url] = ResolvedFile(
                    sourceName: displayName, url: existing.url, id: existing.id,
                    syntax: existing.syntax, imports: existing.imports)
            }
            return
        }
        guard configuration.maximumFiles > 0, files.count < configuration.maximumFiles else {
            diagnose(
                displayName, SourceRange(startByte: 0, endByte: 0),
                "schema file limit exceeded")
            return
        }
        guard configuration.maximumSourceBytes >= 0 else {
            diagnose(
                displayName, SourceRange(startByte: 0, endByte: 0),
                "schema source byte limit exceeded")
            return
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber,
            size.uint64Value > UInt64(configuration.maximumSourceBytes)
        {
            diagnose(
                displayName, SourceRange(startByte: 0, endByte: 0),
                "schema source byte limit exceeded")
            return
        }
        let bytes: [UInt8]
        do { bytes = Array(try Data(contentsOf: url)) } catch {
            diagnose(
                displayName, SourceRange(startByte: 0, endByte: 0), "cannot read schema: \(error)")
            return
        }
        guard bytes.count <= configuration.maximumSourceBytes else {
            diagnose(
                displayName, SourceRange(startByte: 0, endByte: 0),
                "schema source byte limit exceeded")
            return
        }
        let parsed = CapnProtoParser().parse(SourceFile(name: displayName, bytes: bytes))
        diagnostics.append(contentsOf: parsed.diagnostics)
        let id: UInt64
        if let declared = parsed.file.id {
            id = declared
            if declared & (UInt64(1) << 63) == 0 {
                diagnose(displayName, parsed.file.range, "file ID must have its high bit set")
            }
        } else if configuration.requireFileID {
            diagnose(displayName, parsed.file.range, "file does not declare an ID")
            id = TypeID.child(parent: 0, name: displayName)
        } else {
            id = TypeID.child(parent: 0, name: displayName)
        }
        // Insert before following imports so mutually-importing files terminate.
        files[url] = ResolvedFile(
            sourceName: displayName, url: url, id: id, syntax: parsed.file, imports: [])

        var imports: [ResolvedImport] = []
        for path in importedPaths(in: parsed.file.declarations).sorted() {
            guard let importedURL = resolveImport(path, from: url) else {
                diagnose(displayName, parsed.file.range, "import not found: \(path)")
                continue
            }
            let importedName = displayNameForImport(
                path, resolvedURL: importedURL, from: displayName)
            load(importedURL, displayName: importedName)
            if let imported = files[importedURL.standardizedFileURL] {
                imports.append(ResolvedImport(path: path, fileID: imported.id))
            }
        }
        files[url] = ResolvedFile(
            sourceName: displayName, url: url, id: id, syntax: parsed.file,
            imports: imports.sorted { $0.path < $1.path })
    }

    mutating func buildNodes() {
        for file in files.values.sorted(by: { $0.sourceName < $1.sourceName }) {
            collectDeclarations(file.syntax.declarations, file: file, scopeID: file.id, path: [])
        }
        var ids: [UInt64: ResolvedNode] = [:]
        for node in nodes {
            if let previous = ids[node.id] {
                diagnose(
                    node.sourceName, node.range,
                    "duplicate node ID 0x\(String(node.id, radix: 16)); first used by \(previous.qualifiedName)"
                )
            } else {
                ids[node.id] = node
            }
        }
    }

    mutating func collectDeclarations(
        _ declarations: [DeclarationSyntax], file: ResolvedFile, scopeID: UInt64, path: [String]
    ) {
        for declaration in declarations {
            switch declaration {
            case .application: break
            case .using(let value):
                let alias = value.name ?? typeName(value.target)?.components.last
                if let alias {
                    aliases[ScopeKey(fileID: file.id, path: path), default: [:]][alias] =
                        value.target
                }
            case .structure(let value):
                let id = value.id ?? TypeID.child(parent: scopeID, name: value.name)
                addNode(id, scopeID, value.name, path, file, .structure, value.range)
                scopeParameters[ScopeKey(fileID: file.id, path: path + [value.name])] = Set(
                    value.parameters)
                var nested: [DeclarationSyntax] = []
                collectNested(value.members, into: &nested)
                collectDeclarations(nested, file: file, scopeID: id, path: path + [value.name])
            case .enumeration(let value):
                let id = value.id ?? TypeID.child(parent: scopeID, name: value.name)
                addNode(id, scopeID, value.name, path, file, .enumeration, value.range)
            case .interface(let value):
                let id = value.id ?? TypeID.child(parent: scopeID, name: value.name)
                addNode(id, scopeID, value.name, path, file, .interface, value.range)
                scopeParameters[ScopeKey(fileID: file.id, path: path + [value.name])] = Set(
                    value.parameters)
                let nested = value.members.compactMap { member -> DeclarationSyntax? in
                    if case .declaration(let declaration) = member { return declaration }
                    return nil
                }
                collectDeclarations(nested, file: file, scopeID: id, path: path + [value.name])
            case .constant(let value):
                addNode(
                    TypeID.child(parent: scopeID, name: value.name), scopeID, value.name, path,
                    file, .constant, value.range)
            case .annotation(let value):
                let id = value.id ?? TypeID.child(parent: scopeID, name: value.name)
                addNode(
                    id, scopeID,
                    value.name, path, file, .annotation, value.range)
                annotationTargets[id] = Set(value.targets)
            }
        }
    }

    mutating func addNode(
        _ id: UInt64, _ scopeID: UInt64, _ name: String, _ path: [String], _ file: ResolvedFile,
        _ kind: ResolvedNode.Kind, _ range: SourceRange
    ) {
        let node = ResolvedNode(
            id: id, scopeID: scopeID, name: name,
            qualifiedName: (path + [name]).joined(separator: "."), sourceName: file.sourceName,
            kind: kind, range: range)
        nodes.append(node)
        let key = SymbolKey(fileID: file.id, path: path + [name])
        if symbols[key] != nil {
            diagnose(file.sourceName, range, "duplicate declaration '\(name)'")
        } else {
            symbols[key] = node
        }
    }

    mutating func validateReferences() {
        for file in files.values {
            validateDeclarations(file.syntax.declarations, file: file, scope: [], parameters: [])
        }
    }

    mutating func validateDeclarations(
        _ declarations: [DeclarationSyntax], file: ResolvedFile, scope: [String],
        parameters: Set<String>
    ) {
        for declaration in declarations {
            switch declaration {
            case .application(let annotation):
                validateAnnotation(annotation, target: "file", file: file, scope: scope)
            case .using: break
            case .structure(let value):
                let childScope = scope + [value.name]
                let params = parameters.union(value.parameters)
                validateAnnotations(value.annotations, target: "struct", file: file, scope: scope)
                validateMembers(value.members, file: file, scope: childScope, parameters: params)
            case .enumeration(let value):
                validateAnnotations(value.annotations, target: "enum", file: file, scope: scope)
                for enumerant in value.enumerants {
                    validateAnnotations(
                        enumerant.annotations, target: "enumerant", file: file,
                        scope: scope + [value.name])
                }
            case .interface(let value):
                let childScope = scope + [value.name]
                let params = parameters.union(value.parameters)
                validateAnnotations(
                    value.annotations, target: "interface", file: file, scope: scope)
                for type in value.superclasses {
                    validate(type, file: file, scope: childScope, parameters: params)
                }
                for member in value.members {
                    switch member {
                    case .declaration(let nested):
                        validateDeclarations(
                            [nested], file: file, scope: childScope, parameters: params)
                    case .method(let method):
                        validateAnnotations(
                            method.annotations, target: "method", file: file, scope: childScope)
                        let methodParams = params.union(method.typeParameters)
                        method.parameters.forEach { parameter in
                            validate(
                                parameter.type, file: file, scope: childScope,
                                parameters: methodParams)
                            validateAnnotations(
                                parameter.annotations, target: "param", file: file,
                                scope: childScope)
                        }
                        switch method.results {
                        case .parameters(let values):
                            values.forEach { parameter in
                                validate(
                                    parameter.type, file: file, scope: childScope,
                                    parameters: methodParams
                                )
                                validateAnnotations(
                                    parameter.annotations, target: "param", file: file,
                                    scope: childScope)
                            }
                        case .named(let type):
                            validate(type, file: file, scope: childScope, parameters: methodParams)
                        case .stream: break
                        }
                    }
                }
            case .constant(let value):
                validateAnnotations(value.annotations, target: "const", file: file, scope: scope)
                validate(value.type, file: file, scope: scope, parameters: parameters)
            case .annotation(let value):
                validateAnnotations(
                    value.annotations, target: "annotation", file: file, scope: scope)
                validate(value.type, file: file, scope: scope, parameters: parameters)
            }
        }
    }

    mutating func validateMembers(
        _ members: [StructMemberSyntax], file: ResolvedFile, scope: [String],
        parameters: Set<String>
    ) {
        var ordinals = Set<UInt16>()
        func checkOrdinal(_ ordinal: UInt16, _ range: SourceRange) {
            if !ordinals.insert(ordinal).inserted {
                diagnose(file.sourceName, range, "duplicate ordinal @\(ordinal)")
            }
        }
        for member in members {
            switch member {
            case .field(let field):
                checkOrdinal(field.ordinal, field.range);
                validateAnnotations(field.annotations, target: "field", file: file, scope: scope)
                validate(field.type, file: file, scope: scope, parameters: parameters)
            case .group(let group):
                validateAnnotations(group.annotations, target: "group", file: file, scope: scope)
                validateMembers(group.members, file: file, scope: scope, parameters: parameters)
            case .union(let children, let annotations, _):
                validateAnnotations(annotations, target: "union", file: file, scope: scope)
                validateMembers(children, file: file, scope: scope, parameters: parameters)
            case .namedUnion(let group, _):
                validateAnnotations(group.annotations, target: "union", file: file, scope: scope)
                validateMembers(group.members, file: file, scope: scope, parameters: parameters)
            case .declaration(let declaration):
                validateDeclarations(
                    [declaration], file: file, scope: scope, parameters: parameters)
            }
        }
    }

    mutating func validateAnnotations(
        _ annotations: [AnnotationUseSyntax], target: String, file: ResolvedFile, scope: [String]
    ) {
        for annotation in annotations {
            validateAnnotation(annotation, target: target, file: file, scope: scope)
        }
    }

    mutating func validateAnnotation(
        _ annotation: AnnotationUseSyntax, target: String, file: ResolvedFile, scope: [String]
    ) {
        guard let node = resolve(annotation.name, file: file, scope: scope, seenAliases: []) else {
            diagnose(
                file.sourceName, annotation.range,
                "unknown annotation '\(render(annotation.name))'")
            return
        }
        guard node.kind == .annotation else {
            diagnose(
                file.sourceName, annotation.range,
                "'\(render(annotation.name))' is not an annotation")
            return
        }
        if annotationTargets[node.id]?.contains(target) != true {
            diagnose(
                file.sourceName, annotation.range,
                "annotation '\(render(annotation.name))' cannot be applied to \(target)")
        }
    }

    mutating func validate(
        _ type: TypeSyntax, file: ResolvedFile, scope: [String], parameters: Set<String>
    ) {
        switch type {
        case .list(let element): validate(element, file: file, scope: scope, parameters: parameters)
        case .named(let name, let arguments):
            arguments.forEach { validate($0, file: file, scope: scope, parameters: parameters) }
            if name.root == .relative, name.components.count == 1,
                builtins.contains(name.components[0]) || parameters.contains(name.components[0])
            {
                return
            }
            if resolve(name, file: file, scope: scope, seenAliases: []) == nil
                && !resolvesToBuiltin(
                    name, file: file, scope: scope, parameters: parameters, seenAliases: [])
            {
                diagnose(file.sourceName, name.range, "unknown name '\(render(name))'")
            }
        }
    }

    mutating func resolve(
        _ name: NameSyntax, file: ResolvedFile, scope: [String], seenAliases: Set<String>
    ) -> ResolvedNode? {
        switch name.root {
        case .imported(let path):
            guard let importedURL = resolveImport(path, from: file.url),
                let imported = files[importedURL.standardizedFileURL]
            else { return nil }
            return symbols[SymbolKey(fileID: imported.id, path: name.components)]
        case .absolute:
            return symbols[SymbolKey(fileID: file.id, path: name.components)]
        case .relative:
            guard !name.components.isEmpty else { return nil }
            for depth in stride(from: scope.count, through: 0, by: -1) {
                let candidateScope = Array(scope.prefix(depth))
                if let target = symbols[
                    SymbolKey(fileID: file.id, path: candidateScope + name.components)]
                {
                    return target
                }
                for aliasIndex in name.components.indices {
                    let aliasScope = candidateScope + name.components[..<aliasIndex]
                    let aliasName = name.components[aliasIndex]
                    if let alias = aliases[ScopeKey(fileID: file.id, path: Array(aliasScope))]?[
                        aliasName]
                    {
                        let aliasKey =
                            "\(file.id):\(aliasScope.joined(separator: ".")):\(aliasName)"
                        if seenAliases.contains(aliasKey) {
                            diagnose(
                                file.sourceName, name.range, "alias cycle involving '\(aliasName)'")
                            return nil
                        }
                        guard case .named(let aliasName, _) = alias else { return nil }
                        let expanded = NameSyntax(
                            root: aliasName.root,
                            components: aliasName.components
                                + name.components.dropFirst(aliasIndex + 1), range: name.range)
                        return resolve(
                            expanded, file: file, scope: Array(aliasScope),
                            seenAliases: seenAliases.union([aliasKey]))
                    }
                }
            }
            return nil
        }
    }

    func resolvesToBuiltin(
        _ name: NameSyntax, file: ResolvedFile, scope: [String], parameters: Set<String>,
        seenAliases: Set<String>
    ) -> Bool {
        guard name.root == .relative, let first = name.components.first else { return false }
        if name.components.count == 1 && (builtins.contains(first) || parameters.contains(first)) {
            return true
        }
        for depth in stride(from: scope.count, through: 0, by: -1) {
            let candidateScope = Array(scope.prefix(depth))
            for aliasIndex in name.components.indices {
                let aliasScope = candidateScope + name.components[..<aliasIndex]
                let component = name.components[aliasIndex]
                guard
                    let alias = aliases[ScopeKey(fileID: file.id, path: Array(aliasScope))]?[
                        component]
                else { continue }
                let key = "\(file.id):\(aliasScope.joined(separator: ".")):\(component)"
                guard !seenAliases.contains(key) else { return false }
                guard case .named(let aliasName, _) = alias else { return false }
                if aliasName.root == .relative, aliasName.components.count == 1,
                    scopeParameters[ScopeKey(fileID: file.id, path: Array(aliasScope))]?.contains(
                        aliasName.components[0]) == true
                {
                    return true
                }
                let expanded = NameSyntax(
                    root: aliasName.root,
                    components: aliasName.components + name.components.dropFirst(aliasIndex + 1),
                    range: name.range)
                return resolvesToBuiltin(
                    expanded, file: file, scope: Array(aliasScope), parameters: parameters,
                    seenAliases: seenAliases.union([key]))
            }
        }
        return false
    }

    func resolveImport(_ path: String, from source: URL) -> URL? {
        let candidates: [URL]
        if path.hasPrefix("/") {
            candidates = configuration.importPaths.map {
                $0.appending(path: String(path.dropFirst()))
            }
        } else {
            candidates =
                [source.deletingLastPathComponent().appending(path: path)]
                + configuration.importPaths.map { $0.appending(path: path) }
        }
        return candidates.first { fileManager.fileExists(atPath: $0.standardizedFileURL.path) }?
            .standardizedFileURL
    }

    func displayNameForImport(_ path: String, resolvedURL: URL, from sourceName: String) -> String {
        if path.hasPrefix("/") { return String(path.dropFirst()) }
        if let prefix = configuration.sourcePrefix?.standardizedFileURL,
            resolvedURL.standardizedFileURL.path.hasPrefix(prefix.path + "/")
        {
            return String(
                resolvedURL.standardizedFileURL.path.dropFirst(prefix.path.count + 1))
        }
        let base = (sourceName as NSString).deletingLastPathComponent
        if base.isEmpty || base == "." { return path }
        return ((base as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    mutating func diagnose(_ source: String, _ range: SourceRange, _ message: String) {
        diagnostics.append(SourceDiagnostic(source: source, range: range, message: message))
    }
}

private struct SymbolKey: Hashable { let fileID: UInt64; let path: [String] }
private struct ScopeKey: Hashable { let fileID: UInt64; let path: [String] }

private let builtins: Set<String> = [
    "Void", "Bool", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32",
    "UInt64", "Float32", "Float64", "Text", "Data", "AnyPointer", "AnyStruct", "AnyList",
    "Capability",
]

private func typeName(_ type: TypeSyntax) -> NameSyntax? {
    if case .named(let name, _) = type { return name }
    return nil
}

private func collectNested(_ members: [StructMemberSyntax], into result: inout [DeclarationSyntax])
{
    for member in members {
        switch member {
        case .declaration(let declaration): result.append(declaration)
        case .group(let group): collectNested(group.members, into: &result)
        case .union(let children, _, _): collectNested(children, into: &result)
        case .namedUnion(let group, _): collectNested(group.members, into: &result)
        case .field: break
        }
    }
}

private func importedPaths(in rootDeclarations: [DeclarationSyntax]) -> Set<String> {
    var result = Set<String>()
    func name(_ value: NameSyntax) {
        if case .imported(let path) = value.root { result.insert(path) }
    }
    func type(_ value: TypeSyntax) {
        switch value {
        case .list(let element): type(element);
        case .named(let value, let args): name(value); args.forEach(type)
        }
    }
    func annotations(_ values: [AnnotationUseSyntax]) {
        for annotation in values {
            name(annotation.name)
            annotation.brandArguments.forEach(type)
        }
    }
    func members(_ values: [StructMemberSyntax]) {
        for value in values {
            switch value {
            case .field(let field): type(field.type); annotations(field.annotations)
            case .group(let group): annotations(group.annotations); members(group.members)
            case .union(let children, let values, _): annotations(values); members(children)
            case .namedUnion(let group, _):
                annotations(group.annotations); members(group.members)
            case .declaration(let declaration): declarations([declaration])
            }
        }
    }
    func declarations(_ values: [DeclarationSyntax]) {
        for value in values {
            switch value {
            case .application(let annotation): annotations([annotation])
            case .using(let using): type(using.target)
            case .structure(let structure):
                annotations(structure.annotations); members(structure.members)
            case .enumeration(let enumeration):
                annotations(enumeration.annotations)
                enumeration.enumerants.forEach { annotations($0.annotations) }
            case .interface(let interface):
                annotations(interface.annotations)
                interface.superclasses.forEach(type)
                for member in interface.members {
                    switch member {
                    case .declaration(let nested): declarations([nested])
                    case .method(let method):
                        annotations(method.annotations)
                        method.parameters.forEach {
                            type($0.type); annotations($0.annotations)
                        }
                        if case .parameters(let values) = method.results {
                            values.forEach {
                                type($0.type); annotations($0.annotations)
                            }
                        }
                        if case .named(let value) = method.results { type(value) }
                    }
                }
            case .constant(let constant):
                annotations(constant.annotations); type(constant.type)
            case .annotation(let annotation):
                annotations(annotation.annotations); type(annotation.type)
            }
        }
    }
    declarations(rootDeclarations)
    return result
}

private func render(_ name: NameSyntax) -> String {
    let prefix: String
    switch name.root {
    case .relative: prefix = "";
    case .absolute: prefix = ".";
    case .imported(let path): prefix = "import \"\(path)\"."
    }
    return prefix + name.components.joined(separator: ".")
}
