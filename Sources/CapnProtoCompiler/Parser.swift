public struct ParseResult: Equatable, Sendable {
    public let file: SchemaFileSyntax
    public let diagnostics: [SourceDiagnostic]
}

public struct CapnProtoParser: Sendable {
    public init() {}

    public func parse(_ source: SourceFile) -> ParseResult {
        let lexed = CapnProtoLexer().statements(in: source)
        var parser = ParserState(source: source, diagnostics: lexed.diagnostics)
        let file = parser.parseFile(lexed.value)
        return ParseResult(file: file, diagnostics: parser.diagnostics)
    }
}

private struct ParserState {
    let source: SourceFile
    var diagnostics: [SourceDiagnostic]

    mutating func parseFile(_ statements: [LexStatement]) -> SchemaFileSyntax {
        var id: UInt64?
        var declarations: [DeclarationSyntax] = []
        for statement in statements {
            var cursor = Cursor(statement.tokens)
            if cursor.consumeOperator("@"), let value = cursor.consumeInteger() {
                if id == nil { id = value } else { error(statement.range, "duplicate file ID") }
                if !cursor.isAtEnd {
                    error(cursor.remainingRange, "unexpected tokens after file ID")
                }
                continue
            }
            if let declaration = parseDeclaration(statement) { declarations.append(declaration) }
        }
        return SchemaFileSyntax(
            id: id, declarations: declarations,
            range: SourceRange(startByte: 0, endByte: source.bytes.count))
    }

    mutating func parseDeclaration(_ statement: LexStatement) -> DeclarationSyntax? {
        var cursor = Cursor(statement.tokens)
        if cursor.consumeOperator("$") {
            guard let name = parseName(&cursor) else {
                error(statement.range, "expected annotation name"); return nil
            }
            var value: ValueSyntax?
            if let lists = cursor.consumeParenthesized(), lists.count == 1 {
                var item = Cursor(lists[0])
                value = parseValue(&item)
            }
            finish(&cursor, statement.range)
            return .application(
                AnnotationUseSyntax(
                    name: name, brandArguments: [], value: value, range: statement.range))
        }
        guard let keyword = cursor.consumeIdentifier() else {
            error(statement.range, "expected declaration keyword"); return nil
        }
        switch keyword {
        case "using": return parseUsing(statement, &cursor).map(DeclarationSyntax.using)
        case "struct": return parseStruct(statement, &cursor).map(DeclarationSyntax.structure)
        case "enum": return parseEnum(statement, &cursor).map(DeclarationSyntax.enumeration)
        case "interface": return parseInterface(statement, &cursor).map(DeclarationSyntax.interface)
        case "const": return parseConstant(statement, &cursor).map(DeclarationSyntax.constant)
        case "annotation":
            return parseAnnotationDeclaration(statement, &cursor).map(DeclarationSyntax.annotation)
        default:
            error(statement.range, "unknown declaration '\(keyword)'"); return nil
        }
    }

    mutating func parseUsing(_ statement: LexStatement, _ cursor: inout Cursor) -> UsingSyntax? {
        let first = cursor.consumeIdentifier()
        var alias: String?
        var leading: String?
        if first == "import" {
            leading = "import"
        } else if cursor.consumeOperator("=") {
            alias = first
        } else {
            leading = first
        }
        guard let target = parseType(&cursor, leadingIdentifier: leading) else {
            error(statement.range, "expected using target"); return nil
        }
        finish(&cursor, statement.range)
        return UsingSyntax(name: alias, target: target, range: statement.range)
    }

    mutating func parseStruct(_ statement: LexStatement, _ cursor: inout Cursor) -> StructSyntax? {
        guard let name = cursor.consumeIdentifier() else {
            error(statement.range, "expected struct name"); return nil
        }
        let id = parseOptionalID(&cursor)
        let parameters = parseGenericParameters(&cursor)
        let annotations = parseAnnotations(&cursor)
        finish(&cursor, statement.range)
        guard case .block(let statements) = statement.body else {
            error(statement.range, "struct requires a block"); return nil
        }
        return StructSyntax(
            name: name, id: id, parameters: parameters, annotations: annotations,
            members: parseStructMembers(statements), range: statement.range,
            docComment: statement.docComment)
    }

    mutating func parseStructMembers(_ statements: [LexStatement]) -> [StructMemberSyntax] {
        var result: [StructMemberSyntax] = []
        for statement in statements {
            var cursor = Cursor(statement.tokens)
            guard let first = cursor.consumeIdentifier() else {
                error(statement.range, "expected struct member"); continue
            }
            if first == "union" {
                guard case .block(let children) = statement.body else {
                    error(statement.range, "union requires a block"); continue
                }
                let annotations = parseAnnotations(&cursor)
                finish(&cursor, statement.range)
                result.append(
                    .union(
                        parseStructMembers(children), annotations: annotations,
                        statement.range))
                continue
            }
            if cursor.consumeOperator(":"), cursor.consumeIdentifier("group") != nil {
                guard case .block(let children) = statement.body else {
                    error(statement.range, "group requires a block"); continue
                }
                let annotations = parseAnnotations(&cursor)
                finish(&cursor, statement.range)
                result.append(
                    .group(
                        GroupSyntax(
                            name: first, members: parseStructMembers(children),
                            annotations: annotations,
                            range: statement.range,
                            docComment: statement.docComment)))
                continue
            }
            cursor = Cursor(statement.tokens)
            _ = cursor.consumeIdentifier()
            var namedUnionOrdinal: UInt16?
            if cursor.consumeOperator("@"), let ordinal = cursor.consumeInteger(),
                ordinal <= UInt16.max
            {
                namedUnionOrdinal = UInt16(ordinal)
                _ = cursor.consumeOperator("!")
            }
            if cursor.consumeOperator(":"), cursor.consumeIdentifier("union") != nil {
                guard case .block(let children) = statement.body else {
                    error(statement.range, "named union requires a block"); continue
                }
                let annotations = parseAnnotations(&cursor)
                finish(&cursor, statement.range)
                result.append(
                    .namedUnion(
                        GroupSyntax(
                            name: first, members: parseStructMembers(children),
                            annotations: annotations,
                            range: statement.range,
                            docComment: statement.docComment), ordinal: namedUnionOrdinal))
                continue
            }
            cursor = Cursor(statement.tokens)
            _ = cursor.consumeIdentifier()
            if ["struct", "enum", "interface", "const", "annotation", "using"].contains(first),
                !(cursor.peek.map {
                    if case .operator("@") = $0.kind { return true }; return false
                } ?? false)
            {
                if let declaration = parseDeclaration(statement) {
                    result.append(.declaration(declaration))
                }
                continue
            }
            guard cursor.consumeOperator("@"), let ordinalValue = cursor.consumeInteger(),
                ordinalValue <= UInt16.max
            else {
                error(statement.range, "invalid field declaration"); continue
            }
            _ = cursor.consumeOperator("!")
            guard expectOperator(":", &cursor), let type = parseType(&cursor) else {
                error(statement.range, "invalid field declaration"); continue
            }
            let defaultValue = cursor.consumeOperator("=") ? parseValue(&cursor) : nil
            let annotations = parseAnnotations(&cursor)
            finish(&cursor, statement.range)
            result.append(
                .field(
                    FieldSyntax(
                        name: first, ordinal: UInt16(ordinalValue), type: type,
                        defaultValue: defaultValue, annotations: annotations,
                        range: statement.range,
                        docComment: statement.docComment)))
        }
        return result
    }

    mutating func parseEnum(_ statement: LexStatement, _ cursor: inout Cursor) -> EnumSyntax? {
        guard let name = cursor.consumeIdentifier() else {
            error(statement.range, "expected enum name"); return nil
        }
        let id = parseOptionalID(&cursor)
        let annotations = parseAnnotations(&cursor)
        finish(&cursor, statement.range)
        guard case .block(let children) = statement.body else {
            error(statement.range, "enum requires a block"); return nil
        }
        var values: [EnumerantSyntax] = []
        for child in children {
            var item = Cursor(child.tokens)
            guard let valueName = item.consumeIdentifier(), item.consumeOperator("@"),
                let ordinal = item.consumeInteger(), ordinal <= UInt16.max
            else { error(child.range, "invalid enumerant"); continue }
            let annotations = parseAnnotations(&item)
            finish(&item, child.range)
            values.append(
                EnumerantSyntax(
                    name: valueName, ordinal: UInt16(ordinal), annotations: annotations,
                    range: child.range, docComment: child.docComment))
        }
        return EnumSyntax(
            name: name, id: id, enumerants: values, annotations: annotations,
            range: statement.range,
            docComment: statement.docComment)
    }

    mutating func parseInterface(_ statement: LexStatement, _ cursor: inout Cursor)
        -> InterfaceSyntax?
    {
        guard let name = cursor.consumeIdentifier() else {
            error(statement.range, "expected interface name"); return nil
        }
        let id = parseOptionalID(&cursor)
        let parameters = parseGenericParameters(&cursor)
        var superclasses: [TypeSyntax] = []
        if cursor.consumeIdentifier("extends") != nil, let lists = cursor.consumeParenthesized() {
            for list in lists {
                var item = Cursor(list)
                if let type = parseType(&item) { superclasses.append(type) }
                finish(&item, statement.range)
            }
        }
        let annotations = parseAnnotations(&cursor)
        finish(&cursor, statement.range)
        guard case .block(let children) = statement.body else {
            error(statement.range, "interface requires a block"); return nil
        }
        var members: [InterfaceMemberSyntax] = []
        for child in children {
            var item = Cursor(child.tokens)
            guard let first = item.consumeIdentifier() else {
                error(child.range, "expected interface member"); continue
            }
            if ["struct", "enum", "interface", "const", "annotation", "using"].contains(first) {
                if let declaration = parseDeclaration(child) {
                    members.append(.declaration(declaration))
                }
                continue
            }
            guard item.consumeOperator("@"), let ordinal = item.consumeInteger(),
                ordinal <= UInt16.max
            else { error(child.range, "invalid method declaration"); continue }
            var methodTypeParameters: [String] = []
            if let genericLists = item.consumeBracketed() {
                methodTypeParameters = genericLists.compactMap { tokens in
                    var generic = Cursor(tokens); return generic.consumeIdentifier()
                }
            }
            let params: [ParameterSyntax]
            if let parameterLists = item.consumeParenthesized() {
                params = parseParameters(parameterLists, fallbackRange: child.range)
            } else if let type = parseType(&item) {
                params = [
                    ParameterSyntax(
                        name: "params", type: type, defaultValue: nil, annotations: [],
                        range: child.range)
                ]
            } else {
                error(child.range, "invalid method parameters"); continue
            }
            let results: MethodResultsSyntax
            if item.consumeOperator("->") {
                if item.consumeIdentifier("stream") != nil {
                    results = .stream
                } else if let resultLists = item.consumeParenthesized() {
                    results = .parameters(parseParameters(resultLists, fallbackRange: child.range))
                } else if let type = parseType(&item) {
                    results = .named(type)
                } else {
                    error(child.range, "invalid method result"); continue
                }
            } else {
                results = .parameters([])
            }
            let annotations = parseAnnotations(&item)
            finish(&item, child.range)
            members.append(
                .method(
                    MethodSyntax(
                        name: first, ordinal: UInt16(ordinal), typeParameters: methodTypeParameters,
                        parameters: params, results: results,
                        annotations: annotations, range: child.range, docComment: child.docComment))
            )
        }
        return InterfaceSyntax(
            name: name, id: id, parameters: parameters, superclasses: superclasses,
            annotations: annotations,
            members: members, range: statement.range, docComment: statement.docComment)
    }

    mutating func parseConstant(_ statement: LexStatement, _ cursor: inout Cursor)
        -> ConstantSyntax?
    {
        guard let name = cursor.consumeIdentifier(), expectOperator(":", &cursor),
            let type = parseType(&cursor), expectOperator("=", &cursor),
            let value = parseValue(&cursor)
        else { error(statement.range, "invalid constant declaration"); return nil }
        let annotations = parseAnnotations(&cursor)
        finish(&cursor, statement.range)
        return ConstantSyntax(
            name: name, type: type, value: value, annotations: annotations,
            range: statement.range,
            docComment: statement.docComment)
    }

    mutating func parseAnnotationDeclaration(
        _ statement: LexStatement, _ cursor: inout Cursor
    ) -> AnnotationDeclarationSyntax? {
        guard let name = cursor.consumeIdentifier() else {
            error(statement.range, "expected annotation name"); return nil
        }
        let id = parseOptionalID(&cursor)
        var targets: [String] = []
        if let lists = cursor.consumeParenthesized() {
            targets = lists.compactMap { tokens in
                var item = Cursor(tokens)
                return item.consumeIdentifier()
            }
        }
        guard expectOperator(":", &cursor), let type = parseType(&cursor) else {
            error(statement.range, "invalid annotation declaration"); return nil
        }
        let annotations = parseAnnotations(&cursor)
        finish(&cursor, statement.range)
        return AnnotationDeclarationSyntax(
            name: name, id: id, type: type, targets: targets, annotations: annotations,
            range: statement.range,
            docComment: statement.docComment)
    }

    mutating func parseParameters(_ lists: [[LexToken]], fallbackRange: SourceRange)
        -> [ParameterSyntax]
    {
        lists.compactMap { tokens in
            var cursor = Cursor(tokens)
            guard let name = cursor.consumeIdentifier(), expectOperator(":", &cursor),
                let type = parseType(&cursor)
            else { error(fallbackRange, "invalid parameter"); return nil }
            let defaultValue = cursor.consumeOperator("=") ? parseValue(&cursor) : nil
            let annotations = parseAnnotations(&cursor)
            let range = tokensRange(tokens) ?? fallbackRange
            finish(&cursor, range)
            return ParameterSyntax(
                name: name, type: type, defaultValue: defaultValue,
                annotations: annotations, range: range)
        }
    }

    mutating func parseType(_ cursor: inout Cursor, leadingIdentifier: String? = nil) -> TypeSyntax?
    {
        guard var name = parseName(&cursor, leadingIdentifier: leadingIdentifier) else {
            return nil
        }
        var arguments: [TypeSyntax] = []
        if let lists = cursor.consumeParenthesized() {
            for list in lists {
                var item = Cursor(list)
                guard let argument = parseType(&item) else { continue }
                arguments.append(argument)
                finish(&item, tokensRange(list) ?? name.range)
            }
        }
        while cursor.consumeOperator("."), let component = cursor.consumeIdentifier() {
            name = NameSyntax(
                root: name.root, components: name.components + [component],
                range: SourceRange(
                    startByte: name.range.startByte,
                    endByte: cursor.previous?.range.endByte ?? name.range.endByte))
            if let lists = cursor.consumeParenthesized() {
                for list in lists {
                    var item = Cursor(list)
                    if let argument = parseType(&item) { arguments.append(argument) }
                }
            }
        }
        if name.root == .relative, name.components == ["List"], arguments.count == 1 {
            return .list(arguments[0])
        }
        return .named(name, arguments: arguments)
    }

    mutating func parseName(_ cursor: inout Cursor, leadingIdentifier: String? = nil) -> NameSyntax?
    {
        let start = cursor.peek?.range.startByte ?? 0
        var root = NameSyntax.Root.relative
        var components: [String] = []
        var first = leadingIdentifier
        if first == nil, cursor.consumeOperator(".") { root = .absolute }
        if first == nil { first = cursor.consumeIdentifier() }
        if first == "import" {
            guard let path = cursor.consumeString() else { return nil }
            root = .imported(path)
        } else if let first {
            components.append(first)
        } else {
            return nil
        }
        while cursor.consumeOperator("."), let component = cursor.consumeIdentifier() {
            components.append(component)
        }
        let end = cursor.previous?.range.endByte ?? start
        return NameSyntax(
            root: root, components: components, range: SourceRange(startByte: start, endByte: end))
    }

    mutating func parseValue(_ cursor: inout Cursor) -> ValueSyntax? {
        if cursor.consumeIdentifier("embed") != nil, let path = cursor.consumeString() {
            return .embed(path)
        }
        if cursor.consumeOperator("-") {
            if let integer = cursor.consumeInteger() { return .negativeInteger(integer) }
            if let float = cursor.consumeFloat() { return .float(-float) }
            if cursor.consumeIdentifier("inf") != nil { return .float(-.infinity) }
            if cursor.consumeIdentifier("nan") != nil { return .float(-.nan) }
            return nil
        }
        if let integer = cursor.consumeInteger() { return .integer(integer) }
        if let float = cursor.consumeFloat() { return .float(float) }
        if let string = cursor.consumeString() { return .string(string) }
        if let data = cursor.consumeData() { return .data(data) }
        if let lists = cursor.consumeBracketed() {
            return .list(
                lists.compactMap { list in
                    var item = Cursor(list); return parseValue(&item)
                })
        }
        if let lists = cursor.consumeParenthesized() {
            var fields: [(String, ValueSyntax)] = []
            for list in lists {
                var item = Cursor(list)
                guard let name = item.consumeIdentifier(), item.consumeOperator("="),
                    let value = parseValue(&item)
                else { continue }
                fields.append((name, value))
            }
            return fields.isEmpty && lists.isEmpty ? .void : .tuple(fields)
        }
        return parseName(&cursor).map(ValueSyntax.identifier)
    }

    mutating func parseAnnotations(_ cursor: inout Cursor) -> [AnnotationUseSyntax] {
        var result: [AnnotationUseSyntax] = []
        while cursor.consumeOperator("$") {
            guard var name = parseName(&cursor) else { break }
            var brandArguments: [TypeSyntax] = []
            var value: ValueSyntax?
            if let lists = cursor.consumeParenthesized() {
                if cursor.consumeOperator("."), let member = cursor.consumeIdentifier() {
                    brandArguments = lists.compactMap { tokens in
                        var item = Cursor(tokens)
                        return parseType(&item)
                    }
                    name = NameSyntax(
                        root: name.root, components: name.components + [member],
                        range: SourceRange(
                            startByte: name.range.startByte,
                            endByte: cursor.previous?.range.endByte ?? name.range.endByte))
                    if let argumentLists = cursor.consumeParenthesized() {
                        if argumentLists.count == 1 {
                            var item = Cursor(argumentLists[0]); value = parseValue(&item)
                        } else {
                            value = .list(
                                argumentLists.compactMap {
                                    var item = Cursor($0); return parseValue(&item)
                                })
                        }
                    }
                } else if lists.count == 1 {
                    var item = Cursor(lists[0]); value = parseValue(&item)
                } else {
                    value = .list(
                        lists.compactMap {
                            var item = Cursor($0); return parseValue(&item)
                        })
                }
            }
            result.append(
                AnnotationUseSyntax(
                    name: name, brandArguments: brandArguments, value: value,
                    range: name.range))
        }
        return result
    }

    mutating func parseOptionalID(_ cursor: inout Cursor) -> UInt64? {
        guard cursor.consumeOperator("@") else { return nil }
        return cursor.consumeInteger()
    }

    mutating func parseGenericParameters(_ cursor: inout Cursor) -> [String] {
        guard let lists = cursor.consumeParenthesized() else { return [] }
        return lists.compactMap {
            var item = Cursor($0)
            return item.consumeIdentifier()
        }
    }

    mutating func expectOperator(_ value: String, _ cursor: inout Cursor) -> Bool {
        cursor.consumeOperator(value)
    }

    mutating func finish(_ cursor: inout Cursor, _ range: SourceRange) {
        if !cursor.isAtEnd { error(cursor.remainingRange, "unexpected tokens") }
    }

    mutating func error(_ range: SourceRange, _ message: String) {
        diagnostics.append(SourceDiagnostic(source: source.name, range: range, message: message))
    }
}

private struct Cursor {
    let tokens: [LexToken]
    var index = 0
    init(_ tokens: [LexToken]) { self.tokens = tokens }
    var isAtEnd: Bool { index >= tokens.count }
    var peek: LexToken? { isAtEnd ? nil : tokens[index] }
    var previous: LexToken? { index == 0 ? nil : tokens[index - 1] }
    var remainingRange: SourceRange {
        SourceRange(
            startByte: peek?.range.startByte ?? previous?.range.endByte ?? 0,
            endByte: tokens.last?.range.endByte ?? previous?.range.endByte ?? 0)
    }

    mutating func consumeIdentifier(_ expected: String? = nil) -> String? {
        guard let token = peek, case .identifier(let value) = token.kind,
            expected == nil || value == expected
        else { return nil }
        index += 1; return value
    }
    mutating func consumeInteger() -> UInt64? {
        guard let token = peek, case .integerLiteral(let value) = token.kind else { return nil }
        index += 1; return value
    }
    mutating func consumeFloat() -> Double? {
        guard let token = peek, case .floatLiteral(let value) = token.kind else { return nil }
        index += 1; return value
    }
    mutating func consumeString() -> String? {
        guard let token = peek, case .stringLiteral(let value) = token.kind else { return nil }
        index += 1
        var result = value
        while let token = peek, case .stringLiteral(let next) = token.kind {
            result += next
            index += 1
        }
        return result
    }
    mutating func consumeData() -> [UInt8]? {
        guard let token = peek, case .dataLiteral(let value) = token.kind else { return nil }
        index += 1; return value
    }
    mutating func consumeOperator(_ expected: String) -> Bool {
        guard let token = peek, case .operator(let value) = token.kind, value == expected else {
            return false
        }
        index += 1; return true
    }
    mutating func consumeParenthesized() -> [[LexToken]]? {
        guard let token = peek, case .parenthesizedList(let value) = token.kind else { return nil }
        index += 1; return value
    }
    mutating func consumeBracketed() -> [[LexToken]]? {
        guard let token = peek, case .bracketedList(let value) = token.kind else { return nil }
        index += 1; return value
    }
}

private func tokensRange(_ tokens: [LexToken]) -> SourceRange? {
    guard let first = tokens.first, let last = tokens.last else { return nil }
    return SourceRange(startByte: first.range.startByte, endByte: last.range.endByte)
}
