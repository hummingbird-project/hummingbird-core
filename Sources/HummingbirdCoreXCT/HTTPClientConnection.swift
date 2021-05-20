//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1
import NIOSSL

/// Bare bones HTTP client that connects to one Server.
///
/// This is here to for testing purposes
public class HBHTTPClientConnection {
    public let channelPromise: EventLoopPromise<Channel>
    let eventLoopGroup: EventLoopGroup
    let eventLoopGroupProvider: NIOEventLoopGroupProvider
    let responseStream: EventLoopStream<HBHTTPClient.Response>
    let host: String
    let port: Int
    let tlsConfiguration: TLSConfiguration?

    public init(host: String, port: Int, tlsConfiguration: TLSConfiguration? = nil, eventLoopGroupProvider: NIOEventLoopGroupProvider) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch eventLoopGroupProvider {
        case .createNew:
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        case .shared(let elg):
            self.eventLoopGroup = elg
        }
        self.channelPromise = self.eventLoopGroup.next().makePromise()
        self.responseStream = EventLoopStream<HBHTTPClient.Response>(on: self.eventLoopGroup.next())
        self.host = host
        self.port = port
        self.tlsConfiguration = tlsConfiguration
    }

    public func connect() {
        do {
            try self.getBootstrap()
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    return channel.pipeline.addHTTPClientHandlers()
                        .flatMap {
                            let handlers: [ChannelHandler] = [
                                HTTPClientRequestSerializer(),
                                HTTPClientResponseHandler(stream: self.responseStream),
                            ]
                            return channel.pipeline.addHandlers(handlers)
                        }
                }
                .connect(host: self.host, port: self.port)
                .cascade(to: self.channelPromise)
        } catch {
            self.channelPromise.fail(HBHTTPClient.Error.tlsSetupFailed)
        }
    }

    public func syncShutdown() throws {
        try self.responseStream.syncShutdown()
        if case .createNew = self.eventLoopGroupProvider {
            try self.eventLoopGroup.syncShutdownGracefully()
        }
    }

    public func get(_ uri: String, headers: HTTPHeaders = [:]) {
        let request = HBHTTPClient.Request(uri, method: .GET, headers: headers)
        self.execute(request)
    }

    public func head(_ uri: String, headers: HTTPHeaders = [:]) {
        let request = HBHTTPClient.Request(uri, method: .HEAD, headers: headers)
        self.execute(request)
    }

    public func put(_ uri: String, headers: HTTPHeaders = [:], body: ByteBuffer) {
        let request = HBHTTPClient.Request(uri, method: .PUT, headers: headers, body: body)
        self.execute(request)
    }

    public func post(_ uri: String, headers: HTTPHeaders = [:], body: ByteBuffer) {
        let request = HBHTTPClient.Request(uri, method: .POST, headers: headers, body: body)
        self.execute(request)
    }

    public func delete(_ uri: String, headers: HTTPHeaders = [:], body: ByteBuffer) {
        let request = HBHTTPClient.Request(uri, method: .DELETE, headers: headers, body: body)
        self.execute(request)
    }

    public func execute(_ request: HBHTTPClient.Request) {
        self.channelPromise.futureResult.whenComplete { channel in
            switch channel {
            case .success(let value):
                value.writeAndFlush(request, promise: nil)
            case .failure(let error):
                self.responseStream.error(error)
            }
        }
    }

    public func getResponse() -> EventLoopFuture<HBHTTPClient.Response> {
        return self.responseStream.consume().unwrap(orError: HBHTTPClient.Error.noResponse)
    }

    private func getBootstrap() throws -> NIOClientTCPBootstrap {
        if let tlsConfiguration = tlsConfiguration {
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: host)
            let bootstrap = NIOClientTCPBootstrap(ClientBootstrap(group: self.eventLoopGroup), tls: tlsProvider)
            bootstrap.enableTLS()
            return bootstrap
        } else {
            return NIOClientTCPBootstrap(ClientBootstrap(group: self.eventLoopGroup), tls: NIOInsecureNoTLS())
        }
    }

    /// Channel Handler for serializing request header and data
    private class HTTPClientRequestSerializer: ChannelOutboundHandler {
        typealias OutboundIn = HBHTTPClient.Request
        typealias OutboundOut = HTTPClientRequestPart

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            let request = unwrapOutboundIn(data)
            let head = HTTPRequestHead(
                version: .init(major: 1, minor: 1),
                method: request.method,
                uri: request.uri,
                headers: request.headers
            )
            context.write(wrapOutboundOut(.head(head)), promise: nil)

            if let body = request.body, body.readableBytes > 0 {
                context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            }
            context.write(self.wrapOutboundOut(.end(nil)), promise: promise)
        }
    }

    /// Channel Handler for parsing response from server
    private class HTTPClientResponseHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPClientResponsePart
        typealias OutboundOut = HBHTTPClient.Response

        private enum ResponseState {
            /// Waiting to parse the next response.
            case idle
            /// received the head
            case head(HTTPResponseHead)
            /// Currently parsing the response's body.
            case body(HTTPResponseHead, ByteBuffer)
        }

        private var state: ResponseState = .idle
        private let responseStream: EventLoopStream<HBHTTPClient.Response>

        init(stream: EventLoopStream<HBHTTPClient.Response>) {
            self.responseStream = stream
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.fireErrorCaught(error)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = unwrapInboundIn(data)
            switch (part, self.state) {
            case (.head(let head), .idle):
                state = .head(head)
            case (.body(let body), .head(let head)):
                self.state = .body(head, body)
            case (.body(var part), .body(let head, var body)):
                body.writeBuffer(&part)
                self.state = .body(head, body)
            case (.end(let tailHeaders), .body(let head, let body)):
                assert(tailHeaders == nil, "Unexpected tail headers")
                let response = HBHTTPClient.Response(
                    headers: head.headers,
                    status: head.status,
                    body: body
                )
                if context.channel.isActive {
                    context.fireChannelRead(wrapOutboundOut(response))
                }
                self.responseStream.feed(response)
                self.state = .idle
            case (.end(let tailHeaders), .head(let head)):
                assert(tailHeaders == nil, "Unexpected tail headers")
                let response = HBHTTPClient.Response(
                    headers: head.headers,
                    status: head.status,
                    body: nil
                )
                if context.channel.isActive {
                    context.fireChannelRead(wrapOutboundOut(response))
                }
                self.responseStream.feed(response)
                self.state = .idle
            default:
                self.responseStream.error(HBHTTPClient.Error.malformedResponse)
            }
        }
    }
}
