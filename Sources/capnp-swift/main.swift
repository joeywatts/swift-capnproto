import CapnProtoCompiler
import Foundation

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw CLIError.usage }
    arguments.removeFirst()
    switch command {
    case "id":
        if arguments.count == 2, let parent = parseID(arguments[0]) {
            print("0x\(String(TypeID.child(parent: parent, name: arguments[1]), radix: 16))")
        } else if arguments.isEmpty {
            var generator = SystemRandomNumberGenerator()
            print(
                "0x\(String(UInt64.random(in: (UInt64(1) << 63)...UInt64.max, using: &generator), radix: 16))"
            )
        } else {
            throw CLIError.usage
        }
    case "inspect":
        let invocation = try parseFilesAndImports(arguments)
        let schema = NativeSchemaCompiler(
            configuration: CompilerConfiguration(importPaths: invocation.importPaths)
        ).resolve(files: invocation.files)
        try report(schema.diagnostics)
        for file in schema.files {
            print("file 0x\(String(file.id, radix: 16)) \(file.sourceName)")
            for item in schema.nodes where item.sourceName == file.sourceName {
                print(
                    "  \(item.kind.rawValue) 0x\(String(item.id, radix: 16)) \(item.qualifiedName)")
            }
        }
    case "compile":
        let invocation = try parseCompile(arguments)
        let compilation = try NativeSchemaCompiler(
            configuration: CompilerConfiguration(
                importPaths: invocation.files.importPaths, sourcePrefix: invocation.sourcePrefix)
        ).compile(files: invocation.files.files)
        if let requestOutput = invocation.requestOutput {
            try Data(compilation.requestBytes).write(to: requestOutput)
        }
        for file in compilation.generatedFiles {
            let destination = invocation.output.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.contents.utf8).write(to: destination)
        }
    case "normalize-request":
        guard arguments.count == 1 else { throw CLIError.usage }
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        print(try normalizedCompilerIR(bytes), terminator: "")
    case "help", "--help", "-h": print(usage)
    default: throw CLIError.usage
    }
} catch {
    FileHandle.standardError.write(Data("capnp-swift: \(error)\n".utf8))
    if case CLIError.usage = error { FileHandle.standardError.write(Data(usage.utf8)) }
    exit(64)
}

private struct Invocation { var files: [URL]; var importPaths: [URL] }
private struct CompileInvocation {
    var files: Invocation
    var output: URL
    var sourcePrefix: URL?
    var requestOutput: URL?
}

private func parseCompile(_ arguments: [String]) throws -> CompileInvocation {
    var remaining: [String] = []
    var output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var sourcePrefix: URL?
    var requestOutput: URL?
    var index = 0
    while index < arguments.count {
        if arguments[index] == "-o" || arguments[index] == "--output" {
            index += 1; guard index < arguments.count else { throw CLIError.usage }
            output = URL(fileURLWithPath: arguments[index], isDirectory: true)
        } else if arguments[index].hasPrefix("--output=") {
            output = URL(
                fileURLWithPath: String(arguments[index].dropFirst("--output=".count)),
                isDirectory: true)
        } else if arguments[index] == "--src-prefix" {
            index += 1; guard index < arguments.count else { throw CLIError.usage }
            sourcePrefix = URL(fileURLWithPath: arguments[index], isDirectory: true)
        } else if arguments[index].hasPrefix("--src-prefix=") {
            sourcePrefix = URL(
                fileURLWithPath: String(arguments[index].dropFirst("--src-prefix=".count)),
                isDirectory: true)
        } else if arguments[index] == "--request-output" {
            index += 1; guard index < arguments.count else { throw CLIError.usage }
            requestOutput = URL(fileURLWithPath: arguments[index])
        } else if arguments[index].hasPrefix("--request-output=") {
            requestOutput = URL(
                fileURLWithPath: String(arguments[index].dropFirst("--request-output=".count)))
        } else {
            remaining.append(arguments[index])
        }
        index += 1
    }
    return CompileInvocation(
        files: try parseFilesAndImports(remaining), output: output,
        sourcePrefix: sourcePrefix, requestOutput: requestOutput)
}

private func parseFilesAndImports(_ arguments: [String]) throws -> Invocation {
    var result = Invocation(files: [], importPaths: [])
    var index = 0
    while index < arguments.count {
        if arguments[index] == "-I" {
            index += 1
            guard index < arguments.count else { throw CLIError.usage }
            result.importPaths.append(URL(fileURLWithPath: arguments[index], isDirectory: true))
        } else if arguments[index].hasPrefix("-I") {
            result.importPaths.append(
                URL(fileURLWithPath: String(arguments[index].dropFirst(2)), isDirectory: true))
        } else if arguments[index].hasPrefix("-") {
            throw CLIError.usage
        } else {
            result.files.append(URL(fileURLWithPath: arguments[index]))
        }
        index += 1
    }
    if result.files.isEmpty { throw CLIError.usage }
    return result
}

private func report(_ diagnostics: [SourceDiagnostic]) throws {
    guard diagnostics.isEmpty else {
        for diagnostic in diagnostics {
            FileHandle.standardError.write(Data("\(diagnostic)\n".utf8))
        }
        throw CLIError.diagnostics(diagnostics.count)
    }
}

private func parseID(_ value: String) -> UInt64? {
    value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
}

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case diagnostics(Int)
    var description: String {
        switch self {
        case .usage: return "invalid arguments"
        case .diagnostics(let count): return "compilation failed with \(count) diagnostic(s)"
        }
    }
}

private let usage = """
    usage:
      capnp-swift compile [-I path]... [-o path] [--src-prefix path]
                          [--request-output file] schema.capnp...
      capnp-swift inspect [-I path]... schema.capnp...
      capnp-swift id [parent-id child-name]
      capnp-swift normalize-request request.bin
    """
