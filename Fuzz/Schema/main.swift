import CapnProtoCompiler
import CapnProtoTestSupport
import Foundation

guard CommandLine.arguments.count > 1 else {
    print("usage: capnp-fuzz-schema CORPUS_FILE...")
    exit(64)
}

for path in CommandLine.arguments.dropFirst() {
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    _ = SchemaRequestFuzzTarget.consume(bytes)
    let source = SourceFile(name: path, bytes: bytes)
    _ = CapnProtoLexer().tokens(in: source)
    _ = CapnProtoParser().parse(source)
}
