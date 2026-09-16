import Foundation

public struct LexToken: Equatable, Sendable {
    public indirect enum Kind: Equatable, Sendable {
        case identifier(String)
        case stringLiteral(String)
        case dataLiteral([UInt8])
        case integerLiteral(UInt64)
        case floatLiteral(Double)
        case `operator`(String)
        case parenthesizedList([[LexToken]])
        case bracketedList([[LexToken]])
    }

    public let kind: Kind
    public let range: SourceRange

    public init(kind: Kind, range: SourceRange) {
        self.kind = kind
        self.range = range
    }
}

public struct LexStatement: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case line
        case block([LexStatement])
    }

    public let tokens: [LexToken]
    public let body: Body
    public let docComment: String?
    public let range: SourceRange

    public init(
        tokens: [LexToken], body: Body, docComment: String?, range: SourceRange
    ) {
        self.tokens = tokens
        self.body = body
        self.docComment = docComment
        self.range = range
    }
}

public struct LexResult<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let diagnostics: [SourceDiagnostic]

    public init(value: Value, diagnostics: [SourceDiagnostic]) {
        self.value = value
        self.diagnostics = diagnostics
    }
}

public struct CapnProtoLexer: Sendable {
    public let maximumNestingDepth: Int

    public init(maximumNestingDepth: Int = 64) {
        self.maximumNestingDepth = maximumNestingDepth
    }

    public func tokens(in source: SourceFile) -> LexResult<[LexToken]> {
        var state = State(source: source, maximumNestingDepth: maximumNestingDepth)
        let tokens = state.lexTokens(until: nil, depth: 0).tokens
        return LexResult(value: tokens, diagnostics: state.diagnostics)
    }

    public func statements(in source: SourceFile) -> LexResult<[LexStatement]> {
        var state = State(source: source, maximumNestingDepth: maximumNestingDepth)
        let statements = state.lexStatements(until: nil, depth: 0)
        return LexResult(value: statements, diagnostics: state.diagnostics)
    }
}

private struct State {
    let source: SourceFile
    let maximumNestingDepth: Int
    var index = 0
    var diagnostics: [SourceDiagnostic] = []

    var bytes: [UInt8] { source.bytes }

    mutating func lexStatements(until closing: UInt8?, depth: Int) -> [LexStatement] {
        guard depth <= maximumNestingDepth else {
            diagnose(index, min(index + 1, bytes.count), "maximum nesting depth exceeded")
            skipBalanced(open: 123, close: 125)
            return []
        }
        var result: [LexStatement] = []
        while true {
            skipSpaceAndDetachedComments()
            if index >= bytes.count {
                if closing != nil { diagnose(index, index, "unterminated block") }
                return result
            }
            if bytes[index] == closing {
                index += 1
                return result
            }
            if bytes[index] == 125 {
                diagnose(index, index + 1, "unexpected '}'")
                index += 1
                continue
            }

            let start = index
            let tokenResult = lexTokens(until: [59, 123, 125], depth: depth)
            if tokenResult.tokens.isEmpty, index == start {
                diagnose(index, min(index + 1, bytes.count), "expected declaration")
                index += 1
                continue
            }

            var body: LexStatement.Body = .line
            if index < bytes.count, bytes[index] == 123 {
                index += 1
                body = .block(lexStatements(until: 125, depth: depth + 1))
            } else if index < bytes.count, bytes[index] == 59 {
                index += 1
            } else if index < bytes.count, bytes[index] == 125, closing != nil {
                diagnose(index, index + 1, "expected ';' or block")
            } else {
                diagnose(start, index, "expected ';' or block")
            }

            let comment = consumeAttachedDocComment()
            result.append(
                LexStatement(
                    tokens: tokenResult.tokens, body: body, docComment: comment,
                    range: SourceRange(startByte: start, endByte: index)))
        }
    }

    mutating func lexTokens(until terminators: Set<UInt8>?, depth: Int)
        -> (tokens: [LexToken], terminator: UInt8?)
    {
        var result: [LexToken] = []
        while true {
            skipTrivia()
            guard index < bytes.count else { return (result, nil) }
            let byte = bytes[index]
            if terminators?.contains(byte) == true { return (result, byte) }
            if byte == 40 || byte == 91 {
                result.append(lexList(open: byte, depth: depth + 1))
            } else if byte == 34 || byte == 39 {
                result.append(lexString())
            } else if byte == 96 {
                result.append(lexBlockString())
            } else if isIdentifierStart(byte) {
                result.append(lexIdentifier())
            } else if isDigit(byte) {
                result.append(lexNumber())
            } else if byte == 41 || byte == 93 {
                diagnose(index, index + 1, "unexpected '\(Character(UnicodeScalar(byte)))'")
                index += 1
            } else {
                result.append(lexOperator())
            }
        }
    }

    mutating func lexList(open: UInt8, depth: Int) -> LexToken {
        let start = index
        let close: UInt8 = open == 40 ? 41 : 93
        index += 1
        guard depth <= maximumNestingDepth else {
            diagnose(start, index, "maximum nesting depth exceeded")
            skipBalanced(open: open, close: close)
            return LexToken(
                kind: open == 40 ? .parenthesizedList([]) : .bracketedList([]),
                range: SourceRange(startByte: start, endByte: index))
        }
        var items: [[LexToken]] = []
        while true {
            skipTrivia()
            if index >= bytes.count {
                diagnose(start, index, "unterminated list")
                break
            }
            if bytes[index] == close {
                index += 1
                break
            }
            let item = lexTokens(until: [44, close], depth: depth).tokens
            if !item.isEmpty { items.append(item) }
            if index < bytes.count, bytes[index] == 44 {
                index += 1
            } else if index < bytes.count, bytes[index] == close {
                continue
            } else if index >= bytes.count {
                diagnose(start, index, "unterminated list")
                break
            }
        }
        let kind: LexToken.Kind =
            open == 40 ? .parenthesizedList(items) : .bracketedList(items)
        return LexToken(kind: kind, range: SourceRange(startByte: start, endByte: index))
    }

    mutating func lexIdentifier() -> LexToken {
        let start = index
        index += 1
        while index < bytes.count, isIdentifierContinue(bytes[index]) {
            if index + 2 < bytes.count, bytes[index...index + 2] == [0xef, 0xbb, 0xbf] {
                break
            }
            index += 1
        }
        return LexToken(
            kind: .identifier(String(decoding: bytes[start..<index], as: UTF8.self)),
            range: SourceRange(startByte: start, endByte: index))
    }

    mutating func lexNumber() -> LexToken {
        let start = index
        if index + 2 < bytes.count, bytes[index] == 48,
            bytes[index + 1] == 120 || bytes[index + 1] == 88, bytes[index + 2] == 34
        {
            index += 3
            var output: [UInt8] = []
            while index < bytes.count, bytes[index] != 34 {
                if isSpace(bytes[index]) { index += 1; continue }
                guard index + 1 < bytes.count, let high = hexValue(bytes[index]),
                    let low = hexValue(bytes[index + 1])
                else {
                    diagnose(index, min(index + 1, bytes.count), "invalid data literal")
                    index += 1; continue
                }
                output.append(high << 4 | low)
                index += 2
            }
            if index < bytes.count {
                index += 1
            } else {
                diagnose(start, index, "unterminated data literal")
            }
            return token(.dataLiteral(output), start)
        }
        if index + 1 < bytes.count, bytes[index] == 48,
            bytes[index + 1] == 120 || bytes[index + 1] == 88
        {
            index += 2
            while index < bytes.count, isHex(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[(start + 2)..<index], as: UTF8.self)
            if let value = UInt64(text, radix: 16) {
                return token(.integerLiteral(value), start)
            }
            diagnose(start, index, "invalid hexadecimal integer")
            return token(.integerLiteral(0), start)
        }
        var float = false
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        if index < bytes.count, bytes[index] == 46,
            index + 1 < bytes.count, isDigit(bytes[index + 1])
        {
            float = true
            index += 1
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
            float = true
            index += 1
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if float, let value = Double(text) { return token(.floatLiteral(value), start) }
        if let value = UInt64(text) { return token(.integerLiteral(value), start) }
        diagnose(start, index, "invalid number")
        return token(.integerLiteral(0), start)
    }

    mutating func lexString() -> LexToken {
        let start = index
        let quote = bytes[index]
        index += 1
        var output: [UInt8] = []
        while index < bytes.count, bytes[index] != quote {
            let byte = bytes[index]
            if byte == 92 {
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                switch escape {
                case 110: output.append(10)
                case 114: output.append(13)
                case 116: output.append(9)
                case 92: output.append(92)
                case 34: output.append(34)
                case 39: output.append(39)
                case 120:
                    if index + 2 < bytes.count,
                        let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
                    {
                        output.append(high << 4 | low)
                        index += 2
                    } else {
                        diagnose(index - 1, min(index + 1, bytes.count), "invalid hex escape")
                    }
                default:
                    diagnose(index - 1, index + 1, "unknown escape sequence")
                    output.append(escape)
                }
                index += 1
            } else {
                output.append(byte)
                index += 1
            }
        }
        if index < bytes.count { index += 1 } else { diagnose(start, index, "unterminated string") }
        if String(bytes: output, encoding: .utf8) == nil {
            diagnose(start, index, "string literal is not valid UTF-8")
        }
        return token(.stringLiteral(String(decoding: output, as: UTF8.self)), start)
    }

    mutating func lexBlockString() -> LexToken {
        let start = index
        index += 1
        var output: [UInt8] = []
        while index < bytes.count, bytes[index] != 10 && bytes[index] != 13 {
            output.append(bytes[index]); index += 1
        }
        output.append(10)
        return token(.stringLiteral(String(decoding: output, as: UTF8.self)), start)
    }

    mutating func lexOperator() -> LexToken {
        let start = index
        index += 1
        while index < bytes.count, isOperator(bytes[index]), bytes[index] != 44 { index += 1 }
        return token(.operator(String(decoding: bytes[start..<index], as: UTF8.self)), start)
    }

    mutating func skipTrivia() {
        while index < bytes.count {
            if isSpace(bytes[index]) { index += 1; continue }
            if index + 2 < bytes.count, bytes[index...index + 2] == [0xef, 0xbb, 0xbf] {
                index += 3; continue
            }
            if bytes[index] == 35 {
                while index < bytes.count, bytes[index] != 10 { index += 1 }
                continue
            }
            break
        }
    }

    mutating func skipSpaceAndDetachedComments() {
        skipTrivia()
    }

    mutating func consumeAttachedDocComment() -> String? {
        let saved = index
        var cursor = index
        var lines: [String] = []
        var crossedNewline = false
        while cursor < bytes.count {
            while cursor < bytes.count, bytes[cursor] == 32 || bytes[cursor] == 9 { cursor += 1 }
            if cursor < bytes.count, bytes[cursor] == 10 {
                if crossedNewline { break }
                crossedNewline = true; cursor += 1; continue
            }
            guard cursor < bytes.count, bytes[cursor] == 35 else { break }
            cursor += 1
            if cursor < bytes.count, bytes[cursor] == 32 { cursor += 1 }
            let lineStart = cursor
            while cursor < bytes.count, bytes[cursor] != 10 { cursor += 1 }
            lines.append(String(decoding: bytes[lineStart..<cursor], as: UTF8.self))
            if cursor < bytes.count { cursor += 1 }
            crossedNewline = false
        }
        if lines.isEmpty { index = saved; return nil }
        index = cursor
        return lines.joined(separator: "\n") + "\n"
    }

    mutating func skipBalanced(open: UInt8, close: UInt8) {
        var nesting = 1
        while index < bytes.count, nesting > 0 {
            if bytes[index] == open { nesting += 1 }
            if bytes[index] == close { nesting -= 1 }
            index += 1
        }
    }

    mutating func diagnose(_ start: Int, _ end: Int, _ message: String) {
        diagnostics.append(
            SourceDiagnostic(
                source: source.name,
                range: SourceRange(
                    startByte: min(max(0, start), bytes.count),
                    endByte: min(max(start, end), bytes.count)),
                message: message))
    }

    func token(_ kind: LexToken.Kind, _ start: Int) -> LexToken {
        LexToken(kind: kind, range: SourceRange(startByte: start, endByte: index))
    }
}

private func isSpace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 11 || byte == 12
}

private func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
private func isHex(_ byte: UInt8) -> Bool {
    isDigit(byte) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
}
private func hexValue(_ byte: UInt8) -> UInt8? {
    if isDigit(byte) { return byte - 48 }
    if byte >= 65 && byte <= 70 { return byte - 55 }
    if byte >= 97 && byte <= 102 { return byte - 87 }
    return nil
}
private func isIdentifierStart(_ byte: UInt8) -> Bool {
    (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || byte >= 128
}
private func isIdentifierContinue(_ byte: UInt8) -> Bool {
    isIdentifierStart(byte) || isDigit(byte)
}
private func isOperator(_ byte: UInt8) -> Bool {
    !isSpace(byte) && !isIdentifierContinue(byte) && byte != 34
        && byte != 40 && byte != 41 && byte != 91 && byte != 93 && byte != 123 && byte != 125
        && byte != 59 && byte != 35
}
