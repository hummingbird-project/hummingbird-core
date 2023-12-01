import NIOCore
import NIOHTTP2

final class HTTP2UserEventHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    enum State {
        case active(numberOpenStreams: Int)
        case quiescing(numberOpenStreams: Int)
        case closing
    }

    var state: State = .active(numberOpenStreams: 0)

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is NIOHTTP2StreamCreatedEvent:
            self.streamOpened()

        case is StreamClosedEvent:
            self.streamClosed(context: context)

        case is ChannelShouldQuiesceEvent:
            self.quiesce(context: context)

        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func streamOpened() {
        switch self.state {
        case .active(let numberOpenStreams):
            self.state = .active(numberOpenStreams: numberOpenStreams + 1)
        case .quiescing(let numberOpenStreams):
            self.state = .quiescing(numberOpenStreams: numberOpenStreams + 1)
        case .closing:
            assertionFailure("If we have initiated a close, then we should not be opening new streams.")
        }
    }

    func streamClosed(context: ChannelHandlerContext) {
        switch self.state {
        case .active(let numberOpenStreams):
            self.state = .active(numberOpenStreams: numberOpenStreams - 1)
        case .quiescing(let numberOpenStreams):
            if numberOpenStreams > 1 {
                self.state = .quiescing(numberOpenStreams: numberOpenStreams - 1)
            } else {
                self.state = .closing
                context.close(promise: nil)
            }
        case .closing:
            assertionFailure("If we have initiated a close, there should be no streams to close.")
        }
    }

    func quiesce(context: ChannelHandlerContext) {
        switch self.state {
        case .active(let numberOpenStreams):
            if numberOpenStreams > 0 {
                self.state = .quiescing(numberOpenStreams: numberOpenStreams)
            } else {
                self.state = .closing
                context.close(promise: nil)
            }
        case .quiescing, .closing:
            break
        }
    }
}
