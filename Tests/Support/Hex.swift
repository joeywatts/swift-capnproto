import Foundation

public enum HexError: Error, Equatable, Sendable {
    case oddDigitCount
    case invalidDigit(Character)
}

public enum Hex {
    public static func decode(_ text: String) throws -> [UInt8] {
        let digits = text.filter { !$0.isWhitespace && $0 != "_" }
        guard digits.count.isMultiple(of: 2) else { throw HexError.oddDigitCount }
        var result: [UInt8] = []
        result.reserveCapacity(digits.count / 2)
        let characters = Array(digits)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = characters[index].hexDigitValue else {
                throw HexError.invalidDigit(characters[index])
            }
            guard let low = characters[index + 1].hexDigitValue else {
                throw HexError.invalidDigit(characters[index + 1])
            }
            result.append(UInt8(high * 16 + low))
        }
        return result
    }

    public static func encode(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
