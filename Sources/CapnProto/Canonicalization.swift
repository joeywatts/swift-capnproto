private struct CanonicalObjectKey: Hashable {
    let segment: Int
    let start: Int
    let kind: UInt8
}

private struct CanonicalTask {
    let source: ResolvedPointer
    let destinationPointer: Int
}

private struct CanonicalBuffer {
    var bytes = [UInt8](repeating: 0, count: 8)  // Root pointer.

    var wordCount: Int { bytes.count / 8 }

    mutating func appendWords(_ count: Int) throws -> Int {
        guard count >= 0 else { throw CapnProtoError.arithmeticOverflow }
        let start = wordCount
        bytes.append(contentsOf: repeatElement(0, count: try checkedMultiply(count, 8)))
        return start
    }

    mutating func setWord(_ value: UInt64, at index: Int) throws {
        try LittleEndian.storeInteger(value, to: &bytes, at: try checkedMultiply(index, 8))
    }

    mutating func copy(
        from source: [UInt8], sourceOffset: Int, count: Int, to destinationOffset: Int
    ) throws {
        guard count > 0 else { return }
        let sourceRange = try checkedRange(start: sourceOffset, count: count, limit: source.count)
        let destinationRange = try checkedRange(
            start: destinationOffset, count: count, limit: bytes.count)
        bytes.replaceSubrange(destinationRange, with: source[sourceRange])
    }
}

public enum Canonicalization {
    /// Returns the unique, densely-packed, single-segment representation of a
    /// message's root pointer graph.
    public static func canonicalize(_ message: MessageReader) throws -> [UInt8] {
        // Canonicalization has its own traversal budget. Prior reads through the
        // caller's views must not make a deterministic serialization fail.
        let sourceState = ReaderState(
            segments: message.state.segments, options: message.state.options)
        var output = CanonicalBuffer()
        var tasks = [
            CanonicalTask(
                source: try resolvePointer(state: sourceState, segment: 0, pointerIndex: 0),
                destinationPointer: 0)
        ]
        var visited = Set<CanonicalObjectKey>()

        while let task = tasks.popLast() {
            if task.source.isNull {
                try output.setWord(0, at: task.destinationPointer)
                continue
            }
            switch task.source.kind {
            case 0:
                let reader = try task.source.asStruct(depth: 0)
                let sourceStart = reader.dataBitStart / 64
                guard
                    visited.insert(
                        CanonicalObjectKey(segment: reader.segment, start: sourceStart, kind: 0)
                    ).inserted
                else { throw CapnProtoError.invalidCanonicalForm }

                let dataWords = try truncatedDataWords(reader)
                let pointerWords = try truncatedPointerWords(reader)
                if dataWords == 0, pointerWords == 0 {
                    try output.setWord(
                        try PointerValue.struct(dataWords: 0, pointerWords: 0).word(offset: -1),
                        at: task.destinationPointer)
                    continue
                }
                let objectStart = try output.appendWords(try checkedAdd(dataWords, pointerWords))
                try output.setWord(
                    try PointerValue.struct(dataWords: dataWords, pointerWords: pointerWords)
                        .word(offset: objectStart - task.destinationPointer - 1),
                    at: task.destinationPointer)
                try output.copy(
                    from: reader.state.segments[reader.segment],
                    sourceOffset: reader.dataBitStart / 8, count: dataWords * 8,
                    to: objectStart * 8)
                if pointerWords > 0 {
                    for index in (0..<pointerWords).reversed() {
                        tasks.append(
                            CanonicalTask(
                                source: try reader.pointer(at: index),
                                destinationPointer: objectStart + dataWords + index))
                    }
                }
            case 1:
                let reader = try task.source.asList(depth: 0)
                let sourceObjectStart =
                    reader.elementSize == .inlineComposite
                    ? reader.startWord - 1 : reader.startWord
                guard
                    visited.insert(
                        CanonicalObjectKey(
                            segment: reader.segment, start: sourceObjectStart, kind: 1)
                    ).inserted
                else { throw CapnProtoError.invalidCanonicalForm }

                if reader.elementSize == .inlineComposite {
                    let dataWords = try truncatedCompositeDataWords(reader)
                    let pointerWords = try truncatedCompositePointerWords(reader)
                    let stride = try checkedAdd(dataWords, pointerWords)
                    let contentWords = try checkedMultiply(reader.count, stride)
                    let objectStart = try output.appendWords(try checkedAdd(contentWords, 1))
                    try output.setWord(
                        try PointerValue.list(size: .inlineComposite, countOrWords: contentWords)
                            .word(offset: objectStart - task.destinationPointer - 1),
                        at: task.destinationPointer)
                    try output.setWord(
                        try PointerValue.struct(dataWords: dataWords, pointerWords: pointerWords)
                            .word(offset: reader.count),
                        at: objectStart)
                    let sourceStride = reader.dataWordsPerElement + reader.pointerWordsPerElement
                    for element in 0..<reader.count {
                        let sourceStart = reader.startWord + element * sourceStride
                        let destinationStart = objectStart + 1 + element * stride
                        try output.copy(
                            from: reader.state.segments[reader.segment],
                            sourceOffset: sourceStart * 8, count: dataWords * 8,
                            to: destinationStart * 8)
                    }
                    if pointerWords > 0 {
                        for element in (0..<reader.count).reversed() {
                            let sourceStart = reader.startWord + element * sourceStride
                            let destinationStart = objectStart + 1 + element * stride
                            for pointer in (0..<pointerWords).reversed() {
                                tasks.append(
                                    CanonicalTask(
                                        source: try resolvePointer(
                                            state: reader.state, segment: reader.segment,
                                            pointerIndex: sourceStart + reader.dataWordsPerElement
                                                + pointer),
                                        destinationPointer: destinationStart + dataWords + pointer))
                            }
                        }
                    }
                } else {
                    let bits = try checkedMultiply(reader.count, reader.elementSize.bitWidth!)
                    let byteCount = try checkedAdd(bits, 7) / 8
                    let words = try wordsForBytes(byteCount)
                    let objectStart = try output.appendWords(words)
                    try output.setWord(
                        try PointerValue.list(size: reader.elementSize, countOrWords: reader.count)
                            .word(offset: objectStart - task.destinationPointer - 1),
                        at: task.destinationPointer)
                    if reader.elementSize == .pointer {
                        for index in (0..<reader.count).reversed() {
                            tasks.append(
                                CanonicalTask(
                                    source: try reader.pointer(at: index),
                                    destinationPointer: objectStart + index))
                        }
                    } else {
                        try output.copy(
                            from: reader.state.segments[reader.segment],
                            sourceOffset: reader.startWord * 8, count: byteCount,
                            to: objectStart * 8)
                        if reader.elementSize == .bit, reader.count % 8 != 0, byteCount > 0 {
                            let mask = UInt8((1 << UInt8(reader.count % 8)) - 1)
                            output.bytes[objectStart * 8 + byteCount - 1] &= mask
                        }
                    }
                }
            default:
                throw CapnProtoError.invalidCanonicalForm
            }
        }
        return output.bytes
    }

    public static func sizeInWords(_ message: MessageReader) throws -> Int {
        try canonicalize(message).count / 8
    }

    public static func isCanonical(_ message: MessageReader) -> Bool {
        guard message.segmentCount == 1,
            let canonical = try? canonicalize(message),
            let segment = try? message.segmentBytes(0)
        else { return false }
        return canonical == segment
    }
}

extension MessageReader {
    public func canonicalized() throws -> [UInt8] { try Canonicalization.canonicalize(self) }
    public var isCanonical: Bool { Canonicalization.isCanonical(self) }
    public var canonicalSizeInWords: Int { get throws { try Canonicalization.sizeInWords(self) } }

    func segmentBytes(_ index: Int) throws -> [UInt8] {
        guard state.segments.indices.contains(index) else {
            throw CapnProtoError.invalidSegment(index)
        }
        return state.segments[index]
    }
}

private func truncatedDataWords(_ reader: StructReader) throws -> Int {
    var count = reader.dataWordCount
    while count > 0,
        try reader.state.word(segment: reader.segment, index: reader.dataBitStart / 64 + count - 1)
            == 0
    { count -= 1 }
    return count
}

private func truncatedPointerWords(_ reader: StructReader) throws -> Int {
    var count = reader.pointerCount
    while count > 0,
        try reader.state.word(segment: reader.segment, index: reader.pointerStart + count - 1) == 0
    { count -= 1 }
    return count
}

private func truncatedCompositeDataWords(_ reader: ListReader) throws -> Int {
    var count = reader.dataWordsPerElement
    let stride = reader.dataWordsPerElement + reader.pointerWordsPerElement
    while count > 0 {
        var allZero = true
        for element in 0..<reader.count
        where
            try reader.state.word(
                segment: reader.segment, index: reader.startWord + element * stride + count - 1)
            != 0
        { allZero = false; break }
        if !allZero { break }
        count -= 1
    }
    return count
}

private func truncatedCompositePointerWords(_ reader: ListReader) throws -> Int {
    var count = reader.pointerWordsPerElement
    let stride = reader.dataWordsPerElement + reader.pointerWordsPerElement
    while count > 0 {
        var allNull = true
        for element in 0..<reader.count
        where
            try reader.state.word(
                segment: reader.segment,
                index: reader.startWord + element * stride + reader.dataWordsPerElement + count - 1)
            != 0
        { allNull = false; break }
        if !allNull { break }
        count -= 1
    }
    return count
}
