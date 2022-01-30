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

import NIOCore
import NIOHTTP1

#if swift(>=5.5) && canImport(_Concurrency)
public typealias HBSendable = Swift.Sendable
#else
public typealias HBSendable = Any
#endif


#if swift(>=5.5) && canImport(_Concurrency)
// imported symbols that need Sendable conformance
// from NIOCore
extension ByteBuffer: @unchecked HBSendable {}
extension TimeAmount: @unchecked HBSendable {}
// from NIOHTTP1
extension HTTPHeaders: @unchecked HBSendable {}
extension HTTPRequestHead: @unchecked HBSendable {}
extension HTTPResponseStatus: @unchecked HBSendable {}
extension HTTPResponseHead: @unchecked HBSendable {}

#endif // swift(>=5.5) && canImport(_Concurrency)
