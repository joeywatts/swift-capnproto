import Testing

@testable import CapnProto

// Ported behavior: SmallStructLists and nested-list cases from encoding-test.c++.
@Test func compositeAndNestedListsRoundTrip() throws {
    let message = try MessageBuilder(firstSegmentWords: 4, allocationStrategy: .fixedSize)
    let root = try message.initRootStruct(dataWords: 0, pointerCount: 2)
    let structs = try root.initStructListField(at: 0, count: 3, dataWords: 1, pointerCount: 1)
    for index in 0..<3 {
        try structs[index].setInteger(atByte: 0, to: UInt32(index + 10))
        _ = try structs[index].setTextField(at: 0, to: "v\(index)")
    }
    let outer = try root.initListField(at: 1, elementSize: .pointer, count: 2)
    let first = try outer.initList(at: 0, elementSize: .twoBytes, count: 2)
    try first.setInteger(at: 0, to: UInt16(7))
    try first.setInteger(at: 1, to: UInt16(8))
    _ = try outer.initList(at: 1, elementSize: .void, count: 5)

    let read = try message.asReader().rootStruct()
    let structRead = try read.listField(at: 0)
    #expect(structRead.count == 3)
    #expect(try structRead.structElement(at: 2).integer(atByte: 0, as: UInt32.self) == 12)
    #expect(try structRead.structElement(at: 1).textField(at: 0).string == "v1")
    let nested = try read.listField(at: 1)
    #expect(try nested.pointerElement(at: 0).integer(at: 1, as: UInt16.self) == 8)
    #expect(try nested.pointerElement(at: 1).count == 5)
}

// Ported behavior: list-upgrade cases from layout-test.c++.
@Test func primitiveListUpgradePreservesElements() throws {
    let message = try MessageBuilder(firstSegmentWords: 32)
    let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
    let old = try root.initListField(at: 0, elementSize: .twoBytes, count: 3)
    try old.setInteger(at: 0, to: UInt16(100))
    try old.setInteger(at: 1, to: UInt16(200))
    try old.setInteger(at: 2, to: UInt16(300))
    let upgraded = try old.upgradeToStructList(dataWords: 1, pointerCount: 1)
    _ = try upgraded[1].setTextField(at: 0, to: "upgraded")

    let list = try message.asReader().rootStruct().listField(at: 0)
    #expect(try list.structElement(at: 0).integer(atByte: 0, as: UInt16.self) == 100)
    #expect(try list.structElement(at: 1).integer(atByte: 0, as: UInt16.self) == 200)
    #expect(try list.structElement(at: 2).integer(atByte: 0, as: UInt16.self) == 300)
    #expect(try list.structElement(at: 1).textField(at: 0).string == "upgraded")
}

@Test func pointerAndCompositeListUpgradesPreserveValues() throws {
    let message = try MessageBuilder(firstSegmentWords: 64)
    let root = try message.initRootStruct(dataWords: 0, pointerCount: 2)
    let pointers = try root.initListField(at: 0, elementSize: .pointer, count: 2)
    _ = try pointers.initStruct(at: 0, dataWords: 1, pointerCount: 0)
    let second = try pointers.initStruct(at: 1, dataWords: 1, pointerCount: 0)
    try second.setInteger(atByte: 0, to: UInt64(99))
    let pointerUpgrade = try pointers.upgradeToStructList(dataWords: 0, pointerCount: 1)
    #expect(try pointerUpgrade[1].pointerCount == 1)

    let structs = try root.initStructListField(at: 1, count: 2, dataWords: 1, pointerCount: 1)
    try structs[0].setInteger(atByte: 0, to: UInt64(55))
    _ = try structs[0].setTextField(at: 0, to: "kept")
    let widened = try structs.upgrade(dataWords: 2, pointerCount: 2)
    try widened[1].setInteger(atByte: 8, to: UInt64(77))

    let read = try message.asReader().rootStruct()
    #expect(
        try read.listField(at: 0).structElement(at: 1).structField(at: 0)
            .integer(atByte: 0, as: UInt64.self) == 99)
    let widenedRead = try read.listField(at: 1)
    #expect(try widenedRead.structElement(at: 0).integer(atByte: 0, as: UInt64.self) == 55)
    #expect(try widenedRead.structElement(at: 0).textField(at: 0).string == "kept")
    #expect(try widenedRead.structElement(at: 1).integer(atByte: 8, as: UInt64.self) == 77)
}

// Layout-sensitive inline-composite vector matching the wire layout asserted by
// encoding-test.c++'s UnionLayout/SmallStructLists coverage.
@Test func inlineCompositeLayoutIsByteExact() throws {
    let message = try MessageBuilder(firstSegmentWords: 8)
    let list = try message.initRootStructList(count: 2, dataWords: 1, pointerCount: 0)
    try list[0].setInteger(atByte: 0, to: UInt64(11))
    try list[1].setInteger(atByte: 0, to: UInt64(22))
    let words = try stride(from: 0, to: message.segments[0].count, by: 8).map {
        try LittleEndian.loadInteger(UInt64.self, from: message.segments[0], at: $0)
    }
    #expect(words == [0x0000_0017_0000_0001, 0x0000_0001_0000_0008, 11, 22])
}

// Ported behavior: Groups, InterleavedGroups, Unions, UnionLayout,
// UnnamedUnion, and UnionDefault from encoding-test.c++.
@Test func groupsAndUnionsClearOnlyOwnedStorageAndPreserveUnknownTags() throws {
    let message = try MessageBuilder(firstSegmentWords: 16)
    let root = try message.initRootStruct(dataWords: 2, pointerCount: 2)
    try root.setInteger(atByte: 0, to: UInt32.max)
    try root.setInteger(atByte: 4, to: UInt32.max)
    try root.setInteger(atByte: 8, to: UInt32.max)
    _ = try root.setTextField(at: 0, to: "old member")
    _ = try root.setTextField(at: 1, to: "other group")

    try root.selectUnion(
        discriminant: 0xffff, atByte: 6, clearingData: [0..<4], clearingPointers: [0])

    let read = try message.asReader().rootStruct()
    #expect(try read.integer(atByte: 0, as: UInt32.self) == 0)
    #expect(try read.discriminant(atByte: 6) == 0xffff)
    #expect(try read.integer(atByte: 8, as: UInt32.self) == UInt32.max)
    #expect(try read.dataField(at: 0).isNull)
    #expect(try read.textField(at: 1).string == "other group")
}
