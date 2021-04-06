import NIO

/// Stores channel handlers used in HTTP server
public struct HBHTTPChannelHandlers {

    /// Initialize `HBHTTPChannelHandlers`
    public init() {
        self.handlers = []
    }

    /// Add autoclosure that creates a ChannelHandler
    public mutating func addHandler(_ handler: @autoclosure @escaping () -> RemovableChannelHandler) {
        handlers.append(handler)
    }

    /// Return array of ChannelHandlers
    public func getHandlers() -> [RemovableChannelHandler] {
        return handlers.map { $0()}
    }

    private var handlers: [() -> RemovableChannelHandler]
}