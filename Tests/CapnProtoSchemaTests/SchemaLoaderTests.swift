import CapnProtoSchema
import Testing

// Ported behavior from capnproto@3a82de9b schema-loader-test.c++: incremental
// dependencies, upgrade/downgrade replacement, and invalid field offsets.
@Test func schemaLoaderValidatesAndReplacesNodes() throws {
    let field = SchemaField(
        name: "value", codeOrder: 0,
        storage: .slot(offset: 0, type: .uint64, defaultValue: .uint64(0)))
    let old = SchemaNode(
        id: 1, displayName: "Record",
        kind: .structure(
            dataWordCount: 1, pointerCount: 0, preferredListEncoding: .inlineComposite,
            isGroup: false, discriminantCount: 0, discriminantOffset: 0, fields: [field]))
    let extra = SchemaField(
        name: "extra", codeOrder: 1,
        storage: .slot(offset: 1, type: .uint64, defaultValue: .uint64(0)))
    let new = SchemaNode(
        id: 1, displayName: "Record",
        kind: .structure(
            dataWordCount: 2, pointerCount: 0, preferredListEncoding: .inlineComposite,
            isGroup: false, discriminantCount: 0, discriminantOffset: 0,
            fields: [field, extra]))

    var loader = SchemaLoader()
    try loader.load(old)
    try loader.load(new)
    try loader.load(old)
    #expect(loader.registry.schema(id: 1)?.field(named: "extra") != nil)
    #expect(SchemaLoader.compatibility(of: new, with: old).canReadExisting)

    let changedDefault = SchemaNode(
        id: 1, displayName: "Record",
        kind: .structure(
            dataWordCount: 1, pointerCount: 0, preferredListEncoding: .inlineComposite,
            isGroup: false, discriminantCount: 0, discriminantOffset: 0,
            fields: [
                SchemaField(
                    name: "value", codeOrder: 0,
                    storage: .slot(offset: 0, type: .uint64, defaultValue: .uint64(1)))
            ]))
    let changedCompatibility = SchemaLoader.compatibility(of: changedDefault, with: old)
    #expect(!changedCompatibility.canReadExisting)
    #expect(!changedCompatibility.canWriteExisting)

    let invalid = SchemaNode(
        id: 2, displayName: "Invalid",
        kind: .structure(
            dataWordCount: 1, pointerCount: 0, preferredListEncoding: .inlineComposite,
            isGroup: false, discriminantCount: 0, discriminantOffset: 0,
            fields: [
                SchemaField(
                    name: "bad", codeOrder: 0,
                    storage: .slot(
                        offset: UInt32.max, type: .uint64, defaultValue: .uint64(0)))
            ]))
    #expect(throws: SchemaError.self) { try loader.load(invalid) }
}
