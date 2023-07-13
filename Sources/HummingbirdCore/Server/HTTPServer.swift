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

import Logging
import NIOCore
import NIOExtras
import NIOHTTP1
import NIOPosix
#if canImport(Network)
import Network
import NIOTransportServices
#endif

/// HTTP server class
public actor HBHTTPServer {
    enum State: CustomStringConvertible {
        case initial(
            childChannelInitializer: HBChannelInitializer
        )
        case starting
        case running(
            channel: Channel,
            quiescingHelper: ServerQuiescingHelper
        )
        case shuttingDown(shutdownPromise: EventLoopPromise<Void>)
        case shutdown

        var description: String {
            switch self {
            case .initial:
                return "initial"
            case .starting:
                return "starting"
            case .running:
                return "running"
            case .shuttingDown:
                return "shuttingDown"
            case .shutdown:
                return "shutdown"
            }
        }
    }

    /// Server state
    var state: State {
        didSet { self.logger.trace("Server State: \(self.state)") }
    }

    /// EventLoopGroup used by server
    public let eventLoopGroup: EventLoopGroup
    /// Logger used by server
    public let logger: Logger
    /// Server configuration
    public let configuration: Configuration

    /// HTTP server errors
    public enum Error: Swift.Error {
        /// waiting on the server while it is not running will throw this
        case serverNotRunning
        /// the current connection is closing
        case connectionClosing
        /// the server is shutting down
        case serverShuttingDown
        /// the server has shutdown
        case serverShutdown
    }

    /// Initialize HTTP server
    /// - Parameters:
    ///   - group: EventLoopGroup server uses
    ///   - configuration: Configuration for server
    public init(
        group: EventLoopGroup,
        configuration: Configuration,
        childChannelInitializer: HBChannelInitializer = HTTP1Channel(),
        logger: Logger
    ) {
        self.eventLoopGroup = group
        self.configuration = configuration
        self.state = .initial(childChannelInitializer: childChannelInitializer)
        self.logger = logger
    }

    /// Start server
    /// - Parameter responder: Object that provides responses to requests sent to the server
    /// - Returns: EventLoopFuture that is fulfilled when server has started
    public func start(responder: HBHTTPResponder) async throws {
        switch self.state {
        case .initial(let childChannelInitializer):
            self.state = .starting
            let (channel, quiescingHelper) = try await self.makeServer(
                httpChannelInitializer: childChannelInitializer,
                responder: responder
            )
            // check state again
            switch self.state {
            case .initial, .running:
                preconditionFailure("We should only be running once")

            case .starting:
                self.state = .running(channel: channel, quiescingHelper: quiescingHelper)

            case .shuttingDown, .shutdown:
                try await channel.close()
            }

        case .starting, .running:
            fatalError("Unexpected state")

        case .shuttingDown:
            throw Error.serverShuttingDown

        case .shutdown:
            throw Error.serverShutdown
        }
    }

    /// Stop HTTP server
    /// - Returns: EventLoopFuture that is fulfilled when server has stopped
    public func stop() async throws {
        switch self.state {
        case .initial, .starting:
            self.state = .shutdown

        case .running(_, let quiescingHelper):
            let promise = self.eventLoopGroup.next().makePromise(of: Void.self)
            quiescingHelper.initiateShutdown(promise: promise)
            self.state = .shuttingDown(shutdownPromise: promise)
            try await promise.futureResult.get()

            // We need to check the state here again since we just awaited above
            switch self.state {
            case .initial, .starting, .running, .shutdown:
                fatalError("Unexpected state")

            case .shuttingDown:
                self.state = .shutdown
            }

        case .shuttingDown(let shutdownPromise):
            try await shutdownPromise.futureResult.get()

        case .shutdown:
            break
        }
    }

    /// Wait on server. This won't return until `stop` has been called
    /// - Throws: `Error.serverNotRunning` if server hasn't fully started
    public func wait() async throws {
        switch self.state {
        case .initial, .starting:
            throw Error.serverNotRunning
        case .running(let channel, _):
            try await channel.closeFuture.get()
        case .shuttingDown(let shutdownPromise):
            try await shutdownPromise.futureResult.get()
        case .shutdown:
            break
        }
    }

    public var port: Int? {
        if case .running(let channel, _) = self.state {
            return channel.localAddress?.port
        } else if self.configuration.address.port != 0 {
            return self.configuration.address.port
        }
        return nil
    }

    private func makeServer(httpChannelInitializer: HBChannelInitializer, responder: HBHTTPResponder) async throws -> (Channel, ServerQuiescingHelper) {
        let idleTimeoutConfiguration = self.configuration.idleTimeoutConfiguration
        let handlerConfiguration = HBHTTPServerHandler.Configuration(
            maxUploadSize: self.configuration.maxUploadSize,
            maxStreamingBufferSize: self.configuration.maxStreamingBufferSize,
            serverName: self.configuration.serverName
        )
        @Sendable func childChannelInitializer(channel: Channel) -> EventLoopFuture<Void> {
            let childHandlers: [RemovableChannelHandler]
            if let idleTimeoutConfiguration = idleTimeoutConfiguration {
                childHandlers = [
                    IdleStateHandler(
                        readTimeout: idleTimeoutConfiguration.readTimeout,
                        writeTimeout: idleTimeoutConfiguration.writeTimeout
                    ),
                    HBHTTPServerHandler(responder: responder, configuration: handlerConfiguration),
                ]
            } else {
                childHandlers = [HBHTTPServerHandler(responder: responder, configuration: handlerConfiguration)]
            }
            return httpChannelInitializer.initialize(channel: channel, childHandlers: childHandlers, configuration: self.configuration)
        }

        let quiesce = ServerQuiescingHelper(group: self.eventLoopGroup)

        #if canImport(Network)
        let bootstrap: HTTPServerBootstrap
        if let tsBootstrap = self.createTSBootstrap(quiesce: quiesce, childChannelInitializer: childChannelInitializer) {
            bootstrap = tsBootstrap
        } else {
            #if os(iOS) || os(tvOS)
            responder.logger.warning("Running BSD sockets on iOS or tvOS is not recommended. Please use NIOTSEventLoopGroup, to run with the Network framework")
            #endif
            if #available(macOS 10.14, iOS 12, tvOS 12, *), self.configuration.tlsOptions.options != nil {
                logger.warning("tlsOptions set in Configuration will not be applied to a BSD sockets server. Please use NIOTSEventLoopGroup, to run with the Network framework")
            }
            bootstrap = self.createSocketsBootstrap(quiesce: quiesce, childChannelInitializer: childChannelInitializer)
        }
        #else
        let bootstrap = self.createSocketsBootstrap(quiesce: quiesce, childChannelInitializer: childChannelInitializer)
        #endif

        let channel: Channel
        switch self.configuration.address {
        case .hostname(let host, let port):
            channel = try await bootstrap.bind(host: host, port: port).get()
            self.logger.info("Server started and listening on \(host):\(port)")

        case .unixDomainSocket(let path):
            channel = try await bootstrap.bind(unixDomainSocketPath: path).get()
            self.logger.info("Server started and listening on socket path \(path)")
        }
        return (channel, quiesce)
    }

    /// create a BSD sockets based bootstrap
    private func createSocketsBootstrap(quiesce: ServerQuiescingHelper, childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> HTTPServerBootstrap {
        return ServerBootstrap(group: self.eventLoopGroup)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: numericCast(self.configuration.backlog))
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: self.configuration.reuseAddress ? 1 : 0)
            .serverChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: self.configuration.tcpNoDelay ? 1 : 0)
            .serverChannelInitializer { channel in
                channel.pipeline.addHandler(quiesce.makeServerChannelHandler(channel: channel))
            }
            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer(childChannelInitializer)

            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: self.configuration.reuseAddress ? 1 : 0)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: self.configuration.tcpNoDelay ? 1 : 0)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    #if canImport(Network)
    /// create a NIOTransportServices bootstrap using Network.framework
    private func createTSBootstrap(quiesce: ServerQuiescingHelper, childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> HTTPServerBootstrap? {
        guard let bootstrap = NIOTSListenerBootstrap(validatingGroup: self.eventLoopGroup)?
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: self.configuration.reuseAddress ? 1 : 0)
            .serverChannelInitializer({ channel in
                channel.pipeline.addHandler(quiesce.makeServerChannelHandler(channel: channel))
            })
            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer(childChannelInitializer)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: self.configuration.reuseAddress ? 1 : 0)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        else {
            return nil
        }

        if let tlsOptions = configuration.tlsOptions.options {
            return bootstrap.tlsOptions(tlsOptions)
        }
        return bootstrap
    }
    #endif
}

/// Protocol for bootstrap.
protocol HTTPServerBootstrap {
    func bind(host: String, port: Int) -> EventLoopFuture<Channel>
    func bind(unixDomainSocketPath: String) -> EventLoopFuture<Channel>
}

// Extend both `ServerBootstrap` and `NIOTSListenerBootstrap` to conform to `HTTPServerBootstrap`
extension ServerBootstrap: HTTPServerBootstrap {}
#if canImport(Network)
@available(macOS 10.14, iOS 12, tvOS 12, *)
extension NIOTSListenerBootstrap: HTTPServerBootstrap {}
#endif
