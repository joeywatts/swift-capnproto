import CapnProto
import CapnProtoRPC
import Foundation
import Testing

@testable import CapnProtoNIO

@Test func nioTargetLoads() {
    #expect(CapnProtoNIORuntime.isImplemented)
}

private actor AcceptedConnection {
    private var value: NIORPCTransport?
    func set(_ value: NIORPCTransport) { self.value = value }
    func wait() async -> NIORPCTransport {
        while value == nil { await Task.yield() }
        return value!
    }
}

private let networkMethod = CapabilityMethodDescriptor(
    interfaceID: 0x1234, methodID: 0, name: "increment",
    paramStructID: 1, resultStructID: 2, isStreaming: false)

private func networkValue(_ value: UInt32) throws -> StructReader {
    let message = try MessageBuilder()
    let root = try message.initRootStruct(dataWords: 1, pointerCount: 0)
    try root.setInteger(atByte: 0, to: value)
    return try message.asReader().rootStruct()
}

private final class NetworkService: CapabilityCallTarget, @unchecked Sendable {
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        try networkValue(try params.integer(atByte: 0, as: UInt32.self) + 1)
    }
}

// Adapts the TCP bootstrap/basic-call/clean-shutdown path from
// rpc-twoparty-test.c++ and ez-rpc-test.c++ at pinned commit
// 3a82de9b39736a2625f03c93b2b7c50642dd5b25.
@Test func nioTCPTransportRunsLiveTwoPartyRPC() async throws {
    let accepted = AcceptedConnection()
    let listener = try await NIORPCListener.bind(host: "127.0.0.1", port: 0) {
        await accepted.set($0)
    }
    let port = try #require(listener.localAddress?.port)
    let clientTransport = try await NIORPCTransport.connect(host: "127.0.0.1", port: port)
    let serverTransport = await accepted.wait()
    let client = TwoPartyRPCConnection(side: .client, transport: clientTransport)
    let server = TwoPartyRPCConnection(
        side: .server, transport: serverTransport,
        bootstrap: CapabilityClient(target: NetworkService()))
    await client.start()
    await server.start()

    let remote = try await client.bootstrap()
    let result = try await remote.call(networkMethod, params: networkValue(9))
    #expect(try result.integer(atByte: 0, as: UInt32.self) == 10)
    await client.close()
    await server.close()
    await listener.close()
}

@Test func nioUnixDomainTransportPreservesOrderedBytes() async throws {
    let accepted = AcceptedConnection()
    let path = FileManager.default.temporaryDirectory
        .appending(path: "swift-capnp-\(UUID().uuidString).sock").path
    let listener = try await NIORPCListener.bind(unixDomainSocketPath: path) {
        await accepted.set($0)
    }
    let client = try await NIORPCTransport.connect(unixDomainSocketPath: path)
    let server = await accepted.wait()
    try await client.send([1, 2, 3])
    try await client.send([4, 5])
    var bytes: [UInt8] = []
    while bytes.count < 5 { bytes.append(contentsOf: try #require(try await server.receive())) }
    #expect(bytes == [1, 2, 3, 4, 5])
    await client.close()
    await server.close()
    await listener.close()
    try? FileManager.default.removeItem(atPath: path)
}
