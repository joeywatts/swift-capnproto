import Foundation

public struct SubprocessResult: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data
}

public enum Subprocess {
    public static func run(
        executable: URL,
        arguments: [String],
        standardInput: Data = Data(),
        environment: [String: String]? = nil
    ) throws -> SubprocessResult {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(standardInput)
        try input.fileHandleForWriting.close()
        let standardOutput = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SubprocessResult(
            status: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }
}
