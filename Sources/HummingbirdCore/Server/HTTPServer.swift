import NIO

public protocol HBHTTPServer: AnyObject {
    /// Server configuration
    var serverConfiguration: HBHTTPServerConfiguration { get }
    /// EventLoopGroup used by server
    var eventLoopGroup: EventLoopGroup { get }
    /// object initializing HTTP child handlers. This defaults to creating an HTTP1 channel
    var httpChannelInitializer: HBChannelInitializer { get set }
    /// array of child channel handlers
    var childChannelHandlers: [() -> RemovableChannelHandler] { get set }

    func start(responder: HBHTTPResponder) -> EventLoopFuture<Void>
    func stop() -> EventLoopFuture<Void>
    func wait() throws
    
    @discardableResult func addTLSChannelHandler(_ handler: @autoclosure @escaping () -> RemovableChannelHandler) -> Self

}

extension HBHTTPServer {
    /// Append to list of `ChannelHandler`s to be added to server child channels. Need to provide a closure so new instance of these handlers are
    /// created for each child channel
    /// - Parameters:
    ///   - handler: autoclosure generating handler
    @discardableResult public func addChannelHandler(_ handler: @autoclosure @escaping () -> RemovableChannelHandler) -> Self {
        childChannelHandlers.append(handler)
        return self
    }

    public func getChildChannelHandlers(responder: HBHTTPResponder) -> [RemovableChannelHandler] {
        return childChannelHandlers.map { $0()} + [
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
