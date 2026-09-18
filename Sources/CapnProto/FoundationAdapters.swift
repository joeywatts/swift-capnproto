import Foundation

extension MessageReader {
    /// Copies `Data` segments into a message reader.
    public init(dataSegments: [Data], options: ReaderOptions = ReaderOptions()) throws {
        try self.init(segments: dataSegments.map(Array.init), options: options)
    }

    /// Creates a reader from exactly one stream-framed `Data` value.
    public init(
        framedData: Data, framingOptions: FramingOptions = FramingOptions(),
        readerOptions: ReaderOptions = ReaderOptions()
    ) throws {
        try self.init(
            framedBytes: Array(framedData), framingOptions: framingOptions,
            readerOptions: readerOptions)
    }
}

extension DataReader {
    /// A copy of this Cap'n Proto data value as Foundation `Data`.
    public var data: Data { Data(bytes) }
}

extension FramedMessage {
    /// Copies the decoded message segments into Foundation `Data` values.
    public var dataSegments: [Data] { segments.map { Data($0) } }
}

extension MessageFraming {
    public static func encodeData(_ segments: [Data]) throws -> Data {
        Data(try encode(segments.map(Array.init)))
    }

    public static func decodePrefix(
        _ data: Data, options: FramingOptions = FramingOptions()
    ) throws -> FramedMessage {
        try decodePrefix(Array(data), options: options)
    }

    public static func decode(
        _ data: Data, options: FramingOptions = FramingOptions()
    ) throws -> FramedMessage {
        try decode(Array(data), options: options)
    }

    public static func decodeAll(
        _ data: Data, options: FramingOptions = FramingOptions()
    ) throws -> [FramedMessage] {
        try decodeAll(Array(data), options: options)
    }
}

extension StreamMessageDecoder {
    public mutating func append(_ data: Data) throws -> [FramedMessage] {
        try append(Array(data))
    }
}

extension PackedEncoding {
    public static func pack(_ data: Data) throws -> Data {
        Data(try pack(Array(data)))
    }

    public static func unpack(
        _ data: Data, maximumOutputBytes: Int = 64 * 1024 * 1024
    ) throws -> Data {
        Data(try unpack(Array(data), maximumOutputBytes: maximumOutputBytes))
    }
}

extension MessageBuilder {
    public var framedData: Data {
        get throws { Data(try framedBytes) }
    }

    public var packedFramedData: Data {
        get throws { Data(try packedFramedBytes) }
    }
}
