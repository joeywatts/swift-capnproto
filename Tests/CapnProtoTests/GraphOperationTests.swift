import CapnProtoTestSupport
import Testing

@testable import CapnProto

private func makeGraph(firstSegmentWords: Int = 8) throws -> (MessageBuilder, StructBuilder) {
    let message = try MessageBuilder(
        firstSegmentWords: firstSegmentWords, allocationStrategy: .fixedSize)
    let root = try message.initRootStruct(dataWords: 1, pointerCount: 2)
    try root.setInteger(atByte: 0, to: UInt64(7))
    let child = try root.initStructField(at: 0, dataWords: 1, pointerCount: 1)
    try child.setInteger(atByte: 0, to: UInt64(9))
    _ = try child.setTextField(at: 0, to: "child")
    return (message, root)
}

// Ported behavior: cross-message copy and independence cases from layout-test.c++.
@Test func crossMessageDeepCopyIsIndependentAndHandlesFarPointers() throws {
    let (source, sourceRoot) = try makeGraph(firstSegmentWords: 2)
    let destination = try MessageBuilder(firstSegmentWords: 2, allocationStrategy: .fixedSize)
    _ = try destination.setRoot(copying: source.asReader().rootStruct())
    try sourceRoot.clearPointer(at: 0)

    let copied = try destination.asReader().rootStruct()
    #expect(try copied.integer(atByte: 0, as: UInt64.self) == 7)
    #expect(try copied.structField(at: 0).integer(atByte: 0, as: UInt64.self) == 9)
    #expect(try copied.structField(at: 0).textField(at: 0).string == "child")
    #expect(try source.asReader().rootStruct().structField(at: 0).dataWordCount == 0)
}

// Ported behavior: disown/adopt constraints from orphan-test.c++.
@Test func orphanIsSingleUseAndRestrictedToItsArena() throws {
    let (message, root) = try makeGraph()
    let orphan = try root.disownPointer(at: 0)
    #expect(try root.hasPointer(at: 0) == false)
    try root.adopt(orphan, at: 1)
    #expect(
        try message.asReader().rootStruct().structField(at: 1)
            .integer(atByte: 0, as: UInt64.self) == 9)
    #expect(throws: CapnProtoError.orphanAlreadyAdopted) { try root.adopt(orphan, at: 0) }

    let other = try MessageBuilder()
    let otherRoot = try other.initRootStruct(dataWords: 0, pointerCount: 1)
    #expect(throws: CapnProtoError.orphanArenaMismatch) {
        try otherRoot.adopt(orphan, at: 0)
    }
}

// Recursive clearing uses an explicit work stack and must not overflow Swift's call stack.
@Test func recursivelyClearingDeepGraphDoesNotUseCallStack() throws {
    let message = try MessageBuilder(firstSegmentWords: 20_000)
    let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
    var current = root
    for _ in 0..<2_000 {
        current = try current.initStructField(at: 0, dataWords: 0, pointerCount: 1)
    }
    try root.clearPointer(at: 0)
    #expect(try root.hasPointer(at: 0) == false)
}

@Test func copiedGraphsRemainIndependentAcrossSeededValues() throws {
    var generator = SplitMix64(seed: 0x2_4c0f_f33)
    for _ in 0..<100 {
        let value = generator.next()
        let source = try MessageBuilder(firstSegmentWords: 4)
        let sourceRoot = try source.initRootStruct(dataWords: 1, pointerCount: 1)
        try sourceRoot.setInteger(atByte: 0, to: value)
        _ = try sourceRoot.setTextField(at: 0, to: String(value, radix: 16))
        let destination = try MessageBuilder(firstSegmentWords: 4)
        _ = try destination.setRoot(copying: source.asReader().rootStruct())

        try sourceRoot.setInteger(atByte: 0, to: ~value)
        try sourceRoot.clearPointer(at: 0)
        let copied = try destination.asReader().rootStruct()
        #expect(try copied.integer(atByte: 0, as: UInt64.self) == value)
        #expect(try copied.textField(at: 0).string == String(value, radix: 16))
    }
}
