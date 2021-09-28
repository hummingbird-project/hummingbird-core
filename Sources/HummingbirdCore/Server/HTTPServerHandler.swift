//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOCore
import NIOHTTP1

/// Channel handler for responding to a request and returning a response
final class HBHTTPServerHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    enum State {
        case idle
        case head(HTTPRequestHead)
        case body(HTTPRequestHead, ByteBuffer)
        case streamingBody(HBRequestBodyStreamer)
        case error
    }

    let responder: HBHTTPResponder
    let configuration: HBHTTPServer.Configuration

    var requestsInProgress: Int
    var closeAfterResponseWritten: Bool
    var propagatedError: Error?

    /// handler state
    var state: State

    init(responder: HBHTTPResponder, configuration: HBHTTPServer.Configuration) {
        self.responder = responder
        self.configuration = configuration
        self.requestsInProgress = 0
        self.closeAfterResponseWritten = false
        self.propagatedError = nil
        self.state = .idle
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.responder.handlerAdded(context: context)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.responder.handlerRemoved(context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)

        switch (part, self.state) {
        case (.head(let head), .idle):
            self.state = .head(head)

        case (.body(let part), .head(let head)):
            self.state = .body(head, part)

        case (.body(let part), .body(let head, let buffer)):
            let streamer = HBRequestBodyStreamer(eventLoop: context.eventLoop, maxSize: self.configuration.maxUploadSize)
            let request = HBHTTPRequest(head: head, body: .stream(streamer))
            streamer.feed(.byteBuffer(buffer))
            streamer.feed(.byteBuffer(part))
            self.state = .streamingBody(streamer)
            readRequest(context: context, request: request)

        case (.body(let part), .streamingBody(let streamer)):
            streamer.feed(.byteBuffer(part))
            self.state = .streamingBody(streamer)

        case (.end, .head(let head)):
            self.state = .idle
            let request = HBHTTPRequest(head: head, body: .byteBuffer(nil))
            readRequest(context: context, request: request)

        case (.end, .body(let head, let buffer)):
            self.state = .idle
            let request = HBHTTPRequest(head: head, body: .byteBuffer(buffer))
            readRequest(context: context, request: request)

        case (.end, .streamingBody(let streamer)):
            self.state = .idle
            streamer.feed(.end)

        case (.end, .error):
            self.state = .idle

        case (_, .error):
            break

        default:
            assertionFailure("Should not get here")
            context.close(promise: nil)
        }
    }

    func readRequest(context: ChannelHandlerContext, request: HBHTTPRequest) {
        // if error caught from previous channel handler then write an error
        if let error = propagatedError {
            let keepAlive = request.head.isKeepAlive && self.closeAfterResponseWritten == false
            var response = self.getErrorResponse(context: context, error: error, version: request.head.version)
            if request.head.version.major == 1 {
                response.head.headers.replaceOrAdd(name: "connection", value: keepAlive ? "keep-alive" : "close")
            }
            self.writeResponse(context: context, response: response, request: request, keepAlive: keepAlive)
            self.propagatedError = nil
            return
        }
        self.requestsInProgress += 1

        // respond to request
        self.responder.respond(to: request, context: context) { result in
            // should we keep the channel open after responding.
            let keepAlive = request.head.isKeepAlive && (self.closeAfterResponseWritten == false || self.requestsInProgress > 1)
            var response: HBHTTPResponse
            switch result {
            case .failure(let error):
                response = self.getErrorResponse(context: context, error: error, version: request.head.version)

            case .success(let successfulResponse):
                response = successfulResponse
            }
            if request.head.version.major == 1 {
                response.head.headers.replaceOrAdd(name: "connection", value: keepAlive ? "keep-alive" : "close")
            }
            // if we are already running inside the context eventloop don't use `EventLoop.execute`
            if context.eventLoop.inEventLoop {
                self.writeResponse(context: context, response: response, request: request, keepAlive: keepAlive)
            } else {
                context.eventLoop.execute {
                    self.writeResponse(context: context, response: response, request: request, keepAlive: keepAlive)
                }
            }
        }
    }

    func writeResponse(context: ChannelHandlerContext, response: HBHTTPResponse, request: HBHTTPRequest, keepAlive: Bool) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        writeParts(context: context, response: response, promise: promise)
        promise.futureResult.whenComplete { _ in
            // once we have finished writing the response we can drop the request body
            // if we are streaming we need to wait until the request has finished streaming
            if case .stream(let streamer) = request.body {
                streamer.drop().whenComplete { _ in
                    if keepAlive == false {
                        context.close(promise: nil)
                        self.closeAfterResponseWritten = false
                    }
                }
            } else {
                if keepAlive == false {
                    context.close(promise: nil)
                    self.closeAfterResponseWritten = false
                }
            }
            self.requestsInProgress -= 1
        }
    }

    func getErrorResponse(context: ChannelHandlerContext, error: Error, version: HTTPVersion) -> HBHTTPResponse {
        switch error {
        case let httpError as HBHTTPResponseError:
            // this is a processed error so don't log as Error
            self.responder.logger.debug("Error: \(error)")
            return httpError.response(version: version, allocator: context.channel.allocator)
        default:
            // this error has not been recognised
            self.responder.logger.info("Error: \(error)")
            return HBHTTPResponse(
                head: .init(version: version, status: .internalServerError),
                body: .empty
            )
        }
    }

    func writeParts(context: ChannelHandlerContext, response: HBHTTPResponse, promise: EventLoopPromise<Void>) {
        // add content-length header
        var head = response.head
        if case .byteBuffer(let buffer) = response.body {
            head.headers.replaceOrAdd(name: "content-length", value: buffer.readableBytes.description)
        }
        // server name
        if let serverName = self.configuration.serverName {
            head.headers.add(name: "server", value: serverName)
        }
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        switch response.body {
        case .byteBuffer(let buffer):
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: promise)
        case .stream(let streamer):
            streamer.write(on: context.eventLoop) { buffer in
                context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            .whenComplete { result in
                switch result {
                case .failure:
                    // not sure what do write when result is an error, sending .end and closing channel for the moment
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: promise)
                    context.close(promise: nil)
                case .success:
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: promise)
                }
            }
        case .empty:
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: promise)
        }
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            // The remote peer half-closed the channel. At this time, any
            // outstanding response will be written before the channel is
            // closed, and if we are idle we will close the channel immediately.
            if self.requestsInProgress > 0 {
                self.closeAfterResponseWritten = true
            } else {
                context.close(promise: nil)
            }

        case is ChannelShouldQuiesceEvent:
            // we received a quiesce event. If we have any requests in progress we should
            // wait for them to finish
            if self.requestsInProgress > 0 {
                self.closeAfterResponseWritten = true
            } else {
                context.close(promise: nil)
            }

        default:
            self.responder.logger.debug("Unhandled event \(event as? ChannelEvent)")
            context.fireUserInboundEventTriggered(event)
        }
    }

    func read(context: ChannelHandlerContext) {
        if case .streamingBody(let streamer) = self.state {
            guard streamer.currentSize < self.configuration.maxStreamingBufferSize else {
                streamer.onConsume = { streamer in
                    if streamer.currentSize < self.configuration.maxStreamingBufferSize {
                        context.read()
                    }
                }
                return
            }
        }
        context.read()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.propagatedError = error
        switch self.state {
        case .streamingBody(let streamer):
            // request has already been forwarded, have to pass error via streamer
            streamer.feed(.error(error))
            // only set state to error if already streaming a request body. Don't want to feed
            // additional ByteBuffers to streamer if error has been set
            self.state = .error
        default:
            self.propagatedError = error
        }
    }
}
