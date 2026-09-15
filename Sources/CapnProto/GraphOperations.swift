/// A detached pointer graph. Orphans are single-use and may only be adopted by
/// the message arena from which they were disowned.
public final class Orphan {
    let arena: BuilderArena
    let source: ResolvedPointer
    var consumed = false

    init(arena: BuilderArena, source: ResolvedPointer) {
        self.arena = arena
        self.source = source
    }
}

enum CopySource {
    case resolved(ResolvedPointer)
    case structReader(StructReader)
    case listReader(ListReader)
}

private struct CopyTask {
    let source: ResolvedPointer
    let destinationSegment: Int
    let destinationIndex: Int
}

func copyPointerGraph(
    source: CopySource, to arena: BuilderArena, pointerSegment: Int, pointerIndex: Int
) throws {
    let initial: ResolvedPointer
    switch source {
    case let .resolved(pointer):
        initial = pointer
    case let .structReader(reader):
        // Synthesize an offset-zero tag whose target is explicitly overridden.
        let raw = try PointerValue.struct(
            dataWords: reader.dataWordCount, pointerWords: reader.pointerCount
        ).word(offset: 0)
        initial = ResolvedPointer(
            state: reader.state, segment: reader.segment, pointerIndex: 0, raw: raw,
            targetOverride: reader.dataBitStart / 64)
    case let .listReader(reader):
        let countOrWords: Int
        if reader.elementSize == .inlineComposite {
            countOrWords = try checkedMultiply(
                reader.count,
                try checkedAdd(reader.dataWordsPerElement, reader.pointerWordsPerElement))
        } else {
            countOrWords = reader.count
        }
        let raw = try PointerValue.list(size: reader.elementSize, countOrWords: countOrWords)
            .word(offset: 0)
        let target =
            reader.elementSize == .inlineComposite ? reader.startWord - 1 : reader.startWord
        initial = ResolvedPointer(
            state: reader.state, segment: reader.segment, pointerIndex: 0, raw: raw,
            targetOverride: target)
    }

    var tasks = [
        CopyTask(
            source: initial, destinationSegment: pointerSegment, destinationIndex: pointerIndex)
    ]
    while let task = tasks.popLast() {
        if task.source.isNull {
            try arena.setWord(0, segment: task.destinationSegment, index: task.destinationIndex)
            continue
        }
        switch task.source.kind {
        case 0:
            let reader = try task.source.asStruct(depth: 0)
            let object = try arena.allocateObject(
                words: try checkedAdd(reader.dataWordCount, reader.pointerCount),
                fromPointerIn: task.destinationSegment, at: task.destinationIndex,
                pointerValue: .struct(
                    dataWords: reader.dataWordCount, pointerWords: reader.pointerCount))
            try copyBytes(
                count: reader.dataWordCount * 8,
                source: reader.state.segments[reader.segment],
                sourceOffset: reader.dataBitStart / 8,
                arena: arena, destinationSegment: object.allocation.segmentID,
                destinationOffset: object.objectStart * 8)
            for index in 0..<reader.pointerCount {
                tasks.append(
                    CopyTask(
                        source: try reader.pointer(at: index),
                        destinationSegment: object.allocation.segmentID,
                        destinationIndex: object.objectStart + reader.dataWordCount + index))
            }
        case 1:
            let reader = try task.source.asList(depth: 0)
            if reader.elementSize == .inlineComposite {
                let stride = try checkedAdd(
                    reader.dataWordsPerElement, reader.pointerWordsPerElement)
                let destination = try StructListBuilder.initialize(
                    arena: arena, pointerSegment: task.destinationSegment,
                    pointerIndex: task.destinationIndex, count: reader.count,
                    dataWords: reader.dataWordsPerElement,
                    pointerCount: reader.pointerWordsPerElement)
                for index in 0..<reader.count {
                    let sourceStart = reader.startWord + index * stride
                    let destinationStart = destination.elementsStart + index * stride
                    try copyBytes(
                        count: reader.dataWordsPerElement * 8,
                        source: reader.state.segments[reader.segment],
                        sourceOffset: sourceStart * 8,
                        arena: arena, destinationSegment: destination.segment,
                        destinationOffset: destinationStart * 8)
                    for pointer in 0..<reader.pointerWordsPerElement {
                        tasks.append(
                            CopyTask(
                                source: try resolvePointer(
                                    state: reader.state, segment: reader.segment,
                                    pointerIndex: sourceStart + reader.dataWordsPerElement + pointer
                                ),
                                destinationSegment: destination.segment,
                                destinationIndex: destinationStart + reader.dataWordsPerElement
                                    + pointer))
                    }
                }
            } else {
                let destination = try ListBuilder.initialize(
                    arena: arena, pointerSegment: task.destinationSegment,
                    pointerIndex: task.destinationIndex, elementSize: reader.elementSize,
                    count: reader.count)
                if reader.elementSize == .pointer {
                    for index in 0..<reader.count {
                        tasks.append(
                            CopyTask(
                                source: try reader.pointer(at: index),
                                destinationSegment: destination.segment,
                                destinationIndex: destination.startWord + index))
                    }
                } else {
                    let bits = try checkedMultiply(reader.count, reader.elementSize.bitWidth!)
                    let bytes = try checkedAdd(bits, 7) / 8
                    try copyBytes(
                        count: bytes, source: reader.state.segments[reader.segment],
                        sourceOffset: reader.startWord * 8, arena: arena,
                        destinationSegment: destination.segment,
                        destinationOffset: destination.startWord * 8)
                }
            }
        default:
            throw CapnProtoError.invalidPointerKind(task.source.kind)
        }
    }
}

private func copyBytes(
    count: Int, source: [UInt8], sourceOffset: Int, arena: BuilderArena,
    destinationSegment: Int, destinationOffset: Int
) throws {
    guard count > 0 else { return }
    let sourceRange = try checkedRange(start: sourceOffset, count: count, limit: source.count)
    try arena.withBytes(segment: destinationSegment) { destination in
        let destinationRange = try checkedRange(
            start: destinationOffset, count: count, limit: destination.count)
        destination.replaceSubrange(destinationRange, with: source[sourceRange])
    }
}

private struct ObjectKey: Hashable {
    let segment: Int
    let start: Int
    let kind: UInt8
}

extension BuilderArena {
    func clearPointerGraph(segment: Int, pointerIndex: Int) throws {
        let original = try word(segment: segment, index: pointerIndex)
        guard original != 0 else { return }
        let snapshot = try MessageReader(segments: outputSegments)
        var tasks = [
            try resolvePointer(
                state: snapshot.rootPointer().state, segment: segment, pointerIndex: pointerIndex)
        ]
        var visited = Set<ObjectKey>()
        while let pointer = tasks.popLast() {
            if pointer.isNull { continue }
            switch pointer.kind {
            case 0:
                let reader = try pointer.asStruct(depth: 0)
                let start = reader.dataBitStart / 64
                guard
                    visited.insert(ObjectKey(segment: reader.segment, start: start, kind: 0))
                        .inserted
                else { continue }
                for index in 0..<reader.pointerCount { tasks.append(try reader.pointer(at: index)) }
                try clearWords(
                    segment: reader.segment, start: start,
                    count: reader.dataWordCount + reader.pointerCount)
            case 1:
                let reader = try pointer.asList(depth: 0)
                let objectStart =
                    reader.elementSize == .inlineComposite
                    ? reader.startWord - 1 : reader.startWord
                guard
                    visited.insert(
                        ObjectKey(segment: reader.segment, start: objectStart, kind: 1)
                    ).inserted
                else { continue }
                if reader.elementSize == .pointer {
                    for index in 0..<reader.count { tasks.append(try reader.pointer(at: index)) }
                } else if reader.elementSize == .inlineComposite {
                    let stride = reader.dataWordsPerElement + reader.pointerWordsPerElement
                    for element in 0..<reader.count {
                        let start = reader.startWord + element * stride + reader.dataWordsPerElement
                        for index in 0..<reader.pointerWordsPerElement {
                            tasks.append(
                                try resolvePointer(
                                    state: reader.state, segment: reader.segment,
                                    pointerIndex: start + index))
                        }
                    }
                }
                let words: Int
                if reader.elementSize == .inlineComposite {
                    words =
                        1 + reader.count
                        * (reader.dataWordsPerElement + reader.pointerWordsPerElement)
                } else {
                    words = try wordsForBytes(
                        try checkedAdd(
                            try checkedMultiply(reader.count, reader.elementSize.bitWidth!), 7) / 8)
                }
                try clearWords(segment: reader.segment, start: objectStart, count: words)
            default:
                throw CapnProtoError.invalidPointerKind(pointer.kind)
            }
        }
        try setWord(0, segment: segment, index: pointerIndex)
    }
}

extension StructReader {
    func builderCopy(in arena: BuilderArena) throws -> StructBuilder {
        let root = try MessageReader(segments: arena.outputSegments).rootStruct()
        return StructBuilder(
            arena: arena, segment: root.segment, dataStart: root.dataBitStart / 64,
            dataWords: root.dataWordCount, pointerStart: root.pointerStart,
            pointerCount: root.pointerCount)
    }
}
