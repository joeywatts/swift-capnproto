import CapnProtoCompiler
import Testing

// Ported from capnproto 3a82de9b39736a2625f03c93b2b7c50642dd5b25:
// c++/src/capnp/compiler/type-id-test.c++.
@Test func generatedTypeIDsMatchPinnedCompiler() {
    #expect(TypeID.child(parent: 0xa93fc509624c72d9, name: "Node") == 0xe682ab4cf923a417)
    #expect(TypeID.child(parent: 0xe682ab4cf923a417, name: "NestedNode") == 0xdebf55bbfa0fc242)
    #expect(TypeID.group(parent: 0xe682ab4cf923a417, index: 7) == 0x9ea0b19b37fb4435)
    #expect(
        TypeID.method(parent: 0x88eb12a0e0af92b2, ordinal: 0, results: false) == 0xb874edc0d559b391)
    #expect(
        TypeID.method(parent: 0x88eb12a0e0af92b2, ordinal: 0, results: true) == 0xb04fcaddab714ba4)
    #expect(
        TypeID.method(parent: 0x88eb12a0e0af92b2, ordinal: 1, results: false) == 0xd044893357b42568)
    #expect(
        TypeID.method(parent: 0x88eb12a0e0af92b2, ordinal: 1, results: true) == 0x9bf141df4247d52f)
}
