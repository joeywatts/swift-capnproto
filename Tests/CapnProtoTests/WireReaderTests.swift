import Foundation
import Testing

@testable import CapnProto

private func bytes(_ words: [UInt64]) -> [UInt8] {
    words.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> UInt64($0 * 8)) } }
}

private func structPointer(offset: Int32 = 0, data: UInt16, pointers: UInt16) -> UInt64 {
    (UInt64(UInt32(bitPattern: offset)) & 0x3fff_ffff) << 2
        | UInt64(data) << 32 | UInt64(pointers) << 48
}

private func listPointer(
    offset: Int32 = 0, size: ListElementSize, countOrWords: UInt32
) -> UInt64 {
    1 | (UInt64(UInt32(bitPattern: offset)) & 0x3fff_ffff) << 2
        | UInt64(size.rawValue) << 32 | UInt64(countOrWords & 0x1fff_ffff) << 35
}

// Ported behavior: raw struct-pointer and truncation cases from layout-test.c++.
@Test func structPointersDefaultsAndTruncation() throws {
    let root = structPointer(data: 2, pointers: 1)
    let message = try MessageReader(segments: [bytes([root, 0xffff_ffff_ffff_ffff, 42, 0])])
    let value = try message.rootStruct()
    #expect(value.dataWordCount == 2)
    #expect(value.pointerCount == 1)
    #expect(try value.integer(atByte: 8, as: UInt64.self) == 42)
    #expect(try value.integer(atByte: 24, as: UInt32.self, default: 123) == 123)
    #expect(try value.bool(atBit: 0, default: true) == false)
    #expect(try value.structField(at: 9).dataWordCount == 0)
}

// Ported behavior: every raw list representation in layout-test.c++.
@Test(arguments: [
    (ListElementSize.byte, UInt64(4), bytes([0x0403_0201])),
    (.twoBytes, UInt64(3), bytes([0x0003_0002_0001])),
    (.fourBytes, UInt64(2), bytes([0x0000_0002_0000_0001])),
    (.eightBytes, UInt64(1), bytes([0x0102_0304_0506_0708])),
])
func primitiveLists(size: ListElementSize, count: UInt64, payload: [UInt8]) throws {
    let pointer = listPointer(size: size, countOrWords: UInt32(count))
    let list = try MessageReader(segments: [bytes([pointer]) + payload]).rootList()
    #expect(list.count == Int(count))
    switch size {
    case .byte: #expect(try list.integer(at: 0, as: UInt8.self) == 1)
    case .twoBytes: #expect(try list.integer(at: 1, as: UInt16.self) == 2)
    case .fourBytes: #expect(try list.integer(at: 1, as: UInt32.self) == 2)
    case .eightBytes: #expect(try list.integer(at: 0, as: UInt64.self) == 0x0102_0304_0506_0708)
    default: Issue.record("unexpected test element size")
    }
}

@Test func voidBitPointerAndInlineCompositeLists() throws {
    let empty = try MessageReader(segments: [bytes([listPointer(size: .void, countOrWords: 99)])])
        .rootList()
    #expect(empty.count == 99)

    let bits = try MessageReader(
        segments: [bytes([listPointer(size: .bit, countOrWords: 10), 0b10_1001])]
    ).rootList()
    #expect(try bits.bool(at: 0))
    #expect(try bits.bool(at: 1) == false)
    #expect(try bits.bool(at: 3))
    #expect(try bits.bool(at: 5))

    let pointerList = listPointer(size: .pointer, countOrWords: 1)
    let textPointer = listPointer(offset: 0, size: .byte, countOrWords: 3)
    let nested = try MessageReader(segments: [
        bytes([pointerList, textPointer, 0x0000_0000_0000_6968])
    ])
    .rootList().pointerElement(at: 0)
    #expect(try nested.integer(at: 0, as: UInt8.self) == 0x68)

    let composite = listPointer(size: .inlineComposite, countOrWords: 2)
    let tag = structPointer(offset: 2, data: 1, pointers: 0)
    let structs = try MessageReader(segments: [bytes([composite, tag, 11, 22])]).rootList()
    #expect(structs.count == 2)
    #expect(try structs.structElement(at: 0).integer(atByte: 0, as: UInt64.self) == 11)
    #expect(try structs.structElement(at: 1).integer(atByte: 0, as: UInt64.self) == 22)
}

@Test func floatingPointAndRootBlobReaders() throws {
    let floatBits = UInt64(Float(1.5).bitPattern) | UInt64(Float(-2.25).bitPattern) << 32
    let floats = try MessageReader(segments: [
        bytes([listPointer(size: .fourBytes, countOrWords: 2), floatBits])
    ]).rootList()
    #expect(try floats.float32(at: 0) == 1.5)
    #expect(try floats.float32(at: 1) == -2.25)

    let text = try MessageReader(segments: [
        bytes([listPointer(size: .byte, countOrWords: 3), 0x0000_0000_0000_6968])
    ])
    #expect(try text.rootText().string == "hi")
    #expect(try text.rootData().bytes == [0x68, 0x69, 0])
}

// C++-produced `flat` fixture from encoding-test.c++ provenance in manifest.json.
@Test func decodesPinnedCppFlatFixture() throws {
    let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fixture =
        testDirectory
        .appendingPathComponent("../InteropFixtures/generated/flat.bin").standardizedFileURL
    let segment = [UInt8](try Data(contentsOf: fixture))
    let root = try MessageReader(segments: [segment]).rootStruct()
    #expect(try root.textField(at: 0).string == "standard")
    #expect(try root.structField(at: 1).bool(atBit: 0, default: true))
    #expect(try root.structField(at: 1).integer(atByte: 4, as: Int32.self, default: -123) == -123)
    #expect(try root.textField(at: 2).string == "union")
    let outer = try root.listField(at: 3)
    #expect(outer.count == 2)
    let second = try outer.pointerElement(at: 1)
    #expect(second.count == 3)
    #expect(try second.integer(at: 2, as: UInt16.self) == 5)
}
