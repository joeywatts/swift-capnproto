import CapnProtoCompiler
import Foundation
import Testing

@Test func resolverLoadsImportsGeneratesIDsAndResolvesAliases() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(
            path: "swift-capnproto-resolver-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = directory.appending(path: "base.capnp")
    let user = directory.appending(path: "user.capnp")
    try Data("@0x8123456789abcdef; struct Base { value @0 :UInt32; }".utf8).write(to: base)
    try Data(
        """
        @0x923456789abcdef1;
        using B = import "base.capnp";
        struct User { base @0 :B.Base; }
        """.utf8
    ).write(to: user)
    let schema = NativeSchemaCompiler().resolve(files: [user])
    #expect(schema.diagnostics.isEmpty)
    #expect(schema.files.count == 2)
    #expect(
        schema.nodes.contains {
            $0.qualifiedName == "Base"
                && $0.id == TypeID.child(parent: 0x8123456789abcdef, name: "Base")
        })
    #expect(
        schema.nodes.contains {
            $0.qualifiedName == "User"
                && $0.id == TypeID.child(parent: 0x923456789abcdef1, name: "User")
        })
}

@Test func resolverReportsMissingImportsUnknownNamesAndDuplicateIDsTogether() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "swift-capnproto-errors-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "bad.capnp")
    try Data(
        """
        @0x8123456789abcdef;
        using Missing = import "absent.capnp";
        using Loop = Loop;
        annotation fieldOnly @0xa3456789abcdef12 :Void (field);
        $unknown;
        struct A @0x923456789abcdef1 { field @0 :NoSuchType; }
        struct B @0x923456789abcdef1 $fieldOnly {}
        struct C { cycle @0 :Loop; }
        """.utf8
    ).write(to: file)
    let schema = NativeSchemaCompiler().resolve(files: [file])
    #expect(schema.diagnostics.contains { $0.message.contains("import not found") })
    #expect(schema.diagnostics.contains { $0.message.contains("unknown name") })
    #expect(schema.diagnostics.contains { $0.message.contains("duplicate node ID") })
    #expect(schema.diagnostics.contains { $0.message.contains("unknown annotation") })
    #expect(schema.diagnostics.contains { $0.message.contains("cannot be applied to struct") })
    #expect(schema.diagnostics.contains { $0.message.contains("alias cycle") })
}
