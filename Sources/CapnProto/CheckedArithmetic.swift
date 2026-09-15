public enum CapnProtoError: Error, Equatable, CustomStringConvertible {
    case arithmeticOverflow
    case invalidSegment(Int)
    case wordOutOfBounds(segment: Int, word: Int)
    case invalidPointerKind(UInt8)
    case invalidElementSize(UInt8)
    case invalidInlineCompositeTag
    case invalidFarPointer
    case objectOutOfBounds(segment: Int, start: Int, words: Int)
    case nestingLimitExceeded
    case traversalLimitExceeded
    case typeMismatch(expected: String, actual: String)
    case indexOutOfBounds(index: Int, count: Int)
    case invalidText
    case orphanArenaMismatch
    case orphanAlreadyAdopted
    case invalidFrame
    case incompleteFrame
    case frameTooLarge
    case invalidPackedData
    case packedOutputLimitExceeded
    case invalidCanonicalForm

    public var description: String {
        switch self {
        case .arithmeticOverflow: "arithmetic overflow"
        case let .invalidSegment(segment): "invalid segment \(segment)"
        case let .wordOutOfBounds(segment, word): "word \(word) is outside segment \(segment)"
        case let .invalidPointerKind(kind): "invalid pointer kind \(kind)"
        case let .invalidElementSize(size): "invalid list element size \(size)"
        case .invalidInlineCompositeTag: "invalid inline-composite tag"
        case .invalidFarPointer: "invalid far pointer"
        case let .objectOutOfBounds(segment, start, words):
            "object [\(start), \(start + words)) is outside segment \(segment)"
        case .nestingLimitExceeded: "nesting limit exceeded"
        case .traversalLimitExceeded: "traversal limit exceeded"
        case let .typeMismatch(expected, actual): "expected \(expected), got \(actual)"
        case let .indexOutOfBounds(index, count): "index \(index) is outside 0..<\(count)"
        case .invalidText: "text is not NUL-terminated"
        case .orphanArenaMismatch: "orphan belongs to a different message arena"
        case .orphanAlreadyAdopted: "orphan has already been adopted"
        case .invalidFrame: "invalid stream frame"
        case .incompleteFrame: "incomplete stream frame"
        case .frameTooLarge: "stream frame exceeds configured limits"
        case .invalidPackedData: "invalid or truncated packed data"
        case .packedOutputLimitExceeded: "packed data exceeds the output limit"
        case .invalidCanonicalForm: "message graph cannot be canonicalized"
        }
    }
}

@inline(__always)
func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw CapnProtoError.arithmeticOverflow }
    return result
}

@inline(__always)
func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw CapnProtoError.arithmeticOverflow }
    return result
}

@inline(__always)
func checkedRange(start: Int, count: Int, limit: Int) throws -> Range<Int> {
    guard start >= 0, count >= 0 else { throw CapnProtoError.arithmeticOverflow }
    let end = try checkedAdd(start, count)
    guard end <= limit else { throw CapnProtoError.arithmeticOverflow }
    return start..<end
}

/// Sign-extends the low `width` bits of a value.
@inline(__always)
public func signExtend(_ value: UInt64, width: Int) -> Int64 {
    precondition(width > 0 && width <= 64)
    if width == 64 { return Int64(bitPattern: value) }
    let mask = (UInt64(1) << UInt64(width)) - 1
    let sign = UInt64(1) << UInt64(width - 1)
    let narrowed = value & mask
    return Int64(bitPattern: (narrowed ^ sign) &- sign)
}

/// Rounds a nonnegative byte count up to whole 64-bit words.
public func wordsForBytes(_ byteCount: Int) throws -> Int {
    guard byteCount >= 0 else { throw CapnProtoError.arithmeticOverflow }
    return try checkedAdd(byteCount, 7) / 8
}
