import CapnProtoCompiler
import CapnProtoSchema
import Foundation
import Testing

@Test func emitsDeterministicRequestedFilesNestedScopesAndEscapedNames() throws {
    let request = try loadRequest("codegen-request")
    let first = try SwiftGenerator().generate(request)
    let second = try SwiftGenerator().generate(request)
    #expect(first == second)
    #expect(first.map(\.path) == ["keywords.capnp.swift", "import-user.capnp.swift"])

    let keywords = try #require(first.first?.contents)
    #expect(keywords.contains("public enum `Any`"))
    #expect(keywords.contains("    public enum `Protocol`"))
    #expect(keywords.contains("public enum `Type`"))
    #expect(!first.map(\.path).contains("import-base.capnp.swift"))
}

@Test(arguments: ["actor", "protocol", "extension", "repeat", "ordinaryName"])
func identifierEscaping(_ name: String) {
    let result = swiftIdentifier(name)
    #expect(result == (name == "ordinaryName" ? name : "`\(name)`"))
}

private func loadRequest(_ name: String) throws -> Schema.CodeGeneratorRequest {
    let url = try #require(
        Bundle.module.url(
            forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
    return try Schema.CodeGeneratorRequest(framedBytes: Array(try Data(contentsOf: url)))
}
