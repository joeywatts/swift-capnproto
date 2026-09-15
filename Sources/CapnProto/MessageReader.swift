public struct ReaderOptions: Equatable, Sendable {
    public var traversalLimitInWords: Int
    public var nestingLimit: Int

    public init(traversalLimitInWords: Int = 8 * 1024 * 1024, nestingLimit: Int = 64) {
        self.traversalLimitInWords = traversalLimitInWords
        self.nestingLimit = nestingLimit
    }
}

final class ReaderState {
    let segments: [[UInt8]]
    let options: ReaderOptions
    var traversedWords = 0

    init(segments: [[UInt8]], options: ReaderOptions) {
        self.segments = segments
        self.options = options
    }

    func word(segment: Int, index: Int) throws -> UInt64 {
        guard segments.indices.contains(segment) else {
            throw CapnProtoError.invalidSegment(segment)
        }
        guard index >= 0 else {
            throw CapnProtoError.wordOutOfBounds(segment: segment, word: index)
        }
        let offset = try checkedMultiply(index, 8)
        guard offset <= segments[segment].count - 8 else {
            throw CapnProtoError.wordOutOfBounds(segment: segment, word: index)
        }
        return try LittleEndian.loadInteger(UInt64.self, from: segments[segment], at: offset)
    }

    func requireRange(segment: Int, start: Int, words: Int) throws {
        guard segments.indices.contains(segment) else {
            throw CapnProtoError.invalidSegment(segment)
        }
        guard start >= 0, words >= 0 else {
            throw CapnProtoError.objectOutOfBounds(segment: segment, start: start, words: words)
        }
        let end: Int
        do { end = try checkedAdd(start, words) } catch {
            throw CapnProtoError.objectOutOfBounds(segment: segment, start: start, words: words)
        }
        guard end <= segments[segment].count / 8 else {
            throw CapnProtoError.objectOutOfBounds(segment: segment, start: start, words: words)
        }
    }

    func charge(words: Int) throws {
        let next = try checkedAdd(traversedWords, words)
        guard next <= options.traversalLimitInWords else {
            throw CapnProtoError.traversalLimitExceeded
        }
        traversedWords = next
    }
}

public struct MessageReader {
    let state: ReaderState

    /// Copies segment bytes, so all returned views remain valid for the reader's lifetime.
    public init(segments: [[UInt8]], options: ReaderOptions = ReaderOptions()) throws {
        guard options.traversalLimitInWords >= 0, options.nestingLimit >= 0 else {
            throw CapnProtoError.arithmeticOverflow
        }
        guard !segments.isEmpty else { throw CapnProtoError.invalidSegment(0) }
        guard segments.allSatisfy({ $0.count.isMultiple(of: 8) }) else {
            throw CapnProtoError.arithmeticOverflow
        }
        state = ReaderState(segments: segments, options: options)
    }

    public var segmentCount: Int { state.segments.count }
    public func segment(_ index: Int) throws -> SegmentReader {
        guard state.segments.indices.contains(index) else {
            throw CapnProtoError.invalidSegment(index)
        }
        return SegmentReader(state: state, id: index)
    }

    public func rootStruct() throws -> StructReader {
        let pointer = try resolvePointer(state: state, segment: 0, pointerIndex: 0)
        return try pointer.asStruct(depth: 0)
    }

    public func rootList() throws -> ListReader {
        let pointer = try resolvePointer(state: state, segment: 0, pointerIndex: 0)
        return try pointer.asList(depth: 0)
    }

    public func rootAnyPointer() throws -> AnyPointerReader {
        AnyPointerReader(pointer: try rootPointer(), depth: 0)
    }

    public func rootData() throws -> DataReader {
        let list = try rootList()
        guard list.elementSize == .byte || list.isNull else {
            throw CapnProtoError.typeMismatch(
                expected: "byte list", actual: "\(list.elementSize)")
        }
        return DataReader(list: list)
    }

    public func rootText() throws -> TextReader {
        let data = try rootData()
        if data.isNull { return TextReader(data: data) }
        guard data.count > 0, try data.byte(at: data.count - 1) == 0 else {
            throw CapnProtoError.invalidText
        }
        return TextReader(data: data)
    }

    func rootPointer() throws -> ResolvedPointer {
        try resolvePointer(state: state, segment: 0, pointerIndex: 0)
    }
}

public struct SegmentReader {
    private let state: ReaderState
    public let id: Int

    init(state: ReaderState, id: Int) { self.state = state; self.id = id }

    public var wordCount: Int { state.segments[id].count / 8 }
    public func word(at index: Int) throws -> Word {
        Word(try state.word(segment: id, index: index))
    }
}
