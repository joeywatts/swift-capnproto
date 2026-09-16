import Foundation

public struct SourceRange: Equatable, Hashable, Sendable {
    public let startByte: Int
    public let endByte: Int

    public init(startByte: Int, endByte: Int) {
        self.startByte = startByte
        self.endByte = endByte
    }
}

public struct SourceDiagnostic: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Equatable, Sendable { case error, warning }

    public let severity: Severity
    public let source: String
    public let range: SourceRange
    public let message: String

    public init(
        severity: Severity = .error, source: String, range: SourceRange, message: String
    ) {
        self.severity = severity
        self.source = source
        self.range = range
        self.message = message
    }

    public var description: String {
        "\(source):bytes \(range.startByte)-\(range.endByte): \(severity.rawValue): \(message)"
    }
}

public struct SourceFile: Equatable, Sendable {
    public let name: String
    public let bytes: [UInt8]

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }

    public init(name: String, text: String) {
        self.init(name: name, bytes: Array(text.utf8))
    }
}
