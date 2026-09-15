import CapnProto

public enum FuzzResult: Equatable, Sendable {
    case accepted
    case rejected
}

public enum MessageFuzzTarget {
    public static func consume(_ bytes: [UInt8]) -> FuzzResult {
        guard bytes.count >= 8 else { return .rejected }
        let segmentCount = UInt64(loadUInt32(bytes, at: 0)) + 1
        guard segmentCount <= 512 else { return .rejected }
        let tableEntries = segmentCount + 1
        guard tableEntries <= UInt64(Int.max) else { return .rejected }
        let (entriesWithPadding, paddingOverflow) = tableEntries.addingReportingOverflow(1)
        guard !paddingOverflow else { return .rejected }
        let paddedEntries = entriesWithPadding & ~1
        let (tableBytes, tableOverflow) = paddedEntries.multipliedReportingOverflow(by: 4)
        guard !tableOverflow, tableBytes <= UInt64(bytes.count) else { return .rejected }

        var payloadWords: UInt64 = 0
        var segmentWordCounts: [Int] = []
        for segment in 0..<Int(segmentCount) {
            let words = UInt64(loadUInt32(bytes, at: 4 + segment * 4))
            let (sum, overflow) = payloadWords.addingReportingOverflow(words)
            guard !overflow else { return .rejected }
            payloadWords = sum
            segmentWordCounts.append(Int(words))
        }
        let (payloadBytes, payloadOverflow) = payloadWords.multipliedReportingOverflow(by: 8)
        let (totalBytes, totalOverflow) = tableBytes.addingReportingOverflow(payloadBytes)
        guard !payloadOverflow, !totalOverflow, totalBytes <= UInt64(bytes.count) else {
            return .rejected
        }
        var segments: [[UInt8]] = []
        var cursor = Int(tableBytes)
        for wordCount in segmentWordCounts {
            let byteCount = wordCount * 8
            segments.append(Array(bytes[cursor..<(cursor + byteCount)]))
            cursor += byteCount
        }
        // Exercise checked pointer decoding as part of every fuzz invocation. A
        // malformed root is an expected rejection, never a process failure.
        if let reader = try? MessageReader(segments: segments), !segments[0].isEmpty {
            _ = try? reader.rootStruct()
            _ = try? reader.rootList()
        }
        return .accepted
    }

    private static func loadUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

public enum PackedFuzzTarget {
    public static func consume(_ bytes: [UInt8]) -> FuzzResult {
        (try? PackedEncoding.unpack(bytes, maximumOutputBytes: 64 * 1_024 * 1_024)) == nil
            ? .rejected : .accepted
    }
}
