import CapnProto
import CapnProtoSchema
import Foundation
import Testing

@Test func decodesAndReencodesCodeGeneratorRequest() throws {
    let url = try #require(
        Bundle.module.url(
            forResource: "bootstrap-request", withExtension: "bin", subdirectory: "Fixtures"))
    let bytes = Array(try Data(contentsOf: url))
    let request = try Schema.CodeGeneratorRequest(framedBytes: bytes)

    let version = try request.capnpVersion
    #expect(try version.major >= 1)
    #expect(try request.requestedFiles.map { try $0.filename } == ["bootstrap.capnp"])

    let nodes = try request.nodes
    let fixture = try #require(nodes.first { try $0.displayName.hasSuffix(":Fixture") })
    #expect(try fixture.kind == .struct)
    #expect(try fixture.dataWordCount == 1)
    #expect(try fixture.pointerCount == 1)
    #expect(try fixture.fields.map { try $0.name } == ["count", "name"])

    let copy = try Schema.CodeGeneratorRequest(framedBytes: request.reencodedBytes())
    #expect(try copy.nodes.map { try $0.id } == nodes.map { try $0.id })
    #expect(try copy.requestedFiles.map { try $0.filename } == ["bootstrap.capnp"])
}
