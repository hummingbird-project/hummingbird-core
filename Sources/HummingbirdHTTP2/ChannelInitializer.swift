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

import HummingbirdCore
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOSSL

/// Setup child channel for HTTP2
public struct HTTP2ChannelInitializer: HBChannelInitializer {
    /// Idle state handler configuration for HTTP2 channel
    public struct IdleStateHandlerConfiguration: Sendable {
        /// timeout when reading a request
        let readTimeout: TimeAmount
        /// timeout since last writing a response
        let writeTimeout: TimeAmount

        public init(readTimeout: TimeAmount = .seconds(30), writeTimeout: TimeAmount = .minutes(3)) {
            self.readTimeout = readTimeout
            self.writeTimeout = writeTimeout
        }

        public var idleStateHandler: IdleStateHandler {
            IdleStateHandler(readTimeout: self.readTimeout, writeTimeout: self.writeTimeout)
        }
    }

    /// Initialise HTTP2ChannelInitializer
    @available(*, deprecated, renamed: "init(idleTimeoutConfiguration:)")
    public init() {
        self.idleTimeoutConfiguration = nil
    }

    /// Initialise HTTP2ChannelInitializer
    /// - Parameter idleTimeoutConfiguration: Configure when server should close the channel based of idle events
    public init(idleTimeoutConfiguration: IdleStateHandlerConfiguration?) {
        self.idleTimeoutConfiguration = idleTimeoutConfiguration
    }

    public func initialize(channel: Channel, childHandlers: [RemovableChannelHandler], configuration: HBHTTPServer.Configuration) -> EventLoopFuture<Void> {
        func configureHTTP2Pipeline() -> EventLoopFuture<Void> {
            channel.configureHTTP2Pipeline(mode: .server) { streamChannel -> EventLoopFuture<Void> in
                return streamChannel.pipeline.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()).flatMap { _ in
                    streamChannel.pipeline.addHandlers(childHandlers)
                }
            }.flatMap { _ in
                channel.pipeline.addHandler(HTTP2UserEventHandler())
            }
        }
        if let idleTimeoutConfiguration = self.idleTimeoutConfiguration {
            return channel.pipeline.addHandler(idleTimeoutConfiguration.idleStateHandler).flatMap {
                configureHTTP2Pipeline()
            }
        } else {
            return configureHTTP2Pipeline()
        }
    }

    let idleTimeoutConfiguration: IdleStateHandlerConfiguration?
}

/// Setup child channel for HTTP2 upgrade
struct HTTP2UpgradeChannelInitializer: HBChannelInitializer {
    var http1: HTTP1ChannelInitializer
    let http2: HTTP2ChannelInitializer

    init(idleTimeoutConfiguration: HTTP2ChannelInitializer.IdleStateHandlerConfiguration?) {
        self.http1 = HTTP1ChannelInitializer()
        self.http2 = HTTP2ChannelInitializer(idleTimeoutConfiguration: idleTimeoutConfiguration)
    }

    func initialize(channel: Channel, childHandlers: [RemovableChannelHandler], configuration: HBHTTPServer.Configuration) -> EventLoopFuture<Void> {
        channel.configureHTTP2SecureUpgrade(
            h2ChannelConfigurator: { channel in
                self.http2.initialize(channel: channel, childHandlers: childHandlers, configuration: configuration)
            },
            http1ChannelConfigurator: { channel in
                self.http1.initialize(channel: channel, childHandlers: childHandlers, configuration: configuration)
            }
        )
    }

    ///  Add protocol upgrader to channel initializer
    /// - Parameter upgrader: HTTP server protocol upgrader to add
    public mutating func addProtocolUpgrader(_ upgrader: HTTPServerProtocolUpgrader) {
        self.http1.addProtocolUpgrader(upgrader)
    }
}
