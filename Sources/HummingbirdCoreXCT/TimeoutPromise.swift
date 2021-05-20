import NIO

public struct TimeoutPromise {
    let task: Scheduled<Void>
    let promise: EventLoopPromise<Void>

    public init(eventLoop: EventLoop, timeout: TimeAmount) {
        let promise = eventLoop.makePromise(of: Void.self)
        self.promise = promise
        self.task = eventLoop.scheduleTask(in: timeout) { promise.fail(ChannelError.connectTimeout(timeout)) }
    }

    public func succeed() {
        self.promise.succeed(())
    }

    public func fail(_ error: Error) {
        self.promise.fail(error)
    }

    public func wait() throws {
        try self.promise.futureResult.wait()
        self.task.cancel()
    }
}

