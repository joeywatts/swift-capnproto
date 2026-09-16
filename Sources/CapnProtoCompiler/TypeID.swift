import Foundation

public enum TypeID {
    public static func child(parent: UInt64, name: String) -> UInt64 {
        generated(bytes: littleEndian(parent) + Array(name.utf8))
    }

    public static func group(parent: UInt64, index: UInt16) -> UInt64 {
        generated(bytes: littleEndian(parent) + littleEndian(index))
    }

    public static func method(parent: UInt64, ordinal: UInt16, results: Bool) -> UInt64 {
        generated(bytes: littleEndian(parent) + littleEndian(ordinal) + [results ? 1 : 0])
    }

    private static func generated(bytes: [UInt8]) -> UInt64 {
        let digest = MD5.hash(bytes)
        var result: UInt64 = 0
        for byte in digest.prefix(8) { result = result << 8 | UInt64(byte) }
        return result | (UInt64(1) << 63)
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

private enum MD5 {
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
    private static let constants: [UInt32] = (0..<64).map {
        UInt32(abs(sin(Double($0 + 1))) * 4_294_967_296.0)
    }

    static func hash(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for index in 0..<8 { message.append(UInt8(truncatingIfNeeded: bitLength >> (index * 8))) }

        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        for blockStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for word in 0..<16 {
                for byte in 0..<4 {
                    words[word] |= UInt32(message[blockStart + word * 4 + byte]) << (byte * 8)
                }
            }
            var a = a0, b = b0, c = c0, d = d0
            for index in 0..<64 {
                let f: UInt32
                let g: Int
                switch index {
                case 0..<16: f = (b & c) | (~b & d); g = index
                case 16..<32: f = (d & b) | (~d & c); g = (5 * index + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * index + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * index) % 16
                }
                let sum = a &+ f &+ constants[index] &+ words[g]
                let rotated = (sum << shifts[index]) | (sum >> (32 - shifts[index]))
                (a, b, c, d) = (d, b &+ rotated, b, c)
            }
            a0 &+= a; b0 &+= b; c0 &+= c; d0 &+= d
        }
        return [a0, b0, c0, d0].flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        }
    }
}
