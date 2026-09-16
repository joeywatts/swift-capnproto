import CapnProtoCompiler
import Foundation
import Testing

@Test func parserCoversDeclarationsTypesValuesGroupsUnionsGenericsAndInterfaces() throws {
    let source = SourceFile(
        name: "all.capnp",
        text: """
            @0x8123456789abcdef;
            using Base = import "base.capnp";
            const answer :UInt32 = 42;
            annotation note @0x923456789abcdef1 :Text (field, struct);
            struct Box(T) {
              value @0 :T;
              metadata :group { label @1 :Text = "hi"; }
              union { number @2 :Int32; text @3 :Text; }
              enum Kind { first @0; second @1; }
            }
            interface Service extends(Base.Service) {
              call @0 (box :Box(Text)) -> (result :List(UInt16));
              push @1 (data :Data) -> stream;
            }
            """)
    let result = CapnProtoParser().parse(source)
    #expect(result.diagnostics.isEmpty)
    #expect(result.file.id == 0x8123456789abcdef)
    #expect(result.file.declarations.count == 5)
    guard case .structure(let box) = result.file.declarations[3] else {
        Issue.record("expected struct"); return
    }
    #expect(box.parameters == ["T"])
    #expect(box.members.count == 4)
    guard case .interface(let service) = result.file.declarations[4] else {
        Issue.record("expected interface"); return
    }
    #expect(service.superclasses.count == 1)
    #expect(service.members.count == 2)
}

@Test func parserRecoversAndReportsMultipleBoundedErrors() {
    let source = SourceFile(
        name: "broken.capnp",
        text: """
            struct { bad; stillBad @999999 :Missing; }
            enum E { nope; okay @1; }
            mystery Thing;
            """)
    let result = CapnProtoParser().parse(source)
    #expect(result.diagnostics.count >= 3)
    #expect(
        result.diagnostics.allSatisfy {
            $0.range.startByte >= 0 && $0.range.endByte >= $0.range.startByte
                && $0.range.endByte <= source.bytes.count
        })
}

@Test(arguments: [
    "advanced.capnp", "import-base.capnp", "import-user.capnp", "interfaces.capnp",
    "keywords.capnp",
])
func parserAcceptsProjectCompilerFixtures(_ name: String) throws {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    let source = SourceFile(name: name, bytes: Array(try Data(contentsOf: url)))
    let result = CapnProtoParser().parse(source)
    #expect(result.diagnostics.isEmpty)
}

@Test func parserAcceptsPinnedUpstreamSchemas() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appending(path: "Tests/Upstream/capnproto/c++/src/capnp")
    for name in [
        "c++.capnp", "rpc-twoparty.capnp", "rpc.capnp", "schema.capnp",
        "test-import.capnp", "test-import2.capnp", "test.capnp",
    ] {
        let url = root.appending(path: name)
        let source = SourceFile(name: name, bytes: [UInt8](try Data(contentsOf: url)))
        let result = CapnProtoParser().parse(source)
        #expect(result.diagnostics.isEmpty, "\(name): \(result.diagnostics)")
    }
}
