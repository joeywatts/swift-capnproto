import CapnProtoCompiler
import Testing

// Ported from capnproto 3a82de9b39736a2625f03c93b2b7c50642dd5b25:
// c++/src/capnp/compiler/lexer-test.c++.
@Test func lexerTokensTrackBytesLiteralsCommentsAndLists() throws {
    let source = SourceFile(
        name: "tokens.capnp",
        text: "\u{feff}foo # comment\n [\"bar\\x20\", 123, 2.75, 6e4, (baz, qux)]")
    let result = CapnProtoLexer().tokens(in: source)
    #expect(result.diagnostics.isEmpty)
    #expect(result.value.count == 2)
    #expect(result.value[0].kind == .identifier("foo"))
    #expect(result.value[0].range == SourceRange(startByte: 3, endByte: 6))
    guard case .bracketedList(let items) = result.value[1].kind else {
        Issue.record("expected bracketed list"); return
    }
    #expect(items.count == 5)
    #expect(items[0][0].kind == .stringLiteral("bar "))
    #expect(items[1][0].kind == .integerLiteral(123))
    #expect(items[2][0].kind == .floatLiteral(2.75))
    #expect(items[3][0].kind == .floatLiteral(60_000))
    guard case .parenthesizedList(let nested) = items[4][0].kind else {
        Issue.record("expected parenthesized list"); return
    }
    #expect(nested.map { $0.first?.kind } == [.identifier("baz"), .identifier("qux")])
}

@Test func lexerMatchesPinnedTokenListAndWhitespaceCases() throws {
    let scalars = CapnProtoLexer().tokens(
        in: SourceFile(name: "tokens.capnp", text: "  'foo\\x20' 123 2.75 6e4 + -=  "))
    #expect(scalars.diagnostics.isEmpty)
    #expect(
        scalars.value.map(\.kind) == [
            .stringLiteral("foo "), .integerLiteral(123), .floatLiteral(2.75),
            .floatLiteral(60_000), .operator("+"), .operator("-="),
        ])

    let lists = CapnProtoLexer().tokens(
        in: SourceFile(name: "lists.capnp", text: "[foo, (bar, baz),] qux"))
    #expect(lists.diagnostics.isEmpty)
    #expect(lists.value.count == 2)
    guard case .bracketedList(let outer) = lists.value[0].kind else {
        Issue.record("expected bracketed list"); return
    }
    #expect(outer.count == 2)
    guard case .parenthesizedList(let inner) = outer[1][0].kind else {
        Issue.record("expected nested parenthesized list"); return
    }
    #expect(inner.map { $0.first?.kind } == [.identifier("bar"), .identifier("baz")])

    let empty = CapnProtoLexer().tokens(
        in: SourceFile(name: "empty.capnp", text: "(  )"))
    #expect(empty.value.first?.kind == .parenthesizedList([]))

    let bom = CapnProtoLexer().tokens(
        in: SourceFile(
            name: "bom.capnp",
            bytes: [0xef, 0xbb, 0xbf] + Array("foo bar".utf8)
                + [0xef, 0xbb, 0xbf] + Array("baz".utf8)))
    #expect(bom.diagnostics.isEmpty)
    #expect(
        bom.value.map(\.range) == [
            SourceRange(startByte: 3, endByte: 6), SourceRange(startByte: 7, endByte: 10),
            SourceRange(startByte: 13, endByte: 16),
        ])
}

@Test func lexerStatementsBlocksAndDocComments() throws {
    let source = SourceFile(
        name: "statements.capnp", text: "foo { bar; # field\n baz; } # type\nqux;")
    let result = CapnProtoLexer().statements(in: source)
    #expect(result.diagnostics.isEmpty)
    #expect(result.value.count == 2)
    #expect(result.value[0].docComment == "type\n")
    guard case .block(let children) = result.value[0].body else {
        Issue.record("expected block"); return
    }
    #expect(children.count == 2)
    #expect(children[0].docComment == "field\n")
}

@Test func lexerRejectsDeepNestingWithoutInvalidRanges() {
    let source = SourceFile(name: "deep.capnp", text: String(repeating: "(", count: 256))
    let result = CapnProtoLexer(maximumNestingDepth: 30).tokens(in: source)
    #expect(!result.diagnostics.isEmpty)
    #expect(
        result.diagnostics.allSatisfy {
            $0.range.startByte >= 0 && $0.range.endByte >= $0.range.startByte
                && $0.range.endByte <= source.bytes.count
        })
}

@Test func lexerArbitraryBytesNeverProducesInvalidRanges() {
    var state: UInt64 = 0x5eed_f00d_cafe_babe
    for size in 0..<512 {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size)
        for _ in 0..<size {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: state >> 32))
        }
        let source = SourceFile(name: "bytes.capnp", bytes: bytes)
        let tokenResult = CapnProtoLexer().tokens(in: source)
        let statementResult = CapnProtoLexer().statements(in: source)
        #expect(
            (tokenResult.diagnostics + statementResult.diagnostics).allSatisfy {
                $0.range.startByte >= 0 && $0.range.endByte >= $0.range.startByte
                    && $0.range.endByte <= bytes.count
            })
        #expect(tokenResult.value.allSatisfy { tokenRangesAreValid($0, byteCount: bytes.count) })
        #expect(
            statementResult.value.allSatisfy {
                statementRangesAreValid($0, byteCount: bytes.count)
            })
    }
}

private func tokenRangesAreValid(_ token: LexToken, byteCount: Int) -> Bool {
    guard token.range.startByte >= 0, token.range.endByte >= token.range.startByte,
        token.range.endByte <= byteCount
    else { return false }
    switch token.kind {
    case .parenthesizedList(let items), .bracketedList(let items):
        return items.joined().allSatisfy { tokenRangesAreValid($0, byteCount: byteCount) }
    default: return true
    }
}

private func statementRangesAreValid(_ statement: LexStatement, byteCount: Int) -> Bool {
    guard statement.range.startByte >= 0, statement.range.endByte >= statement.range.startByte,
        statement.range.endByte <= byteCount,
        statement.tokens.allSatisfy({ tokenRangesAreValid($0, byteCount: byteCount) })
    else { return false }
    guard case .block(let children) = statement.body else { return true }
    return children.allSatisfy { statementRangesAreValid($0, byteCount: byteCount) }
}
