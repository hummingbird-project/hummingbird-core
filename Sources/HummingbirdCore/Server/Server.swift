import NIO

public protocol HBServer {
    func start(responder: HBHTTPResponder) -> EventLoopFuture<Void>
    func stop() -> EventLoopFuture<Void>
    func wait() throws
    
    @discardableResult func addChannelHandler(_ handler: @autoclosure @escaping () -> RemovableChannelHandler) -> Self
}
