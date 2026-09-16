import CapnProtoCompiler
import CapnProtoSchema
import Foundation
import Testing

@Test func nativeCompilerProducesReadableRequestAndSwift() throws {
    let fixture = try #require(
        Bundle.module.url(forResource: "advanced", withExtension: "capnp", subdirectory: "Fixtures")
    )
    let root = fixture.deletingLastPathComponent()
    let result = try NativeSchemaCompiler(
        configuration: CompilerConfiguration(
            importPaths: [root], sourcePrefix: root
        )
    ).compile(files: [fixture])

    let request = try Schema.CodeGeneratorRequest(framedBytes: result.requestBytes)
    #expect(try request.requestedFiles.count == 1)
    #expect(try request.requestedFiles[0].filename == "advanced.capnp")
    #expect(result.generatedFiles.map(\.path) == ["advanced.capnp.swift"])
    #expect(result.generatedFiles[0].contents.contains("public enum Advanced"))
}

@Test func nativeAndRequestFrontendsGenerateEquivalentRepresentativeSwift() throws {
    let fixtures = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures"))
    let files = ["keywords.capnp", "advanced.capnp", "interfaces.capnp"].map {
        fixtures.appending(path: $0)
    }
    let result = try NativeSchemaCompiler(
        configuration: CompilerConfiguration(
            importPaths: [fixtures], sourcePrefix: fixtures
        )
    ).compile(files: files)
    #expect(result.generatedFiles.count == files.count)
    #expect(result.generatedFiles.allSatisfy { !$0.contents.isEmpty })
}
