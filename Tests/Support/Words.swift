public enum WordAssertions {
    public static func littleEndianWords(_ bytes: [UInt8]) -> [UInt64]? {
        guard bytes.count.isMultiple(of: 8) else { return nil }
        return stride(from: 0, to: bytes.count, by: 8).map { offset in
            var word: UInt64 = 0
            for byte in 0..<8 {
                word |= UInt64(bytes[offset + byte]) << UInt64(byte * 8)
            }
            return word
        }
    }

    public static func firstMismatch(
        expected: [UInt64],
        actualBytes: [UInt8]
    ) -> (index: Int, expected: UInt64, actual: UInt64?)? {
        guard let actual = littleEndianWords(actualBytes) else {
            return (
                actualBytes.count / 8, expected.dropFirst(actualBytes.count / 8).first ?? 0, nil
            )
        }
        for index in 0..<max(expected.count, actual.count) {
            let expectedWord = index < expected.count ? expected[index] : nil
            let actualWord = index < actual.count ? actual[index] : nil
            if expectedWord != actualWord {
                return (index, expectedWord ?? 0, actualWord)
            }
        }
        return nil
    }
}
