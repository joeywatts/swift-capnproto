import Foundation

/// Reference-counted capability table used by connection state machines. IDs are
/// never reused, and release callbacks run exactly once outside the table lock.
public final class CapabilityTable: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let entries: Int
        public let references: Int
        public init(entries: Int, references: Int) {
            self.entries = entries
            self.references = references
        }
    }

    private struct Entry {
        var references: Int
        let client: CapabilityClient
        let onRelease: (@Sendable () -> Void)?
    }

    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 0

    public init() {}

    public func insert(
        _ client: CapabilityClient, references: Int = 1,
        onRelease: (@Sendable () -> Void)? = nil
    ) throws -> UInt32 {
        guard references > 0 else { throw CapabilityTableError.invalidReferenceCount }
        return try lock.withLock {
            guard nextID != UInt32.max else { throw CapabilityTableError.idExhausted }
            let id = nextID
            nextID += 1
            entries[id] = Entry(references: references, client: client, onRelease: onRelease)
            return id
        }
    }

    public func retain(_ id: UInt32, count: Int = 1) throws {
        guard count > 0 else { throw CapabilityTableError.invalidReferenceCount }
        try lock.withLock {
            guard var entry = entries[id] else { throw CapabilityTableError.unknownID(id) }
            let (result, overflow) = entry.references.addingReportingOverflow(count)
            guard !overflow else { throw CapabilityTableError.referenceCountOverflow }
            entry.references = result
            entries[id] = entry
        }
    }

    public func lookup(_ id: UInt32) throws -> CapabilityClient {
        try lock.withLock {
            guard let entry = entries[id] else { throw CapabilityTableError.unknownID(id) }
            return entry.client
        }
    }

    public func release(_ id: UInt32, count: Int = 1) throws {
        guard count > 0 else { throw CapabilityTableError.invalidReferenceCount }
        let callback: (@Sendable () -> Void)? = try lock.withLock {
            guard var entry = entries[id] else { throw CapabilityTableError.unknownID(id) }
            guard count <= entry.references else { throw CapabilityTableError.releaseUnderflow(id) }
            entry.references -= count
            if entry.references == 0 {
                entries.removeValue(forKey: id)
                return entry.onRelease
            }
            entries[id] = entry
            return nil
        }
        callback?()
    }

    public func removeAll() {
        let callbacks: [@Sendable () -> Void] = lock.withLock {
            let result = entries.values.compactMap(\.onRelease)
            entries.removeAll(keepingCapacity: false)
            return result
        }
        for callback in callbacks { callback() }
    }

    public var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                entries: entries.count,
                references: entries.values.reduce(0) { $0 + $1.references })
        }
    }
}

public enum CapabilityTableError: Error, Equatable, Sendable {
    case invalidReferenceCount
    case idExhausted
    case referenceCountOverflow
    case unknownID(UInt32)
    case releaseUnderflow(UInt32)
}
