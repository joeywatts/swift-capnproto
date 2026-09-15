import Foundation

private enum PointerValue {
    case `struct`(dataWords: Int, pointerWords: Int)
    case list(size: ListElementSize, countOrWords: Int)

    func word(offset: Int) throws -> UInt64 {
        guard offset >= -(1 << 29), offset < (1 << 29) else {
            throw CapnProtoError.arithmeticOverflow
        }
        let encodedOffset = UInt64(UInt32(truncatingIfNeeded: offset)) & 0x3fff_ffff
        switch self {
        case let .struct(dataWords, pointerWords):
            guard dataWords <= 0xffff, pointerWords <= 0xffff else {
                throw CapnProtoError.arithmeticOverflow
            }
            return encodedOffset << 2 | UInt64(dataWords) << 32 | UInt64(pointerWords) << 48
        case let .list(size, countOrWords):
            guard countOrWords <= 0x1fff_ffff else { throw CapnProtoError.arithmeticOverflow }
            return 1 | encodedOffset << 2 | UInt64(size.rawValue) << 32
                | UInt64(countOrWords) << 35
        }
    }
}

private struct ObjectAllocation {
    let allocation: SegmentAllocation
    let objectStart: Int
}

extension BuilderArena {
    fileprivate func allocateObject(
        words: Int, fromPointerIn pointerSegment: Int, at pointerIndex: Int,
        pointerValue: PointerValue
    ) throws -> ObjectAllocation {
        if words <= segments[pointerSegment].capacityWords - segments[pointerSegment].usedWords {
            let allocation = try allocate(words: words, preferredSegment: pointerSegment)
            let offset = try checkedAdd(allocation.startWord, -pointerIndex - 1)
            try setWord(
                try pointerValue.word(offset: offset), segment: pointerSegment, index: pointerIndex)
            return ObjectAllocation(allocation: allocation, objectStart: allocation.startWord)
        }

        // A one-word landing pad precedes the object in the new segment.
        let allocation = try allocate(
            words: try checkedAdd(words, 1), preferredSegment: pointerSegment)
        let landing = allocation.startWord
        let objectStart = try checkedAdd(landing, 1)
        guard allocation.segmentID <= Int(UInt32.max), landing <= 0x1fff_ffff else {
            throw CapnProtoError.arithmeticOverflow
        }
        let far = UInt64(2) | UInt64(landing) << 3 | UInt64(allocation.segmentID) << 32
        try setWord(far, segment: pointerSegment, index: pointerIndex)
        try setWord(
            try pointerValue.word(offset: 0), segment: allocation.segmentID, index: landing)
        return ObjectAllocation(allocation: allocation, objectStart: objectStart)
    }
}

extension MessageBuilder {
    public func initRootStruct(dataWords: Int, pointerCount: Int) throws -> StructBuilder {
        try validateStructSize(dataWords: dataWords, pointerCount: pointerCount)
        try arena.setWord(0, segment: 0, index: 0)
        let total = try checkedAdd(dataWords, pointerCount)
        let object = try arena.allocateObject(
            words: total, fromPointerIn: 0, at: 0,
            pointerValue: .struct(dataWords: dataWords, pointerWords: pointerCount))
        return StructBuilder(
            arena: arena, segment: object.allocation.segmentID, dataStart: object.objectStart,
            dataWords: dataWords, pointerStart: object.objectStart + dataWords,
            pointerCount: pointerCount)
    }

    public func initRootList(elementSize: ListElementSize, count: Int) throws -> ListBuilder {
        try arena.setWord(0, segment: 0, index: 0)
        return try ListBuilder.initialize(
            arena: arena, pointerSegment: 0, pointerIndex: 0,
            elementSize: elementSize, count: count)
    }

    public func initRootStructList(count: Int, dataWords: Int, pointerCount: Int) throws
        -> StructListBuilder
    {
        try arena.setWord(0, segment: 0, index: 0)
        return try StructListBuilder.initialize(
            arena: arena, pointerSegment: 0, pointerIndex: 0, count: count,
            dataWords: dataWords, pointerCount: pointerCount)
    }

    public func initRootData(count: Int) throws -> DataBuilder {
        DataBuilder(list: try initRootList(elementSize: .byte, count: count))
    }

    public func setRootData(_ bytes: [UInt8]) throws -> DataBuilder {
        let result = try initRootData(count: bytes.count)
        try result.setBytes(bytes)
        return result
    }

    public func setRootText(_ text: String) throws -> TextBuilder {
        let utf8 = Array(text.utf8)
        let result = TextBuilder(
            data: try initRootData(count: try checkedAdd(utf8.count, 1)))
        try result.setUTF8(utf8)
        return result
    }
}

public struct StructBuilder {
    let arena: BuilderArena
    let segment: Int
    let dataStart: Int
    public let dataWordCount: Int
    let pointerStart: Int
    public let pointerCount: Int

    init(
        arena: BuilderArena, segment: Int, dataStart: Int, dataWords: Int,
        pointerStart: Int, pointerCount: Int
    ) {
        self.arena = arena
        self.segment = segment
        self.dataStart = dataStart
        dataWordCount = dataWords
        self.pointerStart = pointerStart
        self.pointerCount = pointerCount
    }

    public func setBool(atBit offset: Int, to value: Bool, default defaultValue: Bool = false)
        throws
    {
        guard offset >= 0, offset < dataWordCount * 64 else {
            throw CapnProtoError.indexOutOfBounds(index: offset, count: dataWordCount * 64)
        }
        let stored = value != defaultValue
        let byteOffset = try checkedAdd(dataStart * 8, offset / 8)
        try arena.withBytes(segment: segment) { bytes in
            let mask = UInt8(1 << UInt8(offset % 8))
            if stored { bytes[byteOffset] |= mask } else { bytes[byteOffset] &= ~mask }
        }
    }

    public func setInteger<T: FixedWidthInteger>(
        atByte offset: Int, to value: T, default defaultValue: T = 0
    ) throws {
        let width = MemoryLayout<T>.size
        guard offset >= 0, offset <= dataWordCount * 8 - width else {
            throw CapnProtoError.indexOutOfBounds(index: offset, count: dataWordCount * 8)
        }
        try arena.withBytes(segment: segment) { bytes in
            try LittleEndian.storeInteger(
                value ^ defaultValue, to: &bytes, at: dataStart * 8 + offset)
        }
    }

    public func setFloat32(atByte offset: Int, to value: Float, default defaultValue: Float = 0)
        throws
    {
        try setInteger(atByte: offset, to: value.bitPattern, default: defaultValue.bitPattern)
    }

    public func setFloat64(atByte offset: Int, to value: Double, default defaultValue: Double = 0)
        throws
    {
        try setInteger(atByte: offset, to: value.bitPattern, default: defaultValue.bitPattern)
    }

    public func hasPointer(at index: Int) throws -> Bool {
        try arena.word(segment: segment, index: try pointerIndex(index)) != 0
    }

    public func clearPointer(at index: Int) throws {
        try arena.setWord(0, segment: segment, index: try pointerIndex(index))
    }

    public func clearData(inByteRange range: Range<Int>) throws {
        guard range.lowerBound >= 0, range.upperBound <= dataWordCount * 8 else {
            throw CapnProtoError.indexOutOfBounds(
                index: range.upperBound, count: dataWordCount * 8)
        }
        try arena.withBytes(segment: segment) { bytes in
            let start = dataStart * 8 + range.lowerBound
            bytes.replaceSubrange(
                start..<(dataStart * 8 + range.upperBound),
                with: repeatElement(0, count: range.count))
        }
    }

    /// Clears the storage occupied by a group. Pointer indices need not be
    /// contiguous, which supports interleaved group layouts.
    public func clearGroup(dataByteRanges: [Range<Int>], pointerIndices: [Int]) throws {
        for range in dataByteRanges { try clearData(inByteRange: range) }
        for index in pointerIndices { try clearPointer(at: index) }
    }

    public func setDiscriminant(atByte offset: Int, to value: UInt16) throws {
        try setInteger(atByte: offset, to: value)
    }

    /// Selects a union member after zeroing storage owned by the previous member.
    /// Any UInt16 value is accepted so unknown discriminants can be preserved.
    public func selectUnion(
        discriminant value: UInt16, atByte offset: Int,
        clearingData dataByteRanges: [Range<Int>] = [],
        clearingPointers pointerIndices: [Int] = []
    ) throws {
        try clearGroup(dataByteRanges: dataByteRanges, pointerIndices: pointerIndices)
        try setDiscriminant(atByte: offset, to: value)
    }

    public func initStructField(at index: Int, dataWords: Int, pointerCount: Int) throws
        -> StructBuilder
    {
        try validateStructSize(dataWords: dataWords, pointerCount: pointerCount)
        let pointer = try pointerIndex(index)
        try arena.setWord(0, segment: segment, index: pointer)
        let object = try arena.allocateObject(
            words: try checkedAdd(dataWords, pointerCount), fromPointerIn: segment,
            at: pointer, pointerValue: .struct(dataWords: dataWords, pointerWords: pointerCount))
        return StructBuilder(
            arena: arena, segment: object.allocation.segmentID, dataStart: object.objectStart,
            dataWords: dataWords, pointerStart: object.objectStart + dataWords,
            pointerCount: pointerCount)
    }

    public func initListField(at index: Int, elementSize: ListElementSize, count: Int) throws
        -> ListBuilder
    {
        let pointer = try pointerIndex(index)
        try arena.setWord(0, segment: segment, index: pointer)
        return try ListBuilder.initialize(
            arena: arena, pointerSegment: segment, pointerIndex: pointer,
            elementSize: elementSize, count: count)
    }

    public func initStructListField(
        at index: Int, count: Int, dataWords: Int, pointerCount: Int
    ) throws -> StructListBuilder {
        let pointer = try pointerIndex(index)
        try arena.setWord(0, segment: segment, index: pointer)
        return try StructListBuilder.initialize(
            arena: arena, pointerSegment: segment, pointerIndex: pointer, count: count,
            dataWords: dataWords, pointerCount: pointerCount)
    }

    public func initDataField(at index: Int, count: Int) throws -> DataBuilder {
        DataBuilder(list: try initListField(at: index, elementSize: .byte, count: count))
    }

    public func setDataField(at index: Int, to bytes: [UInt8]) throws -> DataBuilder {
        let result = try initDataField(at: index, count: bytes.count)
        try result.setBytes(bytes)
        return result
    }

    public func setTextField(at index: Int, to text: String) throws -> TextBuilder {
        let utf8 = Array(text.utf8)
        let result = TextBuilder(
            data: try initDataField(at: index, count: try checkedAdd(utf8.count, 1)))
        try result.setUTF8(utf8)
        return result
    }

    func pointerIndex(_ index: Int) throws -> Int {
        guard index >= 0, index < pointerCount else {
            throw CapnProtoError.indexOutOfBounds(index: index, count: pointerCount)
        }
        return try checkedAdd(pointerStart, index)
    }
}

public struct ListBuilder {
    let arena: BuilderArena
    let segment: Int
    let startWord: Int
    public let elementSize: ListElementSize
    public let count: Int
    let pointerSegment: Int
    let pointerIndex: Int

    static func initialize(
        arena: BuilderArena, pointerSegment: Int, pointerIndex: Int,
        elementSize: ListElementSize, count: Int
    ) throws -> ListBuilder {
        guard count >= 0 else { throw CapnProtoError.arithmeticOverflow }
        guard elementSize != .inlineComposite else {
            throw CapnProtoError.typeMismatch(
                expected: "primitive or pointer element", actual: "inlineComposite")
        }
        let bits = try checkedMultiply(count, elementSize.bitWidth!)
        let words = try wordsForBytes(try checkedAdd(bits, 7) / 8)
        let object = try arena.allocateObject(
            words: words, fromPointerIn: pointerSegment, at: pointerIndex,
            pointerValue: .list(size: elementSize, countOrWords: count))
        return ListBuilder(
            arena: arena, segment: object.allocation.segmentID, startWord: object.objectStart,
            elementSize: elementSize, count: count, pointerSegment: pointerSegment,
            pointerIndex: pointerIndex)
    }

    public func setBool(at index: Int, to value: Bool) throws {
        try check(index)
        guard elementSize == .bit else {
            throw CapnProtoError.typeMismatch(expected: "bit list", actual: "\(elementSize)")
        }
        let byteIndex = startWord * 8 + index / 8
        try arena.withBytes(segment: segment) { bytes in
            let mask = UInt8(1 << UInt8(index % 8))
            if value { bytes[byteIndex] |= mask } else { bytes[byteIndex] &= ~mask }
        }
    }

    public func setInteger<T: FixedWidthInteger>(at index: Int, to value: T) throws {
        try check(index)
        let expected: ListElementSize
        switch MemoryLayout<T>.size {
        case 1: expected = .byte
        case 2: expected = .twoBytes
        case 4: expected = .fourBytes
        case 8: expected = .eightBytes
        default: throw CapnProtoError.typeMismatch(expected: "wire scalar", actual: "\(T.self)")
        }
        guard elementSize == expected else {
            throw CapnProtoError.typeMismatch(
                expected: "\(expected) list", actual: "\(elementSize)")
        }
        try arena.withBytes(segment: segment) { bytes in
            try LittleEndian.storeInteger(
                value, to: &bytes, at: startWord * 8 + index * MemoryLayout<T>.size)
        }
    }

    public func setFloat32(at index: Int, to value: Float) throws {
        try setInteger(at: index, to: value.bitPattern)
    }

    public func setFloat64(at index: Int, to value: Double) throws {
        try setInteger(at: index, to: value.bitPattern)
    }

    public func initList(
        at index: Int, elementSize childElementSize: ListElementSize, count childCount: Int
    ) throws -> ListBuilder {
        let pointer = try elementPointerIndex(index)
        try arena.setWord(0, segment: segment, index: pointer)
        return try ListBuilder.initialize(
            arena: arena, pointerSegment: segment, pointerIndex: pointer,
            elementSize: childElementSize, count: childCount)
    }

    public func initStruct(at index: Int, dataWords: Int, pointerCount: Int) throws
        -> StructBuilder
    {
        try validateStructSize(dataWords: dataWords, pointerCount: pointerCount)
        let pointer = try elementPointerIndex(index)
        try arena.setWord(0, segment: segment, index: pointer)
        let object = try arena.allocateObject(
            words: try checkedAdd(dataWords, pointerCount), fromPointerIn: segment, at: pointer,
            pointerValue: .struct(dataWords: dataWords, pointerWords: pointerCount))
        return StructBuilder(
            arena: arena, segment: object.allocation.segmentID, dataStart: object.objectStart,
            dataWords: dataWords, pointerStart: object.objectStart + dataWords,
            pointerCount: pointerCount)
    }

    /// Applies the wire-format primitive-list to struct-list upgrade rule while
    /// preserving each primitive as field zero of the corresponding struct.
    public func upgradeToStructList(dataWords: Int, pointerCount: Int) throws -> StructListBuilder {
        guard elementSize != .pointer, elementSize != .inlineComposite else {
            throw CapnProtoError.typeMismatch(expected: "primitive list", actual: "\(elementSize)")
        }
        guard dataWords > 0 || elementSize == .void else {
            throw CapnProtoError.typeMismatch(
                expected: "data-bearing struct", actual: "empty struct")
        }
        let oldBytes = arena.segments[segment].bytes
        let upgraded = try StructListBuilder.initialize(
            arena: arena, pointerSegment: pointerSegment, pointerIndex: pointerIndex, count: count,
            dataWords: dataWords, pointerCount: pointerCount)
        if elementSize == .void { return upgraded }
        if elementSize == .bit {
            for index in 0..<count {
                let byte = oldBytes[startWord * 8 + index / 8]
                try upgraded[index].setBool(atBit: 0, to: byte & (1 << UInt8(index % 8)) != 0)
            }
            return upgraded
        }
        let width = elementSize.bitWidth! / 8
        for index in 0..<count {
            let source = startWord * 8 + index * width
            try arena.withBytes(segment: upgraded.segment) { destination in
                let target = (upgraded.elementsStart + index * upgraded.wordsPerElement) * 8
                destination.replaceSubrange(
                    target..<(target + width), with: oldBytes[source..<(source + width)])
            }
        }
        return upgraded
    }

    private func elementPointerIndex(_ index: Int) throws -> Int {
        try check(index)
        guard elementSize == .pointer else {
            throw CapnProtoError.typeMismatch(expected: "pointer list", actual: "\(elementSize)")
        }
        return startWord + index
    }

    func check(_ index: Int) throws {
        guard index >= 0, index < count else {
            throw CapnProtoError.indexOutOfBounds(index: index, count: count)
        }
    }
}

public struct StructListBuilder {
    let arena: BuilderArena
    let segment: Int
    let elementsStart: Int
    public let count: Int
    public let dataWordCount: Int
    public let pointerCount: Int

    var wordsPerElement: Int { dataWordCount + pointerCount }

    static func initialize(
        arena: BuilderArena, pointerSegment: Int, pointerIndex: Int, count: Int,
        dataWords: Int, pointerCount: Int
    ) throws -> StructListBuilder {
        guard count >= 0 else { throw CapnProtoError.arithmeticOverflow }
        try validateStructSize(dataWords: dataWords, pointerCount: pointerCount)
        let stride = try checkedAdd(dataWords, pointerCount)
        let contentWords = try checkedMultiply(count, stride)
        let object = try arena.allocateObject(
            words: try checkedAdd(contentWords, 1), fromPointerIn: pointerSegment, at: pointerIndex,
            pointerValue: .list(size: .inlineComposite, countOrWords: contentWords))
        let tag = try PointerValue.struct(dataWords: dataWords, pointerWords: pointerCount)
            .word(offset: count)
        try arena.setWord(tag, segment: object.allocation.segmentID, index: object.objectStart)
        return StructListBuilder(
            arena: arena, segment: object.allocation.segmentID,
            elementsStart: object.objectStart + 1, count: count,
            dataWordCount: dataWords, pointerCount: pointerCount)
    }

    public subscript(index: Int) -> StructBuilder {
        get throws {
            guard index >= 0, index < count else {
                throw CapnProtoError.indexOutOfBounds(index: index, count: count)
            }
            let start = try checkedAdd(elementsStart, try checkedMultiply(index, wordsPerElement))
            return StructBuilder(
                arena: arena, segment: segment, dataStart: start, dataWords: dataWordCount,
                pointerStart: start + dataWordCount, pointerCount: pointerCount)
        }
    }
}

public struct DataBuilder {
    let list: ListBuilder
    public var count: Int { list.count }

    public func setByte(at index: Int, to value: UInt8) throws {
        try list.setInteger(at: index, to: value)
    }

    public func setBytes(_ bytes: [UInt8]) throws {
        guard bytes.count == count else {
            throw CapnProtoError.typeMismatch(
                expected: "\(count) bytes", actual: "\(bytes.count) bytes")
        }
        try list.arena.withBytes(segment: list.segment) { storage in
            storage.replaceSubrange(
                (list.startWord * 8)..<(list.startWord * 8 + count), with: bytes)
        }
    }
}

public struct TextBuilder {
    let data: DataBuilder
    public var utf8Count: Int { max(0, data.count - 1) }

    fileprivate func setUTF8(_ bytes: [UInt8]) throws {
        guard data.count == bytes.count + 1 else { throw CapnProtoError.invalidText }
        try data.list.arena.withBytes(segment: data.list.segment) { storage in
            let start = data.list.startWord * 8
            storage.replaceSubrange(start..<(start + bytes.count), with: bytes)
            storage[start + bytes.count] = 0
        }
    }
}

private func validateStructSize(dataWords: Int, pointerCount: Int) throws {
    guard dataWords >= 0, pointerCount >= 0, dataWords <= 0xffff, pointerCount <= 0xffff else {
        throw CapnProtoError.arithmeticOverflow
    }
}
