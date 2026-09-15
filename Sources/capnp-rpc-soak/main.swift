import CapnProto
import CapnProtoRPC
import Foundation

private let method = CapabilityMethodDescriptor(
    interfaceID: 0xeeee_eeee_eeee_eeee, methodID: 0, name: "churn",
    paramStructID: 0, resultStructID: 0, isStreaming: false)

private func value(_ number: UInt32) throws -> StructReader {
    let message = try MessageBuilder()
    let root = try message.initRootStruct(dataWords: 1, pointerCount: 0)
    try root.setInteger(atByte: 0, to: number)
    return try message.asReader().rootStruct()
}

private final class SoakService: CapabilityCallTarget, @unchecked Sendable {
    func call(_ descriptor: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        try value(try params.integer(atByte: 0, as: UInt32.self) &+ 1)
    }
}

@main enum RPCSoakMain {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let seconds = argument("--seconds", in: arguments).flatMap(Double.init) ?? 60
        let iterationLimit = argument("--iterations", in: arguments).flatMap(Int.init) ?? .max
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var iterations = 0
        var calls = 0
        while iterations < iterationLimit, ContinuousClock.now < deadline {
            let (a, b) = InMemoryRPCTransport.makePair(
                configuration: .init(maximumBufferedChunks: 2, fragmentSize: (iterations % 31) + 1))
            let client = TwoPartyRPCConnection(side: .client, transport: a)
            let server = TwoPartyRPCConnection(
                side: .server, transport: b,
                bootstrap: CapabilityClient(target: SoakService()))
            await client.start()
            await server.start()
            var remote: CapabilityClient? = try await client.bootstrap()
            for index in 0..<32 {
                let result = try await remote!.call(method, params: value(UInt32(index)))
                guard try result.integer(atByte: 0, as: UInt32.self) == UInt32(index + 1) else {
                    throw RPCProtocolError.malformedMessage("soak result mismatch")
                }
                calls += 1
            }
            remote = nil
            for _ in 0..<100 where (await server.snapshot).exports != 0 { await Task.yield() }
            await client.close()
            await server.close()
            let clientState = await client.snapshot
            let serverState = await server.snapshot
            guard clientState.questions == 0, clientState.answers == 0,
                clientState.imports == 0, clientState.exports == 0,
                serverState.questions == 0, serverState.answers == 0,
                serverState.imports == 0, serverState.exports == 0
            else { throw RPCProtocolError.malformedMessage("table leak") }
            iterations += 1
        }
        print("rpc-soak iterations=\(iterations) calls=\(calls) tableLeaks=0")
    }

    private static func argument(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}
