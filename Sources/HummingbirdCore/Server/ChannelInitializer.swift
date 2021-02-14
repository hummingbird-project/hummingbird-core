import NIO
import NIOHTTP1

/// HTTPServer child channel initializer protocol
public protocol HBChannelInitializer {
    func initialize(channel: Channel, childHandlers: [RemovableChannelHandler], configuration: HBHTTPServer.Configuration) -> EventLoopFuture<Void>
}

/// Setup child channel for HTTP1
public struct HTTP1ChannelInitializer: HBChannelInitializer {
    public init(upgraders: [HTTPServerProtocolUpgrader] = []) {
        print("Upgraders: \(upgraders)")
        self.upgraders = upgraders
    }

    public func initialize(channel: Channel, childHandlers: [RemovableChannelHandler], configuration: HBHTTPServer.Configuration) -> EventLoopFuture<Void> {
        var serverUpgrade: NIOHTTPServerUpgradeConfiguration?
        if self.upgraders.count > 0 {
            serverUpgrade = (self.upgraders, { channel in
                print("Core: Upgraded")
                childHandlers.forEach {
                    channel.pipeline.removeHandler($0)
                }
            })
        }
        return channel.pipeline.configureHTTPServerPipeline(
            withPipeliningAssistance: configuration.withPipeliningAssistance,
            withServerUpgrade: serverUpgrade,
            withErrorHandling: true
        ).flatMap {
            return channel.pipeline.addHandlers(childHandlers)
        }
    }

    let upgraders: [HTTPServerProtocolUpgrader]
}
