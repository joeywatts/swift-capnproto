public struct FramingOptions: Equatable, Sendable {
    public var maximumSegments: Int
    public var maximumTotalWords: Int

    public init(maximumSegments: Int = 512, maximumTotalWords: Int = 8 * 1024 * 1024) {
        self.maximumSegments = maximumSegments
        self.maximumTotalWords = maximumTotalWords
    }
}

public struct FramedMessage {
    public let segments: [[UInt8]]
    public let byteCount: Int

    public func reader(options: ReaderOptions = ReaderOptions()) throws -> MessageReader {
        try MessageReader(segments: segments, options: options)
    }
}

public enum MessageFraming {
    /// Produces a header followed by one slice per segment for scatter/gather I/O.
    public static func encodeSegments(_ segments: [[UInt8]]) throws -> [[UInt8]] {
        guard !segments.isEmpty, segments.count <= Int(UInt32.max) else {
            throw CapnProtoError.invalidFrame
        }
        guard segments.allSatisfy({ $0.count.isMultiple(of: 8) }) else {
            throw CapnProtoError.invalidFrame
        }
        let tableEntries = try checkedAdd(segments.count, 1)
        let paddedEntries = tableEntries.isMultiple(of: 2) ? tableEntries : tableEntries + 1
        var header = [UInt8](repeating: 0, count: try checkedMultiply(paddedEntries, 4))
        try LittleEndian.storeInteger(UInt32(segments.count - 1), to: &header, at: 0)
        for (index, segment) in segments.enumerated() {
            let words = segment.count / 8
            guard let encoded = UInt32(exactly: words) else { throw CapnProtoError.frameTooLarge }
            try LittleEndian.storeInteger(encoded, to: &header, at: (index + 1) * 4)
        }
        return [header] + segments
    }

    public static func encode(_ segments: [[UInt8]]) throws -> [UInt8] {
        try encodeSegments(segments).flatMap { $0 }
    }

    public static func decodePrefix(
        _ bytes: [UInt8], options: FramingOptions = FramingOptions()
    ) throws -> FramedMessage {
        guard options.maximumSegments > 0, options.maximumTotalWords >= 0 else {
            throw CapnProtoError.frameTooLarge
        }
        guard bytes.count >= 4 else { throw CapnProtoError.incompleteFrame }
        let countMinusOne = try LittleEndian.loadInteger(UInt32.self, from: bytes, at: 0)
        let segmentCount64 = UInt64(countMinusOne) + 1
        guard segmentCount64 <= UInt64(options.maximumSegments),
            let segmentCount = Int(exactly: segmentCount64)
        else { throw CapnProtoError.frameTooLarge }
        let tableEntries = try checkedAdd(segmentCount, 1)
        let paddedEntries = tableEntries.isMultiple(of: 2) ? tableEntries : tableEntries + 1
        let headerBytes = try checkedMultiply(paddedEntries, 4)
        guard bytes.count >= headerBytes else { throw CapnProtoError.incompleteFrame }

        var sizes = [Int]()
        sizes.reserveCapacity(segmentCount)
        var totalWords = 0
        for index in 0..<segmentCount {
            let size = try LittleEndian.loadInteger(
                UInt32.self, from: bytes, at: (index + 1) * 4)
            let words = Int(size)
            totalWords = try checkedAdd(totalWords, words)
            guard totalWords <= options.maximumTotalWords else {
                throw CapnProtoError.frameTooLarge
            }
            sizes.append(words)
        }
        if !tableEntries.isMultiple(of: 2) {
            let padding = try LittleEndian.loadInteger(
                UInt32.self, from: bytes, at: headerBytes - 4)
            guard padding == 0 else { throw CapnProtoError.invalidFrame }
        }
        let payloadBytes = try checkedMultiply(totalWords, 8)
        let frameBytes = try checkedAdd(headerBytes, payloadBytes)
        guard bytes.count >= frameBytes else { throw CapnProtoError.incompleteFrame }
        var segments = [[UInt8]]()
        segments.reserveCapacity(segmentCount)
        var offset = headerBytes
        for words in sizes {
            let count = words * 8
            segments.append(Array(bytes[offset..<(offset + count)]))
            offset += count
        }
        return FramedMessage(segments: segments, byteCount: frameBytes)
    }

    public static func decodeAll(
        _ bytes: [UInt8], options: FramingOptions = FramingOptions()
    ) throws -> [FramedMessage] {
        var result = [FramedMessage]()
        var offset = 0
        while offset < bytes.count {
            let message = try decodePrefix(Array(bytes[offset...]), options: options)
            result.append(message)
            offset = try checkedAdd(offset, message.byteCount)
        }
        return result
    }

    /// Consumes any async sequence of byte chunks. Chunks may split the table or
    /// payload at arbitrary byte boundaries.
    public static func decode<S: AsyncSequence>(
        _ chunks: S, options: FramingOptions = FramingOptions()
    ) async throws -> [FramedMessage] where S.Element == [UInt8] {
        var decoder = StreamMessageDecoder(options: options)
        var messages = [FramedMessage]()
        for try await chunk in chunks {
            messages.append(contentsOf: try decoder.append(chunk))
        }
        try decoder.finish()
        return messages
    }
}

public struct StreamMessageDecoder {
    private var buffer = [UInt8]()
    private let options: FramingOptions

    public init(options: FramingOptions = FramingOptions()) { self.options = options }

    public mutating func append(_ bytes: [UInt8]) throws -> [FramedMessage] {
        buffer.append(contentsOf: bytes)
        var result = [FramedMessage]()
        while !buffer.isEmpty {
            do {
                let message = try MessageFraming.decodePrefix(buffer, options: options)
                result.append(message)
                buffer.removeFirst(message.byteCount)
            } catch CapnProtoError.incompleteFrame {
                break
            }
        }
        return result
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw CapnProtoError.incompleteFrame }
    }
}

extension MessageBuilder {
    public var framedSegments: [[UInt8]] {
        get throws { try MessageFraming.encodeSegments(segments) }
    }

    public var framedBytes: [UInt8] {
        get throws { try MessageFraming.encode(segments) }
    }
}
