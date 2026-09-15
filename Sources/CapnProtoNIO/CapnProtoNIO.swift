import CapnProtoRPC
import Foundation
import NIOCore
import NIOPosix

public enum CapnProtoNIORuntime {
    public static let isImplemented = true
}

private actor NIOInboundMailbox {
    private var chunks: [[UInt8]] = []
    private var waiters: [CheckedContinuation<[UInt8]?, any Error>] = []
    private var terminal: Result<Void, any Error>?

    func offer(_ bytes: [UInt8]) {
        guard terminal == nil else { return }
        if waiters.isEmpty {
            chunks.append(bytes)
        } else {
            waiters.removeFirst().resume(returning: bytes)
        }
    }

    func next() async throws -> [UInt8]? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if let terminal {
            switch terminal {
            case .success: return nil
            case .failure(let error): throw error
            }
        }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func finish(_ error: (any Error)? = nil) {
        guard terminal == nil else { return }
        terminal = error.map(Result.failure) ?? .success(())
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
    }
}

private final class NIOInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let mailbox: NIOInboundMailbox

    init(mailbox: NIOInboundMailbox) { self.mailbox = mailbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        Task { await mailbox.offer(bytes) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            Task { await mailbox.finish() }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task { await mailbox.finish() }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        Task { await mailbox.finish(error) }
        context.close(promise: nil)
    }
}

/// A SwiftNIO-backed ordered byte stream suitable for `TwoPartyRPCConnection`.
public final class NIORPCTransport: RPCMessageTransport, @unchecked Sendable {
    private let channel: any Channel
    private let mailbox: NIOInboundMailbox
    private let ownedGroup: MultiThreadedEventLoopGroup?

    private init(
        channel: any Channel, mailbox: NIOInboundMailbox,
        ownedGroup: MultiThreadedEventLoopGroup? = nil
    ) {
        self.channel = channel
        self.mailbox = mailbox
        self.ownedGroup = ownedGroup
    }

    public static func connect(host: String, port: Int) async throws -> NIORPCTransport {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let mailbox = NIOInboundMailbox()
        do {
            let channel = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(NIOInboundHandler(mailbox: mailbox))
                }
                .connect(host: host, port: port).get()
            return NIORPCTransport(channel: channel, mailbox: mailbox, ownedGroup: group)
        } catch {
            try? await shutdown(group)
            throw error
        }
    }

    public static func connect(unixDomainSocketPath path: String) async throws -> NIORPCTransport {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let mailbox = NIOInboundMailbox()
        do {
            let channel = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(NIOInboundHandler(mailbox: mailbox))
                }
                .connect(unixDomainSocketPath: path).get()
            return NIORPCTransport(channel: channel, mailbox: mailbox, ownedGroup: group)
        } catch {
            try? await shutdown(group)
            throw error
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    public func receive() async throws -> [UInt8]? { try await mailbox.next() }

    public func close() async {
        try? await channel.close().get()
        await mailbox.finish()
        if let ownedGroup { try? await shutdown(ownedGroup) }
    }

    fileprivate static func accepted(channel: any Channel, mailbox: NIOInboundMailbox)
        -> NIORPCTransport
    {
        NIORPCTransport(channel: channel, mailbox: mailbox)
    }
}

/// Owns a listening TCP or Unix-domain socket.
public final class NIORPCListener: @unchecked Sendable {
    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup

    private init(channel: any Channel, group: MultiThreadedEventLoopGroup) {
        self.channel = channel
        self.group = group
    }

    public var localAddress: SocketAddress? { channel.localAddress }

    public static func bind(
        host: String, port: Int, onAccept: @escaping @Sendable (NIORPCTransport) async -> Void
    ) async throws -> NIORPCListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { channel in
                    let mailbox = NIOInboundMailbox()
                    let transport = NIORPCTransport.accepted(channel: channel, mailbox: mailbox)
                    Task { await onAccept(transport) }
                    return channel.pipeline.addHandler(NIOInboundHandler(mailbox: mailbox))
                }
                .bind(host: host, port: port).get()
            return NIORPCListener(channel: channel, group: group)
        } catch {
            try? await shutdown(group)
            throw error
        }
    }

    public static func bind(
        unixDomainSocketPath path: String,
        onAccept: @escaping @Sendable (NIORPCTransport) async -> Void
    ) async throws -> NIORPCListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { channel in
                    let mailbox = NIOInboundMailbox()
                    let transport = NIORPCTransport.accepted(channel: channel, mailbox: mailbox)
                    Task { await onAccept(transport) }
                    return channel.pipeline.addHandler(NIOInboundHandler(mailbox: mailbox))
                }
                .bind(unixDomainSocketPath: path).get()
            return NIORPCListener(channel: channel, group: group)
        } catch {
            try? await shutdown(group)
            throw error
        }
    }

    public func close() async {
        try? await channel.close().get()
        try? await shutdown(group)
    }
}

private func shutdown(_ group: MultiThreadedEventLoopGroup) async throws {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        group.shutdownGracefully { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
}
