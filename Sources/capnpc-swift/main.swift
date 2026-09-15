import CapnProtoSchema
import Foundation

do {
    let input = Array(FileHandle.standardInput.readDataToEndOfFile())
    let request = try Schema.CodeGeneratorRequest(framedBytes: input)

    if CommandLine.arguments.dropFirst() == ["--bootstrap-roundtrip"] {
        FileHandle.standardOutput.write(Data(try request.reencodedBytes()))
    } else if CommandLine.arguments.dropFirst() == ["--bootstrap-inspect"] {
        let version = try request.capnpVersion
        let files = try request.requestedFiles
        let summary =
            "capnp \(try version.major).\(try version.minor).\(try version.micro): "
            + "\(try request.nodes.count) nodes, "
            + files.map { (try? $0.filename) ?? "<invalid>" }.joined(separator: ", ") + "\n"
        FileHandle.standardOutput.write(Data(summary.utf8))
    } else {
        FileHandle.standardError.write(
            Data("capnpc-swift: code generation is not yet implemented\n".utf8))
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("capnpc-swift: \(error)\n".utf8))
    exit(1)
}
