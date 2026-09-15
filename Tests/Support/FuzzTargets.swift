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
        let paddedEntries = tableEntries & ~1
        let (tableBytes, tableOverflow) = paddedEntries.multipliedReportingOverflow(by: 4)
        guard !tableOverflow, tableBytes <= UInt64(bytes.count) else { return .rejected }

        var payloadWords: UInt64 = 0
        for segment in 0..<Int(segmentCount) {
            let words = UInt64(loadUInt32(bytes, at: 4 + segment * 4))
            let (sum, overflow) = payloadWords.addingReportingOverflow(words)
            guard !overflow else { return .rejected }
            payloadWords = sum
        }
        let (payloadBytes, payloadOverflow) = payloadWords.multipliedReportingOverflow(by: 8)
        let (totalBytes, totalOverflow) = tableBytes.addingReportingOverflow(payloadBytes)
        guard !payloadOverflow, !totalOverflow, totalBytes <= UInt64(bytes.count) else {
            return .rejected
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
        var offset = 0
        var outputBytes: UInt64 = 0
        while offset < bytes.count {
            let tag = bytes[offset]
            offset += 1
            let literalCount = tag.nonzeroBitCount
            guard offset <= bytes.count - literalCount else { return .rejected }
            offset += literalCount
            let (sum, overflow) = outputBytes.addingReportingOverflow(8)
            guard !overflow, sum <= 64 * 1_024 * 1_024 else { return .rejected }
            outputBytes = sum

            if tag == 0 {
                guard offset < bytes.count else { return .rejected }
                let run = UInt64(bytes[offset])
                offset += 1
                let (extra, multiplyOverflow) = run.multipliedReportingOverflow(by: 8)
                let (next, addOverflow) = outputBytes.addingReportingOverflow(extra)
                guard !multiplyOverflow, !addOverflow, next <= 64 * 1_024 * 1_024 else {
                    return .rejected
                }
                outputBytes = next
            } else if tag == 0xff {
                guard offset < bytes.count else { return .rejected }
                let runBytes = Int(bytes[offset]) * 8
                offset += 1
                guard offset <= bytes.count - runBytes else { return .rejected }
                offset += runBytes
                let (next, overflow) = outputBytes.addingReportingOverflow(UInt64(runBytes))
                guard !overflow, next <= 64 * 1_024 * 1_024 else { return .rejected }
                outputBytes = next
            }
        }
        return .accepted
    }
}
