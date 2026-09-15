import CapnProto
import CapnProtoSchema
import Foundation
import Testing

// Ported behavior from capnproto@3a82de9b dynamic-test.c++ and test-util.c++:
// defaults plus dynamic writes readable through the underlying typed/raw view.
@Test func dynamicBootstrapFixtureRoundTrips() throws {
    let url = try #require(Bundle.module.url(
        forResource: "bootstrap-request", withExtension: "bin", subdirectory: "Fixtures"))
    let request = try Schema.CodeGeneratorRequest(
        framedBytes: Array(Data(contentsOf: url)))
    var loader = SchemaLoader()
    try loader.load(request: request)
    try loader.finish()
    let schema = try #require(loader.registry.schema(named: "bootstrap.capnp:Fixture"))
    let message = try DynamicMessageBuilder(schema: schema, registry: loader.registry)
    let builder = try message.initRoot()

    guard case .uint16(let initial) = try message.reader().value(named: "count") else {
        Issue.record("count did not have UInt16 dynamic type")
        return
    }
    #expect(initial == 42)
    try builder.set(.uint16(7), named: "count")
    try builder.set(.text("dynamic"), named: "name")

    let reader = try message.reader()
    guard case .text(let name) = try reader.value(named: "name") else {
        Issue.record("name did not have Text dynamic type")
        return
    }
    #expect(name == "dynamic")
    let rawCount: UInt16 = try reader.asTyped { try $0.integer(atByte: 0, default: 42) }
    #expect(rawCount == 7)
}
