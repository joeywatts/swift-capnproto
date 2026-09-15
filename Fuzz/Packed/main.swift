import CapnProtoTestSupport
import Foundation

guard CommandLine.arguments.count > 1 else {
    print("usage: capnp-fuzz-packed CORPUS_FILE...")
    exit(64)
}

for path in CommandLine.arguments.dropFirst() {
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    _ = PackedFuzzTarget.consume(bytes)
}
