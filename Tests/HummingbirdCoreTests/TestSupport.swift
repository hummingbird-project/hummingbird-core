import HummingbirdCore
import HummingbirdCoreXCT
import NIOCore
import NIOHTTP1
import NIOSSL
import XCTest

public enum TestErrors: Error {
    case timeout
}

/// Basic responder that just returns "Hello" in body
public struct HelloResponder: HBHTTPResponder {
    public func respond(to request: HBHTTPRequest, context: ChannelHandlerContext, onComplete: @escaping (Result<HBHTTPResponse, Error>) -> Void) {
        let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok)
        let responseBody = context.channel.allocator.buffer(string: "Hello")
        let response = HBHTTPResponse(head: responseHead, body: .byteBuffer(responseBody))
        onComplete(.success(response))
    }
}

/// Setup child channel for HTTP1, with additional channel handlers
public struct TestHTTP1Channel: HBChannelInitializer {
    let additionalChannels: () -> [RemovableChannelHandler]
    public init(additionalChannels: @escaping @autoclosure () -> [RemovableChannelHandler]) {
        self.additionalChannels = additionalChannels
    }

    /// Initialize HTTP1 channel
    /// - Parameters:
    ///   - channel: channel
    ///   - childHandlers: Channel handlers to add
    ///   - configuration: server configuration
    public func initialize(channel: Channel, childHandlers: [RemovableChannelHandler], configuration: HBHTTPServer.Configuration) -> EventLoopFuture<Void> {
        return channel.eventLoop.makeCompletedFuture {
            let handlers = self.additionalChannels() + childHandlers
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                withPipeliningAssistance: configuration.withPipeliningAssistance,
                withErrorHandling: true
            )
            try channel.pipeline.syncOperations.addHandlers(handlers)
        }
    }
}

public func testServer(
    _ server: HBHTTPServer,
    clientConfiguration: HBXCTClient.Configuration = .init(),
    responder: HBHTTPResponder,
    _ test: (HBXCTClient) async throws -> Void
) async throws {
    try await server.start(responder: responder)
    let client = await HBXCTClient(
        host: "localhost",
        port: server.port!,
        configuration: clientConfiguration,
        eventLoopGroupProvider: .createNew
    )
    client.connect()
    do {
        try await test(client)
    } catch {
        try await client.shutdown()
        try await server.stop()
        throw error
    }
    try await client.shutdown()
    try await server.stop()
}

public func withTimeout(_ timeout: TimeAmount, _ process: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await Task.sleep(nanoseconds: numericCast(timeout.nanoseconds))
            throw TestErrors.timeout
        }
        group.addTask {
            try await process()
        }
        try await group.next()
        group.cancelAll()
    }
}
