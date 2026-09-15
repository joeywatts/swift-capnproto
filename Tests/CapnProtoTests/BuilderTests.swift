import Testing

@testable import CapnProto

// Ported behavior: Encoding.AllTypes and defaults from encoding-test.c++.
@Test func structScalarsDefaultsAndNestedFieldsRoundTrip() throws {
    let message = try MessageBuilder(firstSegmentWords: 32)
    let root = try message.initRootStruct(dataWords: 3, pointerCount: 2)
    try root.setBool(atBit: 0, to: true, default: true)
    try root.setInteger(atByte: 4, to: Int32(-123), default: -123)
    try root.setInteger(atByte: 8, to: UInt64.max)
    try root.setFloat32(atByte: 16, to: 1.5)
    try root.setFloat64(atByte: 16, to: -2.25)
    let child = try root.initStructField(at: 0, dataWords: 1, pointerCount: 0)
    try child.setInteger(atByte: 0, to: UInt16(42))
    _ = try root.setTextField(at: 1, to: "hello")

    let read = try message.asReader().rootStruct()
    #expect(try read.bool(atBit: 0, default: true))
    #expect(try read.integer(atByte: 4, as: Int32.self, default: -123) == -123)
    #expect(try read.integer(atByte: 8, as: UInt64.self) == UInt64.max)
    #expect(try read.float64(atByte: 16) == -2.25)
    #expect(try read.structField(at: 0).integer(atByte: 0, as: UInt16.self) == 42)
    #expect(try read.textField(at: 1).string == "hello")
    #expect(try root.hasPointer(at: 0))
    try root.clearPointer(at: 0)
    #expect(try root.hasPointer(at: 0) == false)
}

// Ported behavior: primitive lists, empty lists, and bit packing from encoding-test.c++.
@Test func primitiveAndBitListsRoundTrip() throws {
    let message = try MessageBuilder(firstSegmentWords: 16)
    let root = try message.initRootStruct(dataWords: 0, pointerCount: 3)
    let integers = try root.initListField(at: 0, elementSize: .twoBytes, count: 3)
    try integers.setInteger(at: 0, to: UInt16(1))
    try integers.setInteger(at: 1, to: UInt16.max)
    try integers.setInteger(at: 2, to: UInt16(9))
    let bits = try root.initListField(at: 1, elementSize: .bit, count: 10)
    try bits.setBool(at: 0, to: true)
    try bits.setBool(at: 9, to: true)
    _ = try root.initListField(at: 2, elementSize: .byte, count: 0)

    let read = try message.asReader().rootStruct()
    #expect(try read.listField(at: 0).integer(at: 1, as: UInt16.self) == .max)
    #expect(try read.listField(at: 1).bool(at: 0))
    #expect(try read.listField(at: 1).bool(at: 8) == false)
    #expect(try read.listField(at: 1).bool(at: 9))
    #expect(try read.listField(at: 2).count == 0)
    #expect(try root.hasPointer(at: 2))
}

// Ported behavior: blobs and terminators from blob-test.c++.
@Test func dataAndTextBuildersPreserveBytesAndTerminators() throws {
    let message = try MessageBuilder(firstSegmentWords: 2, allocationStrategy: .fixedSize)
    let root = try message.initRootStruct(dataWords: 0, pointerCount: 2)
    _ = try root.setDataField(at: 0, to: [0, 1, 0xff])
    _ = try root.setTextField(at: 1, to: "hé")

    let read = try message.asReader().rootStruct()
    #expect(try read.dataField(at: 0).bytes == [0, 1, 0xff])
    #expect(try read.textField(at: 1).string == "hé")
    #expect(message.segmentCount > 1)
}

@Test func builderBoundsAndTypeErrorsAreDeterministic() throws {
    let message = try MessageBuilder(firstSegmentWords: 4)
    let root = try message.initRootStruct(dataWords: 1, pointerCount: 1)
    #expect(throws: CapnProtoError.indexOutOfBounds(index: 8, count: 8)) {
        try root.setInteger(atByte: 8, to: UInt8(1))
    }
    let list = try root.initListField(at: 0, elementSize: .byte, count: 1)
    #expect(throws: CapnProtoError.typeMismatch(expected: "twoBytes list", actual: "byte")) {
        try list.setInteger(at: 0, to: UInt16(1))
    }
}
