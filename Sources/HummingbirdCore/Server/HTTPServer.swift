import NIO

public protocol HBHTTPServer: AnyObject {
    /// Server configuration
    var serverConfiguration: HBHTTPServerConfiguration { get }
    /// EventLoopGroup used by server
    var eventLoopGroup: EventLoopGroup { get }
    /// object initializing HTTP child handlers. This defaults to creating an HTTP1 channel
    var httpChannelInitializer: HBChannelInitializer { get set }
    /// array of child channel handlers
    var childChannelHandlers: HBHTTPChannelHandlers { get set }

    /// Start HTTP server
    /// - Parameter responder: HTTP responder providing responses for requests
    func start(responder: HBHTTPResponder) -> EventLoopFuture<Void>
    /// Stop HTTP server
    func stop() -> EventLoopFuture<Void>
    /// Wait while HTTP server is running
    func wait() throws

    /// Add TLS channel handler
    /// - Parameter handler: autoclosure generating TLS handler
    @discardableResult func addTLSChannelHandler(_ handler: @autoclosure @escaping () -> RemovableChannelHandler) -> Self
}

extension HBHTTPServer {
    /// Append to list of `ChannelHandler`s to be added to server child channels. Need to provide a closure so new instance of these handlers are
    /// created for each child channel
    /// - Parameters:
    ///   - handler: autoclosure generating handler
    @discardableResult public func addChannelHandler(_ handler: @autoclosure @escaping () -> RemovableChannelHandler) -> Self {
        childChannelHandlers.addHandler(handler())
        return self
    }

    /// Return all child channel handlers
    /// - Parameter responder: HTTP responder providing responses for requests
    public func getChildChannelHandlers(responder: HBHTTPResponder) -> [RemovableChannelHandler] {
        return childChannelHandlers.getHandlers() + [
            HBHTTPEncodeHandler(configuration: self.serverConfiguration),
            HBHTTPDecodeHandler(configuration: self.serverConfiguration),
            HBHTTPServerHandler(responder: responder),
        ]
    }
}

public protocol HBHTTPServerConfiguration {
    /// Bind address for server
    var address: HBBindAddress { get }
    /// Server name to return in "server" header
    var serverName: String? { get }
    /// Maximum upload size allowed
    var maxUploadSize: Int { get }
    /// Maximum size of buffer for streaming request payloads
    var maxStreamingBufferSize: Int { get }
    /// Allows socket to be bound to an address that is already in use.
    var reuseAddress: Bool { get }
    /// Pipelining ensures that only one http request is processed at one time
    var withPipeliningAssistance: Bool { get }
}
