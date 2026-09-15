import Testing

@testable import CapnProto

private func evolutionBytes(_ words: [UInt64]) -> [UInt8] {
    words.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> UInt64($0 * 8)) } }
}

private func evolutionStructPointer(
    offset: Int32 = 0, data: UInt16, pointers: UInt16
) -> UInt64 {
    (UInt64(UInt32(bitPattern: offset)) & 0x3fff_ffff) << 2
        | UInt64(data) << 32 | UInt64(pointers) << 48
}

private func evolutionListPointer(
    offset: Int32 = 0, size: ListElementSize, countOrWords: UInt32
) -> UInt64 {
    1 | (UInt64(UInt32(bitPattern: offset)) & 0x3fff_ffff) << 2
        | UInt64(size.rawValue) << 32 | UInt64(countOrWords & 0x1fff_ffff) << 35
}

// Reader half of compiler/evolution-test.c++: section truncation, larger
// structs, primitive/pointer-list upgrades, default XOR, and unknown tags.
@Test func schemaEvolutionReadRules() throws {
    let newerStruct = try MessageReader(segments: [
        evolutionBytes([evolutionStructPointer(data: 2, pointers: 0), 10, 20])
    ]).rootStruct()
    #expect(try newerStruct.integer(atByte: 0, as: UInt64.self) == 10)
    #expect(try newerStruct.integer(atByte: 8, as: UInt64.self) == 20)

    let olderStruct = try MessageReader(segments: [
        evolutionBytes([evolutionStructPointer(data: 1, pointers: 0), 10])
    ]).rootStruct()
    #expect(try olderStruct.integer(atByte: 8, as: UInt64.self, default: 99) == 99)

    let bytesList = try MessageReader(segments: [
        evolutionBytes([
            evolutionListPointer(size: .byte, countOrWords: 3), 0x0000_0000_0003_0201,
        ])
    ]).rootList()
    #expect(try bytesList.structElement(at: 1).integer(atByte: 0, as: UInt8.self) == 2)
    #expect(try bytesList.evolvedInteger(at: 2, as: UInt8.self) == 3)

    let bitList = try MessageReader(segments: [
        evolutionBytes([evolutionListPointer(size: .bit, countOrWords: 2), 2])
    ]).rootList()
    #expect(try bitList.structElement(at: 1).bool(atBit: 0))

    // The reverse direction: an old primitive-list reader sees field zero of
    // each struct in a newer inline-composite list.
    let composite = try MessageReader(segments: [
        evolutionBytes([
            evolutionListPointer(size: .inlineComposite, countOrWords: 2),
            evolutionStructPointer(offset: 2, data: 1, pointers: 0), 7, 8,
        ])
    ]).rootList()
    #expect(try composite.integer(at: 0, as: UInt16.self) == 7)
    #expect(try composite.integer(at: 1, as: UInt16.self) == 8)

    let compositePointers = try MessageReader(segments: [
        evolutionBytes([
            evolutionListPointer(size: .inlineComposite, countOrWords: 1),
            evolutionStructPointer(offset: 1, data: 0, pointers: 1),
            evolutionListPointer(size: .byte, countOrWords: 2), 0x61,
        ])
    ]).rootList()
    #expect(try compositePointers.pointerElement(at: 0).integer(at: 0, as: UInt8.self) == 0x61)

    let pointerList = try MessageReader(segments: [
        evolutionBytes([
            evolutionListPointer(size: .pointer, countOrWords: 1),
            evolutionListPointer(size: .byte, countOrWords: 2), 0x0000_0000_0000_0061,
        ])
    ]).rootList()
    let upgraded = try pointerList.structElement(at: 0)
    #expect(try upgraded.textField(at: 0).string == "a")

    let unknownValues = try MessageReader(segments: [
        evolutionBytes([evolutionStructPointer(data: 1, pointers: 0), 0xffff_1234])
    ]).rootStruct()
    #expect(try unknownValues.integer(atByte: 0, as: UInt16.self) == 0x1234)
    #expect(try unknownValues.discriminant(atByte: 2) == 0xffff)
    #expect(
        try unknownValues.integer(atByte: 4, as: UInt32.self, default: 0xa5a5_a5a5)
            == 0xa5a5_a5a5)

    let defaultFloat: Float = 1.25
    let actualFloat: Float = -4.5
    let storedFloat = UInt64(defaultFloat.bitPattern ^ actualFloat.bitPattern)
    let floatStruct = try MessageReader(segments: [
        evolutionBytes([evolutionStructPointer(data: 1, pointers: 0), storedFloat])
    ]).rootStruct()
    #expect(try floatStruct.float32(atByte: 0, default: defaultFloat) == actualFloat)
}
