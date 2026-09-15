/// Controls how a message builder chooses the capacity of newly-created segments.
public enum AllocationStrategy: Equatable, Sendable {
    /// Every new segment has at least the first segment's capacity.
    case fixedSize
    /// Each new segment is at least twice as large as the preceding segment.
    case growing
}

/// The stable location of an allocation in a message builder.
public struct SegmentAllocation: Equatable, Sendable {
    public let segmentID: Int
    public let startWord: Int
    public let wordCount: Int

    init(segmentID: Int, startWord: Int, wordCount: Int) {
        self.segmentID = segmentID
        self.startWord = startWord
        self.wordCount = wordCount
    }
}

struct BuilderSegment {
    let id: Int
    var bytes: [UInt8]
    var usedWords: Int

    var capacityWords: Int { bytes.count / 8 }
}

final class BuilderArena {
    private(set) var segments: [BuilderSegment]
    let firstSegmentWords: Int
    let strategy: AllocationStrategy

    init(firstSegmentWords: Int, strategy: AllocationStrategy) throws {
        guard firstSegmentWords >= 0 else { throw CapnProtoError.arithmeticOverflow }
        self.firstSegmentWords = max(firstSegmentWords, 1)
        self.strategy = strategy
        let byteCount = try checkedMultiply(max(firstSegmentWords, 1), 8)
        segments = [
            BuilderSegment(id: 0, bytes: [UInt8](repeating: 0, count: byteCount), usedWords: 0)
        ]
    }

    func allocate(words: Int, preferredSegment: Int? = nil) throws -> SegmentAllocation {
        guard words >= 0 else { throw CapnProtoError.arithmeticOverflow }
        if let preferredSegment, segments.indices.contains(preferredSegment),
            words <= segments[preferredSegment].capacityWords - segments[preferredSegment].usedWords
        {
            return consume(words: words, in: preferredSegment)
        }
        if preferredSegment == nil, let last = segments.indices.last,
            words <= segments[last].capacityWords - segments[last].usedWords
        {
            return consume(words: words, in: last)
        }

        let previousCapacity = segments.last!.capacityWords
        let proposed: Int
        switch strategy {
        case .fixedSize:
            proposed = firstSegmentWords
        case .growing:
            proposed = try checkedMultiply(previousCapacity, 2)
        }
        let capacity = max(words, proposed)
        let byteCount = try checkedMultiply(capacity, 8)
        let id = segments.count
        segments.append(
            BuilderSegment(id: id, bytes: [UInt8](repeating: 0, count: byteCount), usedWords: 0))
        return consume(words: words, in: id)
    }

    private func consume(words: Int, in segmentID: Int) -> SegmentAllocation {
        let start = segments[segmentID].usedWords
        segments[segmentID].usedWords += words
        return SegmentAllocation(segmentID: segmentID, startWord: start, wordCount: words)
    }

    func word(segment: Int, index: Int) throws -> UInt64 {
        guard segments.indices.contains(segment), index >= 0, index < segments[segment].usedWords
        else {
            throw CapnProtoError.wordOutOfBounds(segment: segment, word: index)
        }
        return try LittleEndian.loadInteger(
            UInt64.self, from: segments[segment].bytes, at: index * 8)
    }

    func setWord(_ value: UInt64, segment: Int, index: Int) throws {
        guard segments.indices.contains(segment), index >= 0, index < segments[segment].usedWords
        else {
            throw CapnProtoError.wordOutOfBounds(segment: segment, word: index)
        }
        try LittleEndian.storeInteger(value, to: &segments[segment].bytes, at: index * 8)
    }

    func withBytes<R>(segment: Int, _ body: (inout [UInt8]) throws -> R) throws -> R {
        guard segments.indices.contains(segment) else {
            throw CapnProtoError.invalidSegment(segment)
        }
        return try body(&segments[segment].bytes)
    }

    var outputSegments: [[UInt8]] {
        segments.map { Array($0.bytes.prefix($0.usedWords * 8)) }
    }
}

/// Owns mutable message storage. Builder views retain this object, so their
/// storage remains alive for as long as any view is in use.
public final class MessageBuilder {
    let arena: BuilderArena

    public init(
        firstSegmentWords: Int = 1024,
        allocationStrategy: AllocationStrategy = .growing
    ) throws {
        arena = try BuilderArena(
            firstSegmentWords: firstSegmentWords, strategy: allocationStrategy)
        _ = try arena.allocate(words: 1, preferredSegment: 0)  // Root pointer.
    }

    public var segmentCount: Int { arena.segments.count }

    /// Reserves zero-initialized words. This low-level operation is useful for
    /// custom generated-code allocators; most callers use the typed initializers.
    public func allocate(words: Int) throws -> SegmentAllocation {
        try arena.allocate(words: words)
    }

    /// Returns used words only, ordered by stable segment ID.
    public var segments: [[UInt8]] { arena.outputSegments }

    public func asReader(options: ReaderOptions = ReaderOptions()) throws -> MessageReader {
        try MessageReader(segments: segments, options: options)
    }
}
