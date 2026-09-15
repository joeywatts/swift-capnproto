import CapnProto
import CapnProtoSchema
import Foundation
import Testing

private let emptyBrand = SchemaBrand()

// Ported behavior from capnproto@3a82de9b schema-test.c++: Structs, Unions,
// Enums, NestedLookup, and InterfacesMethods.
@Test func loadsBootstrappedSchemasAndPerformsLookup() throws {
    let request = try bootstrapRequest()
    var loader = SchemaLoader()
    let loaded = try loader.load(request: request)
    try loader.finish()

    #expect(loaded.count == 2)
    let file = try #require(loader.registry.schema(named: "bootstrap.capnp"))
    let fixtureID = try #require(file.nestedNodes["Fixture"])
    let fixture = try loader.registry.dependency(fixtureID, of: file)
    #expect(fixture.unqualifiedName == "Fixture")
    #expect(fixture.field(named: "count")?.hadExplicitDefault == true)
    #expect(fixture.field(named: "name") != nil)
    #expect(fixture.field(named: "missing") == nil)
}

// Ported behavior from capnproto@3a82de9b schema-loader-test.c++: Load,
// Upgrade, Downgrade, Incompatible, and OutOfBoundsFieldOffset.
@Test func validatesIncrementalGraphsAndSchemaReplacement() throws {
    let old = makeRecord(fieldCount: 1, dataWords: 1)
    let new = makeRecord(fieldCount: 2, dataWords: 2)
    let compatibility = SchemaLoader.compatibility(of: new, with: old)
    #expect(compatibility.canReadExisting)
    #expect(!compatibility.canWriteExisting)
    #expect(!compatibility.isEquivalent)

    var loader = SchemaLoader()
    try loader.load(old)
    try loader.load(new)
    #expect(loader.registry.schema(id: old.id)?.field(named: "extra") != nil)
    try loader.load(old)
    #expect(loader.registry.schema(id: old.id)?.field(named: "extra") != nil)

    var missing = SchemaLoader()
    try missing.load(
        SchemaNode(
            id: 20, displayName: "MissingOwner", nestedNodes: ["Child": 21], kind: .file))
    #expect(throws: SchemaError.missingSchema(21)) { try missing.finish() }

    var invalid = SchemaLoader()
    let invalidField = SchemaField(
        name: "bad", codeOrder: 0,
        storage: .slot(offset: UInt32.max, type: .uint64, defaultValue: .uint64(0)))
    #expect(throws: SchemaError.self) {
        try invalid.load(
            SchemaNode(
                id: 22, displayName: "Invalid",
                kind: .structure(
                    dataWordCount: 1, pointerCount: 0, preferredListEncoding: .inlineComposite,
                    isGroup: false, discriminantCount: 0, discriminantOffset: 0,
                    fields: [invalidField])))
    }
}

// Ported behavior from capnproto@3a82de9b dynamic-test.c++ and the dynamic
// helpers in test-util.c++: scalar/default/blob/list/enum/struct field access.
@Test func dynamicallyRoundTripsAllFieldShapesAndMatchesRawTypedView() throws {
    let schemas = try makeDynamicRegistry()
    let rootSchema = try schemas.requireSchema(id: 100)
    let dynamicMessage = try DynamicMessageBuilder(schema: rootSchema, registry: schemas)
    let builder = try dynamicMessage.initRoot()

    try builder.set(.bool(true), named: "flag")
    try builder.set(.int32(-1234), named: "number")
    try builder.set(.uint64(UInt64.max - 4), named: "big")
    try builder.set(.float64(-0.0), named: "ratio")
    try builder.set(.text("hello\nworld"), named: "name")
    try builder.set(.data([0, 1, 0xfe, 0xff]), named: "bytes")
    try builder.set(
        .enumeration(
            try DynamicEnum(
                rawValue: 1, schema: schemas.requireSchema(id: 101))), named: "color")

    let numbers = try builder.initList(named: "numbers", count: 3)
    try numbers.set(.uint16(2), at: 0)
    try numbers.set(.uint16(3), at: 1)
    try numbers.set(.uint16(5), at: 2)
    let child = try builder.initStruct(named: "child")
    try child.set(.uint32(99), named: "value")

    let reader = try dynamicMessage.reader()
    #expect(try reader.value(named: "flag").boolValue == true)
    #expect(try reader.value(named: "number").int32Value == -1234)
    #expect(try reader.value(named: "name").textValue == "hello\nworld")
    #expect(try reader.value(named: "bytes").dataValue == [0, 1, 0xfe, 0xff])
    let list = try #require(reader.value(named: "numbers").listValue)
    #expect(list.count == 3)
    #expect(try list.value(at: 2).uint16Value == 5)
    let childReader = try #require(reader.value(named: "child").structValue)
    #expect(try childReader.value(named: "value").uint32Value == 99)

    let rawNumber: Int32 = try reader.asTyped { try $0.integer(atByte: 4) }
    #expect(rawNumber == -1234)
    #expect(
        try DynamicDiagnostics.describe(reader)
            == DynamicDiagnostics.describe(reader.raw, schema: rootSchema, registry: schemas))
    #expect(try DynamicDiagnostics.describe(reader).contains("name = \"hello\\nworld\""))
    #expect(try DynamicDiagnostics.describe(reader).contains("ratio = -0"))
}

// Ported behavior from capnproto@3a82de9b dynamic-test.c++: unions, groups,
// unknown enum values, capabilities, and AnyPointer.
@Test func dynamicallyHandlesUnionsGroupsCapabilitiesAndAnyPointer() throws {
    let schemas = try makeDynamicRegistry()
    let unionSchema = try schemas.requireSchema(id: 103)
    let message = try DynamicMessageBuilder(schema: unionSchema, registry: schemas)
    let builder = try message.initRoot()
    try builder.set(.int32(17), named: "number")
    #expect(try message.reader().activeUnionField()?.name == "number")
    try builder.set(.text("selected"), named: "text")
    let reader = try message.reader()
    #expect(try reader.activeUnionField()?.name == "text")
    #expect(try reader.value(named: "text").textValue == "selected")
    #expect(throws: SchemaError.self) { try reader.value(named: "number") }

    let rootSchema = try schemas.requireSchema(id: 100)
    let other = try DynamicMessageBuilder(schema: rootSchema, registry: schemas)
    let otherBuilder = try other.initRoot()
    try otherBuilder.set(.capability(7), named: "service")
    let cap = try other.reader().value(named: "service")
    #expect(cap.capabilityValue == 7)

    let groupSchema = try schemas.requireSchema(id: 105)
    let groupMessage = try DynamicMessageBuilder(schema: groupSchema, registry: schemas)
    let groupBuilder = try groupMessage.initRoot()
    try groupBuilder.set(.bool(true), named: "enabled")
    try otherBuilder.set(.int32(44), named: "number")
    try otherBuilder.set(.structure(try groupMessage.reader()), named: "settings")
    let afterGroup = try other.reader()
    #expect(try afterGroup.value(named: "number").int32Value == 44)
    let groupReader = try #require(afterGroup.value(named: "settings").structValue)
    #expect(try groupReader.value(named: "enabled").boolValue == true)

    let childSource = try otherBuilder.initStruct(named: "child")
    try childSource.set(.uint32(123), named: "value")
    let sourceReader = try #require(other.reader().value(named: "child").structValue)
    try otherBuilder.set(.structure(sourceReader), named: "payload")
    guard case .anyPointer(let payload) = try other.reader().value(named: "payload") else {
        Issue.record("payload did not have AnyPointer dynamic type")
        return
    }
    #expect(try payload.asStruct().integer(atByte: 0, as: UInt32.self) == 123)

    let outer = try otherBuilder.initList(named: "nestedChildren", count: 1)
    let inner = try outer.initList(at: 0, count: 2)
    try inner.structElement(at: 1).set(.uint32(321), named: "value")
    guard case .list(let outerReader) = try other.reader().value(named: "nestedChildren"),
        case .list(let innerReader) = try outerReader.value(at: 0),
        case .structure(let nestedChild) = try innerReader.value(at: 1)
    else {
        Issue.record("nested struct list had the wrong dynamic shape")
        return
    }
    #expect(try nestedChild.value(named: "value").uint32Value == 321)

    let unknown = try DynamicEnum(rawValue: 65000, schema: schemas.requireSchema(id: 101))
    #expect(unknown.name == nil)
    #expect(try DynamicDiagnostics.describe(.enumeration(unknown)) == "unknown(65000)")
}

// Ported behavior from capnproto@3a82de9b stringify-test.c++: stable escaping,
// enum names, schema diagnostics, and bounded recursive/list formatting.
@Test func stringificationIsDeterministicAndBounded() throws {
    let schemas = try makeDynamicRegistry()
    let schema = try schemas.requireSchema(id: 100)
    let first = DynamicDiagnostics.describe(schema: schema)
    let second = DynamicDiagnostics.describe(schema: schema)
    #expect(first == second)
    #expect(first.contains("struct Dynamic.Root @0x64"))

    let message = try DynamicMessageBuilder(schema: schema, registry: schemas)
    let builder = try message.initRoot()
    let list = try builder.initList(named: "numbers", count: 4)
    for index in 0..<4 { try list.set(.uint16(UInt16(index)), at: index) }
    let reader = try message.reader()
    let limited = try DynamicDiagnostics.describe(
        reader, options: DiagnosticOptions(maximumDepth: 4, maximumListElements: 2))
    #expect(limited.contains("numbers = [0, 1, ...]"))
    #expect(
        try DynamicDiagnostics.describe(
            reader, options: DiagnosticOptions(maximumDepth: 0)) == "...")
}

private func bootstrapRequest() throws -> Schema.CodeGeneratorRequest {
    let url = try #require(
        Bundle.module.url(
            forResource: "bootstrap-request", withExtension: "bin", subdirectory: "Fixtures"))
    return try Schema.CodeGeneratorRequest(framedBytes: Array(Data(contentsOf: url)))
}

private func makeRecord(fieldCount: Int, dataWords: UInt16) -> SchemaNode {
    var fields = [
        SchemaField(
            name: "value", codeOrder: 0,
            storage: .slot(offset: 0, type: .uint64, defaultValue: .uint64(0)))
    ]
    if fieldCount > 1 {
        fields.append(
            SchemaField(
                name: "extra", codeOrder: 1,
                storage: .slot(offset: 1, type: .uint64, defaultValue: .uint64(0))))
    }
    return SchemaNode(
        id: 10, displayName: "Evolution.Record", displayNamePrefixLength: 10,
        kind: .structure(
            dataWordCount: dataWords, pointerCount: 0,
            preferredListEncoding: .inlineComposite, isGroup: false,
            discriminantCount: 0, discriminantOffset: 0, fields: fields))
}

private func makeDynamicRegistry() throws -> SchemaRegistry {
    let color = SchemaNode(
        id: 101, displayName: "Dynamic.Color", displayNamePrefixLength: 8, scopeID: 100,
        kind: .enumeration([
            SchemaEnumerant(name: "red", codeOrder: 0),
            SchemaEnumerant(name: "green", codeOrder: 1),
        ]))
    let child = SchemaNode(
        id: 102, displayName: "Dynamic.Child", displayNamePrefixLength: 8, scopeID: 100,
        kind: .structure(
            dataWordCount: 1, pointerCount: 0, preferredListEncoding: .inlineComposite,
            isGroup: false, discriminantCount: 0, discriminantOffset: 0,
            fields: [
                SchemaField(
                    name: "value", codeOrder: 0,
                    storage: .slot(offset: 0, type: .uint32, defaultValue: .uint32(0)))
            ]))
    let root = SchemaNode(
        id: 100, displayName: "Dynamic.Root", displayNamePrefixLength: 8,
        nestedNodes: ["Color": 101, "Child": 102],
        kind: .structure(
            dataWordCount: 4, pointerCount: 7, preferredListEncoding: .inlineComposite,
            isGroup: false, discriminantCount: 0, discriminantOffset: 0,
            fields: [
                SchemaField(
                    name: "flag", codeOrder: 0,
                    storage: .slot(offset: 0, type: .bool, defaultValue: .bool(false))),
                SchemaField(
                    name: "number", codeOrder: 1,
                    storage: .slot(offset: 1, type: .int32, defaultValue: .int32(0))),
                SchemaField(
                    name: "big", codeOrder: 2,
                    storage: .slot(offset: 1, type: .uint64, defaultValue: .uint64(0))),
                SchemaField(
                    name: "ratio", codeOrder: 3,
                    storage: .slot(offset: 3, type: .float64, defaultValue: .float64(0))),
                SchemaField(
                    name: "color", codeOrder: 4,
                    storage: .slot(
                        offset: 1, type: .enumeration(id: 101, brand: emptyBrand),
                        defaultValue: .enumeration(0))),
                SchemaField(
                    name: "name", codeOrder: 5,
                    storage: .slot(offset: 0, type: .text, defaultValue: .text(""))),
                SchemaField(
                    name: "bytes", codeOrder: 6,
                    storage: .slot(offset: 1, type: .data, defaultValue: .data([]))),
                SchemaField(
                    name: "numbers", codeOrder: 7,
                    storage: .slot(offset: 2, type: .list(.uint16), defaultValue: .void)),
                SchemaField(
                    name: "child", codeOrder: 8,
                    storage: .slot(
                        offset: 3, type: .structure(id: 102, brand: emptyBrand),
                        defaultValue: .void)),
                SchemaField(
                    name: "service", codeOrder: 9,
                    storage: .slot(
                        offset: 4, type: .interface(id: 104, brand: emptyBrand),
                        defaultValue: .interface)),
                SchemaField(
                    name: "settings", codeOrder: 10, storage: .group(typeID: 105)),
                SchemaField(
                    name: "payload", codeOrder: 11,
                    storage: .slot(
                        offset: 5, type: .anyPointer(.any), defaultValue: .void)),
                SchemaField(
                    name: "nestedChildren", codeOrder: 12,
                    storage: .slot(
                        offset: 6,
                        type: .list(.list(.structure(id: 102, brand: emptyBrand))),
                        defaultValue: .void)),
            ]))
    let union = SchemaNode(
        id: 103, displayName: "Dynamic.Choice", displayNamePrefixLength: 8,
        kind: .structure(
            dataWordCount: 1, pointerCount: 1, preferredListEncoding: .inlineComposite,
            isGroup: false, discriminantCount: 2, discriminantOffset: 2,
            fields: [
                SchemaField(
                    name: "number", codeOrder: 0, discriminantValue: 0,
                    storage: .slot(offset: 0, type: .int32, defaultValue: .int32(0))),
                SchemaField(
                    name: "text", codeOrder: 1, discriminantValue: 1,
                    storage: .slot(offset: 0, type: .text, defaultValue: .text(""))),
            ]))
    let service = SchemaNode(
        id: 104, displayName: "Dynamic.Service", displayNamePrefixLength: 8,
        kind: .interface(methods: [], superclasses: []))
    let settings = SchemaNode(
        id: 105, displayName: "Dynamic.Root.settings", displayNamePrefixLength: 13,
        scopeID: 100,
        kind: .structure(
            dataWordCount: 4, pointerCount: 7, preferredListEncoding: .inlineComposite,
            isGroup: true, discriminantCount: 0, discriminantOffset: 0,
            fields: [
                SchemaField(
                    name: "enabled", codeOrder: 0,
                    storage: .slot(offset: 200, type: .bool, defaultValue: .bool(false)))
            ]))
    var loader = SchemaLoader()
    for node in [root, color, child, union, service, settings] { try loader.load(node) }
    try loader.finish()
    return loader.registry
}

private extension DynamicValue {
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var int32Value: Int32? { if case .int32(let value) = self { value } else { nil } }
    var uint16Value: UInt16? { if case .uint16(let value) = self { value } else { nil } }
    var uint32Value: UInt32? { if case .uint32(let value) = self { value } else { nil } }
    var textValue: String? { if case .text(let value) = self { value } else { nil } }
    var dataValue: [UInt8]? { if case .data(let value) = self { value } else { nil } }
    var listValue: DynamicListReader? { if case .list(let value) = self { value } else { nil } }
    var structValue: DynamicStructReader? {
        if case .structure(let value) = self { value } else { nil }
    }
    var capabilityValue: UInt32? {
        if case .capability(.some(let value)) = self { value } else { nil }
    }
}
