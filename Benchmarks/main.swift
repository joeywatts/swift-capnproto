import CapnProtoTestSupport
import Foundation

let iterations =
    Int(ProcessInfo.processInfo.environment["CAPNP_BENCHMARK_ITERATIONS"] ?? "10000") ?? 10_000
let sample = Array(repeating: UInt8(0), count: 256)
let packedSample: [UInt8] = [0, 31]
let clock = ContinuousClock()

func report(_ name: String, _ body: () -> UInt64) {
    let start = clock.now
    let checksum = body()
    let duration = start.duration(to: clock.now).components
    let nanoseconds = duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000
    print(
        "{\"benchmark\":\"\(name)\",\"iterations\":\(iterations),\"nanoseconds\":\(nanoseconds),\"checksum\":\(checksum)}"
    )
}

report("decode") {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        checksum &+= MessageFuzzTarget.consume(sample) == .accepted ? 1 : 0
    }
    return checksum
}

report("traversal") {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        for byte in sample { checksum &+= UInt64(byte) }
    }
    return checksum
}

report("build") {
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        let bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 256)
        checksum &+= UInt64(bytes.count)
    }
    return checksum
}

report("serialize") {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        let output = sample.withUnsafeBytes { Array($0) }
        checksum &+= UInt64(output.count)
    }
    return checksum
}

report("packed-io") {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        checksum &+= PackedFuzzTarget.consume(packedSample) == .accepted ? 1 : 0
    }
    return checksum
}
