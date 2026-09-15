import CapnProto
import CapnProtoNIO
import CapnProtoRPC
import Foundation

private let method = CapabilityMethodDescriptor(
    interfaceID: 0xeeee_eeee_eeee_eeee, methodID: 0, name: "increment",
    paramStructID: 0, resultStructID: 0, isStreaming: false)

private func value(_ number: UInt32) throws -> StructReader {
    let message = try MessageBuilder()
    let root = try message.initRootStruct(dataWords: 1, pointerCount: 0)
    try root.setInteger(atByte: 0, to: number)
    return try message.asReader().rootStruct()
}

private actor Completion {
    private var finished = false
    private var connection: TwoPartyRPCConnection?
    func attach(_ connection: TwoPartyRPCConnection) { self.connection = connection }
    func complete() { finished = true }
    func wait() async { while !finished { await Task.yield() } }
    func closeConnectionAfterReply() async {
        guard let connection else { return }
        while (await connection.snapshot).answers != 0 { await Task.yield() }
        await connection.close()
    }
}

private final class Echo: CapabilityCallTarget, @unchecked Sendable {
    let completion: Completion
    init(completion: Completion) { self.completion = completion }
    func supports(interfaceID: UInt64) -> Bool { interfaceID == method.interfaceID }
    func call(_ descriptor: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        guard descriptor.interfaceID == method.interfaceID, descriptor.methodID == 0 else {
            throw CapabilityError.unknownMethod(
                interfaceID: descriptor.interfaceID, methodID: descriptor.methodID)
        }
        let result = try value(try params.integer(atByte: 0, as: UInt32.self) + 1)
        await completion.complete()
        return result
    }
}

@main enum RPCInteropMain {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { throw RPCConnectionError.disconnected }
        if arguments[1] == "server" {
            let completion = Completion()
            let listener = try await NIORPCListener.bind(host: "127.0.0.1", port: 0) { transport in
                let connection = TwoPartyRPCConnection(
                    side: .server, transport: transport,
                    bootstrap: CapabilityClient(target: Echo(completion: completion)))
                await completion.attach(connection)
                await connection.start()
            }
            print(listener.localAddress!.port!)
            fflush(stdout)
            await completion.wait()
            await completion.closeConnectionAfterReply()
            await listener.close()
        } else if arguments[1] == "client", arguments.count == 3,
            let port = Int(arguments[2])
        {
            let transport = try await NIORPCTransport.connect(host: "127.0.0.1", port: port)
            let connection = TwoPartyRPCConnection(side: .client, transport: transport)
            await connection.start()
            do {
                let remote = try await connection.bootstrap()
                let result = try await remote.call(method, params: value(41))
                print(try result.integer(atByte: 0, as: UInt32.self))
                await connection.close()
            } catch {
                let snapshot = await connection.snapshot
                FileHandle.standardError.write(Data("\(snapshot)\n".utf8))
                throw error
            }
        } else {
            throw RPCConnectionError.disconnected
        }
    }
}
