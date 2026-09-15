import Foundation

public struct StructReader {
    let state: ReaderState
    let segment: Int
    let dataBitStart: Int
    let dataBitCount: Int
    public let dataWordCount: Int
    let pointerStart: Int
    public let pointerCount: Int
    let depth: Int

    init(
        state: ReaderState, segment: Int, dataBitStart: Int, dataBitCount: Int,
        pointerStart: Int, pointerWords: Int, depth: Int
    ) {
        self.state = state
        self.segment = segment
        self.dataBitStart = dataBitStart
        self.dataBitCount = dataBitCount
        dataWordCount = dataBitCount / 64
        self.pointerStart = pointerStart
        pointerCount = pointerWords
        self.depth = depth
    }

    static func empty(state: ReaderState, depth: Int) -> StructReader {
        StructReader(
            state: state, segment: 0, dataBitStart: 0, dataBitCount: 0,
            pointerStart: 0, pointerWords: 0, depth: depth
        )
    }

    public func bool(atBit offset: Int, default defaultValue: Bool = false) throws -> Bool {
        guard offset >= 0 else { throw CapnProtoError.arithmeticOverflow }
        guard offset < dataBitCount else { return defaultValue }
        let absoluteBit = try checkedAdd(dataBitStart, offset)
        let byte = state.segments[segment][absoluteBit / 8]
        return ((byte >> UInt8(absoluteBit % 8)) & 1 != 0) != defaultValue
    }

    public func integer<T: FixedWidthInteger>(
        atByte offset: Int,
        as type: T.Type = T.self,
        default defaultValue: T = 0
    ) throws -> T {
        guard offset >= 0 else { throw CapnProtoError.arithmeticOverflow }
        let width = MemoryLayout<T>.size
        guard dataBitStart.isMultiple(of: 8) else {
            throw CapnProtoError.typeMismatch(expected: "byte-aligned data", actual: "bit field")
        }
        let requestedBits = try checkedMultiply(try checkedAdd(offset, width), 8)
        guard requestedBits <= dataBitCount else { return defaultValue }
        let byteStart = try checkedAdd(dataBitStart / 8, offset)
        let stored = try LittleEndian.loadInteger(
            T.self, from: state.segments[segment], at: byteStart)
        return stored ^ defaultValue
    }

    public func float32(atByte offset: Int, default defaultValue: Float = 0) throws -> Float {
        let bits = try integer(
            atByte: offset, as: UInt32.self, default: defaultValue.bitPattern)
        return Float(bitPattern: bits)
    }

    public func float64(atByte offset: Int, default defaultValue: Double = 0) throws -> Double {
        let bits = try integer(
            atByte: offset, as: UInt64.self, default: defaultValue.bitPattern)
        return Double(bitPattern: bits)
    }

    public func discriminant(atByte offset: Int) throws -> UInt16 {
        try integer(atByte: offset, as: UInt16.self)
    }

    public func structField(at index: Int) throws -> StructReader {
        try pointer(at: index).asStruct(depth: depth + 1)
    }

    public func listField(at index: Int) throws -> ListReader {
        try pointer(at: index).asList(depth: depth + 1)
    }

    public func dataField(at index: Int) throws -> DataReader {
        let list = try listField(at: index)
        guard list.elementSize == .byte || list.isNull else {
            throw CapnProtoError.typeMismatch(expected: "byte list", actual: "\(list.elementSize)")
        }
        return DataReader(list: list)
    }

    public func textField(at index: Int) throws -> TextReader {
        let data = try dataField(at: index)
        if data.isNull { return TextReader(data: data) }
        guard data.count > 0, try data.byte(at: data.count - 1) == 0 else {
            throw CapnProtoError.invalidText
        }
        return TextReader(data: data)
    }

    private func pointer(at index: Int) throws -> ResolvedPointer {
        guard index >= 0 else {
            throw CapnProtoError.indexOutOfBounds(index: index, count: pointerCount)
        }
        if index >= pointerCount {
            return ResolvedPointer(
                state: state, segment: segment, pointerIndex: 0, raw: 0, targetOverride: nil)
        }
        return try resolvePointer(
            state: state, segment: segment, pointerIndex: try checkedAdd(pointerStart, index)
        )
    }
}

public struct ListReader {
    let state: ReaderState
    let segment: Int
    let startWord: Int
    public let elementSize: ListElementSize
    public let count: Int
    let dataWordsPerElement: Int
    let pointerWordsPerElement: Int
    let depth: Int
    public let isNull: Bool

    static func empty(state: ReaderState, depth: Int) -> ListReader {
        ListReader(
            state: state, segment: 0, startWord: 0, elementSize: .void, count: 0,
            dataWordsPerElement: 0, pointerWordsPerElement: 0, depth: depth, isNull: true
        )
    }

    public func bool(at index: Int) throws -> Bool {
        try checkIndex(index)
        if elementSize == .inlineComposite {
            guard dataWordsPerElement > 0 else { return false }
            let stride = try checkedAdd(dataWordsPerElement, pointerWordsPerElement)
            let word = try checkedAdd(startWord, try checkedMultiply(index, stride))
            return state.segments[segment][word * 8] & 1 != 0
        }
        guard elementSize == .bit else {
            throw CapnProtoError.typeMismatch(expected: "bit list", actual: "\(elementSize)")
        }
        let byteOffset = index / 8
        let absolute = try checkedAdd(try checkedMultiply(startWord, 8), byteOffset)
        return (state.segments[segment][absolute] & (1 << UInt8(index % 8))) != 0
    }

    public func integer<T: FixedWidthInteger>(at index: Int, as type: T.Type = T.self) throws -> T {
        try checkIndex(index)
        let expected: ListElementSize
        switch MemoryLayout<T>.size {
        case 1: expected = .byte
        case 2: expected = .twoBytes
        case 4: expected = .fourBytes
        case 8: expected = .eightBytes
        default: throw CapnProtoError.typeMismatch(expected: "wire scalar", actual: "\(T.self)")
        }
        if elementSize == .inlineComposite {
            guard dataWordsPerElement * 8 >= MemoryLayout<T>.size else { return 0 }
            let stride = try checkedAdd(dataWordsPerElement, pointerWordsPerElement)
            let word = try checkedAdd(startWord, try checkedMultiply(index, stride))
            return try LittleEndian.loadInteger(
                T.self, from: state.segments[segment], at: try checkedMultiply(word, 8))
        }
        guard elementSize == expected else {
            throw CapnProtoError.typeMismatch(
                expected: "\(expected) list", actual: "\(elementSize)")
        }
        let relative = try checkedMultiply(index, MemoryLayout<T>.size)
        let absolute = try checkedAdd(try checkedMultiply(startWord, 8), relative)
        return try LittleEndian.loadInteger(T.self, from: state.segments[segment], at: absolute)
    }

    public func float32(at index: Int) throws -> Float {
        Float(bitPattern: try integer(at: index, as: UInt32.self))
    }

    public func float64(at index: Int) throws -> Double {
        Double(bitPattern: try integer(at: index, as: UInt64.self))
    }

    public func pointerElement(at index: Int) throws -> ListReader {
        try pointer(at: index).asList(depth: depth + 1)
    }

    public func structPointerElement(at index: Int) throws -> StructReader {
        try pointer(at: index).asStruct(depth: depth + 1)
    }

    /// Reads an inline-composite element, or applies Cap'n Proto's primitive/pointer-list
    /// to struct-list evolution rule.
    public func structElement(at index: Int) throws -> StructReader {
        try checkIndex(index)
        try requireDepth(state, depth + 1)
        if elementSize == .inlineComposite {
            let stride = try checkedAdd(dataWordsPerElement, pointerWordsPerElement)
            let start = try checkedAdd(startWord, try checkedMultiply(index, stride))
            return StructReader(
                state: state, segment: segment,
                dataBitStart: try checkedMultiply(start, 64),
                dataBitCount: try checkedMultiply(dataWordsPerElement, 64),
                pointerStart: try checkedAdd(start, dataWordsPerElement),
                pointerWords: pointerWordsPerElement, depth: depth + 1
            )
        }
        if elementSize == .pointer {
            let pointerIndex = try checkedAdd(startWord, index)
            return StructReader(
                state: state, segment: segment, dataBitStart: 0, dataBitCount: 0,
                pointerStart: pointerIndex, pointerWords: 1, depth: depth + 1
            )
        }
        if elementSize == .void {
            return StructReader.empty(state: state, depth: depth + 1)
        }
        if elementSize == .bit {
            let startBit = try checkedAdd(try checkedMultiply(startWord, 64), index)
            return StructReader(
                state: state, segment: segment, dataBitStart: startBit, dataBitCount: 1,
                pointerStart: 0, pointerWords: 0, depth: depth + 1
            )
        }
        let byteWidth = elementSize.bitWidth! / 8
        let byteStart = try checkedAdd(
            try checkedMultiply(startWord, 8), try checkedMultiply(index, byteWidth))
        // Primitive elements become the low bytes of a one-word data section. An
        // unaligned element is represented by a narrow view and read through the
        // dedicated evolved scalar accessor below.
        return StructReader(
            state: state, segment: segment, dataBitStart: try checkedMultiply(byteStart, 8),
            dataBitCount: try checkedMultiply(byteWidth, 8), pointerStart: 0,
            pointerWords: 0, depth: depth + 1
        )
    }

    /// Reads field zero after a primitive-list to struct-list schema upgrade.
    public func evolvedInteger<T: FixedWidthInteger>(at index: Int, as type: T.Type = T.self) throws
        -> T
    {
        try checkIndex(index)
        guard elementSize != .inlineComposite, elementSize != .pointer,
            elementSize != .void, elementSize != .bit
        else {
            throw CapnProtoError.typeMismatch(expected: "primitive list", actual: "\(elementSize)")
        }
        guard elementSize.bitWidth == MemoryLayout<T>.size * 8 else {
            throw CapnProtoError.typeMismatch(expected: "\(T.self)", actual: "\(elementSize)")
        }
        let absolute = try checkedAdd(
            try checkedMultiply(startWord, 8), try checkedMultiply(index, MemoryLayout<T>.size)
        )
        return try LittleEndian.loadInteger(T.self, from: state.segments[segment], at: absolute)
    }

    private func pointer(at index: Int) throws -> ResolvedPointer {
        try checkIndex(index)
        if elementSize == .inlineComposite {
            guard pointerWordsPerElement > 0 else {
                return ResolvedPointer(
                    state: state, segment: segment, pointerIndex: 0, raw: 0,
                    targetOverride: nil)
            }
            let stride = try checkedAdd(dataWordsPerElement, pointerWordsPerElement)
            let element = try checkedAdd(startWord, try checkedMultiply(index, stride))
            return try resolvePointer(
                state: state, segment: segment,
                pointerIndex: try checkedAdd(element, dataWordsPerElement))
        }
        guard elementSize == .pointer else {
            throw CapnProtoError.typeMismatch(expected: "pointer list", actual: "\(elementSize)")
        }
        return try resolvePointer(state: state, segment: segment, pointerIndex: startWord + index)
    }

    private func checkIndex(_ index: Int) throws {
        guard index >= 0, index < count else {
            throw CapnProtoError.indexOutOfBounds(index: index, count: count)
        }
    }
}

public struct DataReader {
    private let list: ListReader
    init(list: ListReader) { self.list = list }
    public var count: Int { list.count }
    public var isNull: Bool { list.isNull }
    public func byte(at index: Int) throws -> UInt8 { try list.integer(at: index) }
    public var bytes: [UInt8] {
        let start = list.startWord * 8
        return Array(list.state.segments[list.segment][start..<(start + list.count)])
    }
}

public struct TextReader {
    private let data: DataReader
    init(data: DataReader) { self.data = data }
    public var utf8Bytes: [UInt8] { Array(data.bytes.dropLast()) }
    public var string: String? { String(bytes: utf8Bytes, encoding: .utf8) }
}
