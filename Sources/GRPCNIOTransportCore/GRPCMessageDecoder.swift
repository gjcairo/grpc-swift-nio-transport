/*
 * Copyright 2024, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

internal import GRPCCore
package import NIOCore

/// A ``GRPCMessageDecoder`` helps with the deframing of gRPC data frames:
/// - It reads the frame's metadata to know whether the message payload is compressed or not, and its length
/// - It reads and decompresses the payload, if compressed
/// - It helps put together frames that have been split across multiple `ByteBuffers` by the underlying transport
struct GRPCMessageDecoder: NIOSingleStepByteToMessageDecoder {
  /// Length of the gRPC message header (1 compression byte, 4 bytes for the length).
  static let metadataLength = 5

  typealias InboundOut = ByteBuffer

  private let decompressor: Zlib.Decompressor?
  private let maxPayloadSize: Int

  /// Create a new ``GRPCMessageDeframer``.
  /// - Parameters:
  ///   - maxPayloadSize: The maximum size a message payload can be.
  ///   - decompressor: A `Zlib.Decompressor` to use when decompressing compressed gRPC messages.
  /// - Important: You must call `end()` on the `decompressor` when you're done using it, to clean
  /// up any resources allocated by `Zlib`.
  init(
    maxPayloadSize: Int,
    decompressor: Zlib.Decompressor? = nil
  ) {
    self.maxPayloadSize = maxPayloadSize
    self.decompressor = decompressor
  }

  mutating func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
    guard buffer.readableBytes >= Self.metadataLength else {
      // If we cannot read enough bytes to cover the metadata's length, then we
      // need to wait for more bytes to become available to us.
      return nil
    }

    // Store the current reader index in case we don't yet have enough
    // bytes in the buffer to decode a full frame, and need to reset it.
    // The force-unwraps for the compression flag and message length are safe,
    // because we've checked just above that we've got at least enough bytes to
    // read all of the metadata.
    let originalReaderIndex = buffer.readerIndex
    let isMessageCompressed = buffer.readInteger(as: UInt8.self)! == 1
    let messageLength = buffer.readInteger(as: UInt32.self)!

    if messageLength > self.maxPayloadSize {
      throw RPCError(
        code: .resourceExhausted,
        message: """
          Message has exceeded the configured maximum payload size \
          (max: \(self.maxPayloadSize), actual: \(messageLength))
          """
      )
    }

    guard var message = buffer.readSlice(length: Int(messageLength)) else {
      // `ByteBuffer/readSlice(length:)` returns nil when there are not enough
      // bytes to read the requested length. This can happen if we don't yet have
      // enough bytes buffered to read the full message payload.
      // By reading the metadata though, we have already moved the reader index,
      // so we must reset it to its previous, original position for now,
      // and return. We'll try decoding again, once more bytes become available
      // in our buffer.
      buffer.moveReaderIndex(to: originalReaderIndex)
      return nil
    }

    if isMessageCompressed {
      guard let decompressor = self.decompressor else {
        // We cannot decompress the payload - throw an error.
        throw RPCError(
          code: .internalError,
          message: "Received a compressed message payload, but no decompressor has been configured."
        )
      }
      return try decompressor.decompress(&message, limit: self.maxPayloadSize)
    } else {
      return message
    }
  }

  mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
    try self.decode(buffer: &buffer)
  }
}

package struct GRPCMessageDeframer {
  private var decoder: GRPCMessageDecoder
  private var buffer: Optional<ByteBuffer>

  package var _readerIndex: Int? {
    self.buffer?.readerIndex
  }

  init(maxPayloadSize: Int, decompressor: Zlib.Decompressor?) {
    self.decoder = GRPCMessageDecoder(
      maxPayloadSize: maxPayloadSize,
      decompressor: decompressor
    )
    self.buffer = nil
  }

  package init(maxPayloadSize: Int) {
    self.decoder = GRPCMessageDecoder(maxPayloadSize: maxPayloadSize, decompressor: nil)
    self.buffer = nil
  }

  package mutating func append(_ buffer: ByteBuffer) {
    if self.buffer == nil || self.buffer!.readableBytes == 0 {
      self.buffer = buffer
    } else {
      // Avoid having too many read bytes in the buffer which can lead to the buffer growing much
      // larger than is necessary.
      let readerIndex = self.buffer!.readerIndex
      if readerIndex > 1024 && readerIndex > (self.buffer!.capacity / 2) {
        self.buffer!.discardReadBytes()
      }
      self.buffer!.writeImmutableBuffer(buffer)
    }
  }

  package mutating func decodeNext() throws -> ByteBuffer? {
    guard (self.buffer?.readableBytes ?? 0) > 0 else { return nil }
    // Above checks mean this is both non-nil and non-empty.
    let message = try self.decoder.decode(buffer: &self.buffer!)
    return message
  }
}

extension GRPCMessageDeframer {
  mutating func decode(into queue: inout OneOrManyQueue<ByteBuffer>) throws {
    while let next = try self.decodeNext() {
      queue.append(next)
    }
  }
}
