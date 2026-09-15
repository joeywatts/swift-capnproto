public enum ListElementSize: UInt8, CaseIterable, Sendable {
    case void = 0
    case bit = 1
    case byte = 2
    case twoBytes = 3
    case fourBytes = 4
    case eightBytes = 5
    case pointer = 6
    case inlineComposite = 7

    var bitWidth: Int? {
        switch self {
        case .void: 0
        case .bit: 1
        case .byte: 8
        case .twoBytes: 16
        case .fourBytes: 32
        case .eightBytes, .pointer: 64
        case .inlineComposite: nil
        }
    }
}

struct ResolvedPointer {
    let state: ReaderState
    let segment: Int
    let pointerIndex: Int
    let raw: UInt64
    let targetOverride: Int?

    var kind: UInt8 { UInt8(raw & 3) }
    var isNull: Bool { raw == 0 }

    func target() throws -> Int {
        if let targetOverride { return targetOverride }
        let offset = signExtend((raw >> 2) & 0x3fff_ffff, width: 30)
        guard let relative = Int(exactly: offset) else { throw CapnProtoError.arithmeticOverflow }
        return try checkedAdd(try checkedAdd(pointerIndex, 1), relative)
    }

    func asStruct(depth: Int) throws -> StructReader {
        if isNull { return StructReader.empty(state: state, depth: depth) }
        guard kind == 0 else {
            throw CapnProtoError.typeMismatch(expected: "struct", actual: pointerKindName(kind))
        }
        try requireDepth(state, depth)
        let dataWords = Int((raw >> 32) & 0xffff)
        let pointerWords = Int((raw >> 48) & 0xffff)
        let words = try checkedAdd(dataWords, pointerWords)
        let start = try target()
        try state.requireRange(segment: segment, start: start, words: words)
        try state.charge(words: words)
        return StructReader(
            state: state,
            segment: segment,
            dataBitStart: try checkedMultiply(start, 64),
            dataBitCount: try checkedMultiply(dataWords, 64),
            pointerStart: try checkedAdd(start, dataWords),
            pointerWords: pointerWords,
            depth: depth
        )
    }

    func asList(depth: Int) throws -> ListReader {
        if isNull { return ListReader.empty(state: state, depth: depth) }
        guard kind == 1 else {
            throw CapnProtoError.typeMismatch(expected: "list", actual: pointerKindName(kind))
        }
        try requireDepth(state, depth)
        guard let size = ListElementSize(rawValue: UInt8((raw >> 32) & 7)) else {
            throw CapnProtoError.invalidElementSize(UInt8((raw >> 32) & 7))
        }
        let countOrWords = Int((raw >> 35) & 0x1fff_ffff)
        let start = try target()
        if size == .inlineComposite {
            let total = try checkedAdd(countOrWords, 1)
            try state.requireRange(segment: segment, start: start, words: total)
            let tag = try state.word(segment: segment, index: start)
            guard tag & 3 == 0 else { throw CapnProtoError.invalidInlineCompositeTag }
            let elementCount = Int((tag >> 2) & 0x3fff_ffff)
            let dataWords = Int((tag >> 32) & 0xffff)
            let pointerWords = Int((tag >> 48) & 0xffff)
            let wordsPerElement = try checkedAdd(dataWords, pointerWords)
            let required = try checkedMultiply(elementCount, wordsPerElement)
            guard required <= countOrWords else { throw CapnProtoError.invalidInlineCompositeTag }
            try state.charge(words: countOrWords)
            return ListReader(
                state: state, segment: segment, startWord: start + 1, elementSize: size,
                count: elementCount, dataWordsPerElement: dataWords,
                pointerWordsPerElement: pointerWords, depth: depth, isNull: false
            )
        }
        let bits = size.bitWidth!
        let totalBits = try checkedMultiply(countOrWords, bits)
        let words = try wordsForBytes(try checkedAdd(totalBits, 7) / 8)
        try state.requireRange(segment: segment, start: start, words: words)
        try state.charge(words: words)
        return ListReader(
            state: state, segment: segment, startWord: start, elementSize: size,
            count: countOrWords, dataWordsPerElement: 0, pointerWordsPerElement: 0,
            depth: depth, isNull: false
        )
    }
}

func requireDepth(_ state: ReaderState, _ depth: Int) throws {
    guard depth < state.options.nestingLimit else { throw CapnProtoError.nestingLimitExceeded }
}

func pointerKindName(_ kind: UInt8) -> String {
    switch kind {
    case 0: "struct";
    case 1: "list";
    case 2: "far";
    default: "capability"
    }
}

func resolvePointer(state: ReaderState, segment: Int, pointerIndex: Int) throws -> ResolvedPointer {
    let raw = try state.word(segment: segment, index: pointerIndex)
    guard raw & 3 == 2 else {
        return ResolvedPointer(
            state: state, segment: segment, pointerIndex: pointerIndex, raw: raw,
            targetOverride: nil
        )
    }
    let isDoubleFar = raw & 4 != 0
    let landing = Int((raw >> 3) & 0x1fff_ffff)
    let targetSegment64 = raw >> 32
    guard let targetSegment = Int(exactly: targetSegment64),
        state.segments.indices.contains(targetSegment)
    else {
        throw CapnProtoError.invalidFarPointer
    }
    if !isDoubleFar {
        try state.requireRange(segment: targetSegment, start: landing, words: 1)
        let landingRaw = try state.word(segment: targetSegment, index: landing)
        guard landingRaw & 3 != 2 else { throw CapnProtoError.invalidFarPointer }
        return ResolvedPointer(
            state: state, segment: targetSegment, pointerIndex: landing, raw: landingRaw,
            targetOverride: nil
        )
    }

    try state.requireRange(segment: targetSegment, start: landing, words: 2)
    let objectFar = try state.word(segment: targetSegment, index: landing)
    let tag = try state.word(segment: targetSegment, index: landing + 1)
    guard objectFar & 7 == 2, tag & 3 != 2, ((tag >> 2) & 0x3fff_ffff) == 0 else {
        throw CapnProtoError.invalidFarPointer
    }
    let objectStart = Int((objectFar >> 3) & 0x1fff_ffff)
    let objectSegment64 = objectFar >> 32
    guard let objectSegment = Int(exactly: objectSegment64),
        state.segments.indices.contains(objectSegment)
    else {
        throw CapnProtoError.invalidFarPointer
    }
    return ResolvedPointer(
        state: state, segment: objectSegment, pointerIndex: landing + 1, raw: tag,
        targetOverride: objectStart
    )
}
