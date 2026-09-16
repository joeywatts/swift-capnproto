import CapnProto
import CapnProtoNIO
import CapnProtoRPC
import Foundation

private let method = CapabilityMethodDescriptor(
    interfaceID: 0xeeee_eeee_eeee_eeee, methodID: 0, name: "increment",
    paramStructID: 0, resultStructID: 0, isStreaming: false)
private let getEcho = CapabilityMethodDescriptor(
    interfaceID: 0xbbbb_bbbb_bbbb_bbbb, methodID: 0, name: "getEcho",
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

private final class BootstrapService: CapabilityCallTargetWithCaps, @unchecked Sendable {
    let echo: CapabilityClient
    init(completion: Completion) { echo = CapabilityClient(target: Echo(completion: completion)) }
    func call(_ descriptor: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    { throw CapabilityError.unserializableCapability }
    func call(
        _ descriptor: CapabilityMethodDescriptor, params: StructReader,
        capabilities: [CapabilityClient]
    ) async throws -> CapabilityCallResult {
        guard descriptor.interfaceID == getEcho.interfaceID, descriptor.methodID == 0 else {
            throw CapabilityError.unknownMethod(
                interfaceID: descriptor.interfaceID, methodID: descriptor.methodID)
        }
        let message = try MessageBuilder()
        let root = try message.initRootStruct(dataWords: 0, pointerCount: 1)
        try root.setCapabilityField(at: 0, tableIndex: 0)
        return CapabilityCallResult(
            results: try message.asReader().rootStruct(), capabilities: [echo])
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
                    bootstrap: CapabilityClient(target: BootstrapService(completion: completion)))
                await completion.attach(connection)
                await connection.start()
            }
            print(listener.localAddress!.port!)
            fflush(nil)
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
                let parent = Task { try await remote.call(getEcho, params: value(0)) }
                while (await connection.snapshot).questions < 1 { await Task.yield() }
                let pipelined = await connection.pipeline(questionID: 1, pointerFields: [0])
                let result = try await pipelined.call(method, params: value(41))
                _ = try await parent.value
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
