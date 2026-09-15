public enum PackedEncoding {
    public static func pack(_ bytes: [UInt8]) throws -> [UInt8] {
        var encoder = PackedEncoder()
        var result = try encoder.append(bytes)
        result += try encoder.finish()
        return result
    }

    public static func unpack(
        _ bytes: [UInt8], maximumOutputBytes: Int = 64 * 1024 * 1024
    ) throws -> [UInt8] {
        var decoder = try PackedDecoder(maximumOutputBytes: maximumOutputBytes)
        var result = try decoder.append(bytes)
        result += try decoder.finish()
        return result
    }
}

private enum EncoderRun {
    case none
    case zero(Int)
    case literal([[UInt8]])
}

public struct PackedEncoder {
    private var buffer = [UInt8]()
    private var run = EncoderRun.none
    private var finished = false

    public init() {}

    public mutating func append(_ bytes: [UInt8]) throws -> [UInt8] {
        guard !finished else { throw CapnProtoError.invalidPackedData }
        buffer.append(contentsOf: bytes)
        return process(final: false)
    }

    public mutating func finish() throws -> [UInt8] {
        guard !finished, buffer.isEmpty else { throw CapnProtoError.invalidPackedData }
        finished = true
        return process(final: true)
    }

    private mutating func process(final: Bool) -> [UInt8] {
        var output = [UInt8]()
        while true {
            switch run {
            case .none:
                guard buffer.count >= 8 else { return output }
                let word = Array(buffer.prefix(8))
                buffer.removeFirst(8)
                let tag = word.enumerated().reduce(UInt8(0)) { result, element in
                    element.element == 0 ? result : result | (1 << UInt8(element.offset))
                }
                output.append(tag)
                for index in 0..<8 where tag & (1 << UInt8(index)) != 0 {
                    output.append(word[index])
                }
                if tag == 0 {
                    run = .zero(0)
                } else if tag == 0xff {
                    run = .literal([])
                }
            case let .zero(count):
                if count == 255 {
                    output.append(UInt8(count))
                    run = .none
                    continue
                }
                guard buffer.count >= 8 else {
                    if final {
                        output.append(UInt8(count))
                        run = .none
                    }
                    return output
                }
                if buffer.prefix(8).allSatisfy({ $0 == 0 }) {
                    buffer.removeFirst(8)
                    run = .zero(count + 1)
                } else {
                    output.append(UInt8(count))
                    run = .none
                }
            case let .literal(words):
                if words.count == 255 {
                    output.append(UInt8(words.count))
                    output.append(contentsOf: words.joined())
                    run = .none
                    continue
                }
                guard buffer.count >= 8 else {
                    if final {
                        output.append(UInt8(words.count))
                        output.append(contentsOf: words.joined())
                        run = .none
                    }
                    return output
                }
                let word = Array(buffer.prefix(8))
                if word.filter({ $0 == 0 }).count <= 1 {
                    buffer.removeFirst(8)
                    run = .literal(words + [word])
                } else {
                    output.append(UInt8(words.count))
                    output.append(contentsOf: words.joined())
                    run = .none
                }
            }
        }
    }
}

private enum DecoderState {
    case tag
    case word(tag: UInt8, index: Int, bytes: [UInt8])
    case zeroCount
    case literalCount
    case literalBytes(Int)
}

public struct PackedDecoder {
    private var state = DecoderState.tag
    private var buffer = [UInt8]()
    private let maximumOutputBytes: Int
    private var outputByteCount = 0
    private var finished = false

    public init(maximumOutputBytes: Int = 64 * 1024 * 1024) throws {
        guard maximumOutputBytes >= 0 else { throw CapnProtoError.packedOutputLimitExceeded }
        self.maximumOutputBytes = maximumOutputBytes
    }

    public mutating func append(_ bytes: [UInt8]) throws -> [UInt8] {
        guard !finished else { throw CapnProtoError.invalidPackedData }
        buffer.append(contentsOf: bytes)
        var cursor = 0
        var output = [UInt8]()
        processing: while true {
            switch state {
            case .tag:
                guard cursor < buffer.count else { break processing }
                let tag = buffer[cursor]
                cursor += 1
                state = .word(tag: tag, index: 0, bytes: [UInt8](repeating: 0, count: 8))
            case let .word(tag, index, partial):
                var word = partial
                var nextIndex = index
                while nextIndex < 8 {
                    if tag & (1 << UInt8(nextIndex)) != 0 {
                        guard cursor < buffer.count else {
                            state = .word(tag: tag, index: nextIndex, bytes: word)
                            break processing
                        }
                        word[nextIndex] = buffer[cursor]
                        cursor += 1
                    }
                    nextIndex += 1
                }
                try appendChecked(word, to: &output)
                if tag == 0 {
                    state = .zeroCount
                } else if tag == 0xff {
                    state = .literalCount
                } else {
                    state = .tag
                }
            case .zeroCount:
                guard cursor < buffer.count else { break processing }
                let count = Int(buffer[cursor]) * 8
                cursor += 1
                try appendChecked(repeatElement(0, count: count), to: &output)
                state = .tag
            case .literalCount:
                guard cursor < buffer.count else { break processing }
                state = .literalBytes(Int(buffer[cursor]) * 8)
                cursor += 1
            case let .literalBytes(remaining):
                if remaining == 0 {
                    state = .tag
                    continue
                }
                guard cursor < buffer.count else { break processing }
                let count = min(remaining, buffer.count - cursor)
                try appendChecked(buffer[cursor..<(cursor + count)], to: &output)
                cursor += count
                state = .literalBytes(remaining - count)
            }
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        return output
    }

    public mutating func finish() throws -> [UInt8] {
        guard !finished else { throw CapnProtoError.invalidPackedData }
        finished = true
        guard buffer.isEmpty, case .tag = state else { throw CapnProtoError.invalidPackedData }
        return []
    }

    private mutating func appendChecked<S: Sequence>(_ bytes: S, to output: inout [UInt8]) throws
    where S.Element == UInt8 {
        let values = Array(bytes)
        let next = try checkedAdd(outputByteCount, values.count)
        guard next <= maximumOutputBytes else {
            throw CapnProtoError.packedOutputLimitExceeded
        }
        outputByteCount = next
        output.append(contentsOf: values)
    }
}

extension MessageBuilder {
    public var packedFramedBytes: [UInt8] {
        get throws { try PackedEncoding.pack(framedBytes) }
    }
}
