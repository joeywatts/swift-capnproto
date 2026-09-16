import Testing

@testable import CapnProto

// Ported behavior: allocation/segment-count assertions from message-test.c++.
@Test func fixedSizeArenaUsesStableSegmentsAndZeroesAllocations() throws {
    let message = try MessageBuilder(firstSegmentWords: 2, allocationStrategy: .fixedSize)
    let first = try message.allocate(words: 1)
    let second = try message.allocate(words: 2)

    #expect(first == SegmentAllocation(segmentID: 0, startWord: 1, wordCount: 1))
    #expect(second == SegmentAllocation(segmentID: 1, startWord: 0, wordCount: 2))
    #expect(message.segmentCount == 2)
    #expect(
        message.segments == [[UInt8](repeating: 0, count: 16), [UInt8](repeating: 0, count: 16)])
}

// Ported behavior: single/multi-segment allocation pairs from encoding-test.c++.
@Test func growingArenaDoublesCapacityAndEmitsOnlyUsedWords() throws {
    let message = try MessageBuilder(firstSegmentWords: 1, allocationStrategy: .growing)
    let second = try message.allocate(words: 2)
    let third = try message.allocate(words: 3)

    #expect(second.segmentID == 1)
    #expect(third.segmentID == 2)
    #expect(message.segmentCount == 3)
    #expect(message.segments.map(\.count) == [8, 16, 24])
    #expect(message.segments.flatMap { $0 }.allSatisfy { $0 == 0 })
}

@Test func allocationRejectsInvalidAndOverflowingSizes() throws {
    let message = try MessageBuilder(firstSegmentWords: 1)
    #expect(throws: CapnProtoError.arithmeticOverflow) { try message.allocate(words: -1) }
    #expect(throws: CapnProtoError.allocationLimitExceeded) {
        _ = try MessageBuilder(firstSegmentWords: Int.max)
    }
}

@Test func builderAllocationLimitsAcceptBoundaryAndRejectOnePastIt() throws {
    let message = try MessageBuilder(
        firstSegmentWords: 1, allocationStrategy: .fixedSize,
        options: BuilderOptions(maximumSegments: 3, maximumTotalWords: 3))
    _ = try message.allocate(words: 1)
    _ = try message.allocate(words: 1)
    #expect(message.segmentCount == 3)
    #expect(throws: CapnProtoError.allocationLimitExceeded) {
        try message.allocate(words: 1)
    }

    let segmentLimited = try MessageBuilder(
        firstSegmentWords: 1, allocationStrategy: .fixedSize,
        options: BuilderOptions(maximumSegments: 1, maximumTotalWords: 3))
    #expect(throws: CapnProtoError.allocationLimitExceeded) {
        try segmentLimited.allocate(words: 1)
    }
}

@Test func deterministicSegmentOutputIsAnOwnedSnapshot() throws {
    let message = try MessageBuilder(firstSegmentWords: 2)
    _ = try message.allocate(words: 1)
    var snapshot = message.segments
    snapshot[0][0] = 99
    #expect(message.segments[0][0] == 0)
    #expect(message.segments == message.segments)
}
