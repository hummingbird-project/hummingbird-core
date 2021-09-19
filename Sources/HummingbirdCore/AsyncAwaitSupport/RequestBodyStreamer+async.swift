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

#if compiler(>=5.5)

import NIOCore
import _NIOConcurrency

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HBStreamerProtocol {
    public var sequence: HBRequestBodyStreamerSequence { return .init(streamer: self) }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HBRequestBodyStreamer {
    public func consume() async throws -> HBRequestBodyStreamer.ConsumeOutput {
        return try await self.eventLoop.flatSubmit {
            self.consume()
        }.get()

    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HBByteBufferStreamer {
    public func consume() -> HBRequestBodyStreamer.ConsumeOutput {
        guard let output = self.byteBuffer.readSlice(length: self.byteBuffer.readableBytes) else {
            return .end
        }
        if output.readableBytes == 0 {
            return .end
        }
        return .byteBuffer(output)
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
public struct HBRequestBodyStreamerSequence: AsyncSequence {
    public typealias Element = ByteBuffer

    let streamer: HBStreamerProtocol

    public struct AsyncIterator: AsyncIteratorProtocol {
        let streamer: HBStreamerProtocol
        
        public func next() async throws -> ByteBuffer? {
            let output = try await self.streamer.consume()
            switch output {
            case .byteBuffer(let buffer):
                return buffer
            case .end:
                return nil
            }
        }
    }

    /// Make async iterator
    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(streamer: self.streamer)
    }
}

#endif // compiler(>=5.5)
