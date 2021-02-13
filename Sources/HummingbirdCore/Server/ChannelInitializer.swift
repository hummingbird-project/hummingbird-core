import NIO

/// HTTPServer child channel initializer protocol
public protocol HBChannelInitializer {
    func initialize(channel: Channel, childHandlers: [ChannelHandler], configuration: HBHTTPServer.Configuration) -> EventLoopFuture<Void>
}

/// Setup child channel for HTTP1
public struct HTTP1ChannelInitializer: HBChannelInitializer {
    public init() {}

    public func initialize(channel: Channel, childHandlers: [ChannelHandler], configuration: HBHTTPServer.Configuration) -> EventLoopFuture<Void> {
        return channel.pipeline.configureHTTPServerPipeline(
            withPipeliningAssistance: configuration.withPipeliningAssistance,
            withErrorHandling: true
        ).flatMap {
            return channel.pipeline.addHandlers(childHandlers)
        }
    }
}
