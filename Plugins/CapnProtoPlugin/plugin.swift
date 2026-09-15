import Foundation
import PackagePlugin

@main
struct CapnProtoPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else { return [] }
        let targetDirectoryPath = sourceTarget.directory
        let targetDirectory = URL(fileURLWithPath: targetDirectoryPath.string, isDirectory: true)
            .resolvingSymlinksInPath()
        let configurationURL = targetDirectory.appending(path: ".capnp-swift.json")
        let configuration = try loadConfiguration(at: configurationURL)
        if let moduleName = configuration.moduleName, moduleName != sourceTarget.name {
            throw PluginFailure(
                "configured moduleName \(moduleName) does not match SwiftPM target \(sourceTarget.name)"
            )
        }

        let importRoots =
            ([targetDirectory]
            + configuration.importPaths.map {
                targetDirectory.appending(path: $0, directoryHint: .isDirectory)
            }).map { $0.resolvingSymlinksInPath() }
        let schemas = try schemaFiles(below: targetDirectory)
        guard !schemas.isEmpty else { return [] }

        var inputFiles = Set(schemas)
        for root in importRoots {
            inputFiles.formUnion(try schemaFiles(below: root))
        }
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            inputFiles.insert(configurationURL)
        }

        let capnp = try findExecutable(named: "capnp")
        let generator = try context.tool(named: "capnpc-swift").path
        return try schemas.map { schema in
            let relative = try relativePath(of: schema, below: targetDirectory)
            let output = context.pluginWorkDirectory.appending(subpath: relative + ".swift")
            let importArguments = importRoots.map { "-I\($0.path)" }
            return .buildCommand(
                displayName: "Generating Swift from \(relative)",
                executable: capnp,
                arguments: [
                    "compile", "-o\(generator.string):\(context.pluginWorkDirectory.string)",
                    "--src-prefix=\(targetDirectory.path)",
                ] + importArguments + [schema.path],
                inputFiles: inputFiles.sorted { $0.path < $1.path }.map { Path($0.path) },
                outputFiles: [output]
            )
        }
    }
}

private struct Configuration: Decodable {
    var moduleName: String?
    var importPaths: [String] = []

    private enum CodingKeys: String, CodingKey {
        case moduleName
        case importPaths
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        moduleName = try values.decodeIfPresent(String.self, forKey: .moduleName)
        importPaths = try values.decodeIfPresent([String].self, forKey: .importPaths) ?? []
    }
}

private struct PluginFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func loadConfiguration(at url: URL) throws -> Configuration {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
    }
    return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
}

private func schemaFiles(below directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        throw PluginFailure("import path does not exist: \(directory.path)")
    }
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    return try enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension == "capnp",
            try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { return nil }
        return url.resolvingSymlinksInPath()
    }.sorted { $0.path < $1.path }
}

private func relativePath(of file: URL, below directory: URL) throws -> String {
    let root = directory.resolvingSymlinksInPath().path
    let path = file.resolvingSymlinksInPath().path
    guard path.hasPrefix(root + "/") else {
        throw PluginFailure("schema is outside target directory: \(path)")
    }
    return String(path.dropFirst(root.count + 1))
}

private func findExecutable(named name: String) throws -> Path {
    let environment = ProcessInfo.processInfo.environment
    for directory in environment["PATH", default: ""].split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
            .appending(path: name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return Path(candidate.path)
        }
    }
    throw PluginFailure("\(name) was not found on PATH")
}
