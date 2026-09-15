import CapnProto
import Foundation

let iterations =
    Int(ProcessInfo.processInfo.environment["CAPNP_BENCHMARK_ITERATIONS"] ?? "10000") ?? 10_000
let benchmarkMessage = try MessageBuilder(firstSegmentWords: 64)
let benchmarkRoot = try benchmarkMessage.initRootStruct(dataWords: 1, pointerCount: 1)
try benchmarkRoot.setInteger(atByte: 0, to: UInt64(42))
_ = try benchmarkRoot.setDataField(at: 0, to: [UInt8](repeating: 7, count: 256))
let sample = try benchmarkMessage.framedBytes
let packedSample = try benchmarkMessage.packedFramedBytes
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
        let frame = try! MessageFraming.decodePrefix(sample)
        checksum &+= try! frame.reader().rootStruct().integer(atByte: 0, as: UInt64.self)
    }
    return checksum
}

report("traversal") {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        let root = try! benchmarkMessage.asReader().rootStruct()
        checksum &+= try! root.dataField(at: 0).bytes.reduce(UInt64(0)) { $0 + UInt64($1) }
    }
    return checksum
}

report("build") {
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        let message = try! MessageBuilder(firstSegmentWords: 64)
        let root = try! message.initRootStruct(dataWords: 1, pointerCount: 1)
        try! root.setInteger(atByte: 0, to: UInt64(index))
        _ = try! root.setDataField(at: 0, to: [UInt8](repeating: 7, count: 256))
        checksum &+= UInt64(message.segments.reduce(0) { $0 + $1.count })
    }
    return checksum
}

report("serialize") {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        let output = try! benchmarkMessage.framedBytes
        checksum &+= UInt64(output.count)
    }
    return checksum
}

report("packed-io") {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        checksum &+= UInt64(try! PackedEncoding.unpack(packedSample).count)
    }
    return checksum
}
