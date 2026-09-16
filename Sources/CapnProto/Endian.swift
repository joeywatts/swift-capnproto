/// Alignment-independent little-endian scalar access.
public enum LittleEndian {
    @inline(__always)
    public static func loadInteger<T: FixedWidthInteger>(
        _ type: T.Type = T.self,
        from bytes: [UInt8],
        at offset: Int
    ) throws -> T {
        let width = MemoryLayout<T>.size
        let range: Range<Int>
        do {
            range = try checkedRange(start: offset, count: width, limit: bytes.count)
        } catch {
            throw CapnProtoError.arithmeticOverflow
        }
        _ = range
        let stored = bytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        return T(littleEndian: stored)
    }

    @inline(__always)
    public static func storeInteger<T: FixedWidthInteger>(
        _ value: T,
        to bytes: inout [UInt8],
        at offset: Int
    ) throws {
        let width = MemoryLayout<T>.size
        let range: Range<Int>
        do {
            range = try checkedRange(start: offset, count: width, limit: bytes.count)
        } catch {
            throw CapnProtoError.arithmeticOverflow
        }
        for (shift, index) in range.enumerated() {
            bytes[index] = UInt8(truncatingIfNeeded: value >> T(shift * 8))
        }
    }
}

public struct Word: Equatable, Hashable, Sendable {
    public var rawValue: UInt64

    public init(_ rawValue: UInt64 = 0) { self.rawValue = rawValue }

    public subscript(bits range: Range<Int>) -> UInt64 {
        get {
            precondition(range.lowerBound >= 0 && range.upperBound <= 64 && !range.isEmpty)
            let width = range.count
            let mask = width == 64 ? UInt64.max : (UInt64(1) << UInt64(width)) - 1
            return (rawValue >> UInt64(range.lowerBound)) & mask
        }
        set {
            precondition(range.lowerBound >= 0 && range.upperBound <= 64 && !range.isEmpty)
            let width = range.count
            let lowMask = width == 64 ? UInt64.max : (UInt64(1) << UInt64(width)) - 1
            let mask = lowMask << UInt64(range.lowerBound)
            rawValue = (rawValue & ~mask) | ((newValue & lowMask) << UInt64(range.lowerBound))
        }
    }

    public static func load(from bytes: [UInt8], atByteOffset offset: Int) throws -> Word {
        Word(try LittleEndian.loadInteger(UInt64.self, from: bytes, at: offset))
    }

    public func store(to bytes: inout [UInt8], atByteOffset offset: Int) throws {
        try LittleEndian.storeInteger(rawValue, to: &bytes, at: offset)
    }
}
