import NIO

public protocol HBHTTPServer: AnyObject {
    /// Server configuration
    var configuration: HBHTTPServerConfiguration { get }
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
            HBHTTPEncodeHandler(configuration: self.configuration),
            HBHTTPDecodeHandler(configuration: self.configuration),
            HBHTTPServerHandler(responder: responder),
        ]
    }
}

/// HTTP server configuration
public struct HBHTTPServerConfiguration {
    /// Bind address for server
    public let address: HBBindAddress
    /// Server name to return in "server" header
    public let serverName: String?
    /// Maximum upload size allowed
    public let maxUploadSize: Int
    /// Maximum size of buffer for streaming request payloads
    public let maxStreamingBufferSize: Int
    /// Defines the maximum length for the queue of pending connections
    public let backlog: Int
    /// Allows socket to be bound to an address that is already in use.
    public let reuseAddress: Bool
    /// Disables the Nagle algorithm for send coalescing.
    public let tcpNoDelay: Bool
    /// Pipelining ensures that only one http request is processed at one time
    public let withPipeliningAssistance: Bool

    /// Initialize HTTP server configuration
    /// - Parameters:
    ///   - address: Bind address for server
    ///   - serverName: Server name to return in "server" header
    ///   - maxUploadSize: Maximum upload size allowed
    ///   - maxStreamingBufferSize: Maximum size of buffer for streaming request payloads
    ///   - reuseAddress: Allows socket to be bound to an address that is already in use.
    ///   - tcpNoDelay: Disables the Nagle algorithm for send coalescing.
    ///   - withPipeliningAssistance: Pipelining ensures that only one http request is processed at one time
    public init(
        address: HBBindAddress = .hostname(),
        serverName: String? = nil,
        maxUploadSize: Int = 2 * 1024 * 1024,
        maxStreamingBufferSize: Int = 1 * 1024 * 1024,
        backlog: Int = 256,
        reuseAddress: Bool = true,
        tcpNoDelay: Bool = false,
        withPipeliningAssistance: Bool = true
    ) {
        self.address = address
        self.serverName = serverName
        self.maxUploadSize = maxUploadSize
        self.maxStreamingBufferSize = maxStreamingBufferSize
        self.backlog = backlog
        self.reuseAddress = reuseAddress
        self.tcpNoDelay = tcpNoDelay
        self.withPipeliningAssistance = withPipeliningAssistance
    }
}
