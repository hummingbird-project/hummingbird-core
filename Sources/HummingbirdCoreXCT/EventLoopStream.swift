//
//  File.swift
//  
//
//  Created by Adam Fowler on 20/05/2021.
//

import NIO

/// Stream using a circular buffer of promises
class EventLoopStream<Value> {

    /// Queue of promises for each Value fed to the streamer. Last entry is always waiting for the next buffer or end tag
    var queue: CircularBuffer<EventLoopPromise<Value?>>
    /// EventLoop everything is running on
    let eventLoop: EventLoop

    init(on eventLoop: EventLoop) {
        self.queue = .init(initialCapacity: 8)
        self.queue.append(eventLoop.makePromise())
        self.eventLoop = eventLoop
    }

    /// shutdown stream
    func syncShutdown() throws {
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.eventLoop.execute {
            func _dropAll() {
                self.consume().map { output in
                    if output != nil {
                        _dropAll()
                    } else {
                        promise.succeed(())
                    }
                }
                .cascadeFailure(to: promise)
            }
            if self.queue.last != nil {
                self.end()
                _dropAll()
            } else {
                promise.succeed(())
            }
        }
        try promise.futureResult.wait()
    }

    /// Feed a Value to the stream
    /// - Parameter value: Value
    func feed(_ value: Value) {
        self.feed(.success(value))
    }

    /// Feed an Error to the stream
    /// - Parameter error: Error
    func error(_ error: Error) {
        self.feed(.failure(error))
    }

    /// Feed an end tag (nil)
    func end() {
        self.eventLoop.execute {
            // queue most have at least one promise on it, or something has gone wrong
            assert(self.queue.last != nil)
            let promise = self.queue.last!

            promise.succeed(nil)
        }
    }

    /// Consume what has been fed to the queue
    /// - Returns: Returns an EventLoopFuture that will be fulfilled with Value popped off end of stream
    func consume() -> EventLoopFuture<Value?> {
        self.eventLoop.flatSubmit {
            assert(self.queue.first != nil)
            let promise = self.queue.first!
            return promise.futureResult.map { result in
                _ = self.queue.popFirst()
                return result
            }
        }
    }

    private func feed(_ result: Result<Value, Error>) {
        self.eventLoop.execute {
            // queue most have at least one promise on it, or something has gone wrong
            assert(self.queue.last != nil)
            let promise = self.queue.last!

            self.queue.append(self.eventLoop.makePromise())
            promise.completeWith(result.map { $0 })
        }
    }
}
