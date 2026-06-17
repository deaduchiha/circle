import Foundation
import NIO
import NIOSSL

enum DoTDNSClient {
  static func query(
    endpoint: String,
    wireQuestion: Data,
    type: DNSRecordType,
    timeout: TimeInterval
  ) async throws -> [DNSRecord] {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let records = try querySync(
            endpoint: endpoint,
            wireQuestion: wireQuestion,
            type: type,
            timeout: timeout
          )
          continuation.resume(returning: records)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func querySync(
    endpoint: String,
    wireQuestion: Data,
    type: DNSRecordType,
    timeout: TimeInterval
  ) throws -> [DNSRecord] {
    let parts = endpoint.split(separator: ":", maxSplits: 1).map(String.init)
    let host = parts[0]
    let port = parts.count > 1 ? Int(parts[1]) ?? 853 : 853

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }

    let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
    let promise = group.next().makePromise(of: [DNSRecord].self)

    let bootstrap = ClientBootstrap(group: group)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          let sync = channel.pipeline.syncOperations
          try sync.addHandler(NIOSSLClientHandler(context: sslContext, serverHostname: host))
          try sync.addHandler(
            DoTQueryHandler(question: wireQuestion, expectedType: type, promise: promise)
          )
        }
      }

    let schedule = group.next().scheduleTask(in: .seconds(Int64(timeout))) {
      promise.fail(DNSResolverError.timeout)
    }

    bootstrap.connect(host: host, port: port).whenFailure { error in
      schedule.cancel()
      promise.fail(error)
    }

    promise.futureResult.whenComplete { _ in
      schedule.cancel()
    }

    return try promise.futureResult.wait()
  }
}

private final class DoTQueryHandler: ChannelDuplexHandler {
  typealias InboundIn = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private let question: Data
  private let expectedType: DNSRecordType
  private let promise: EventLoopPromise<[DNSRecord]>
  private var buffer = ByteBuffer()

  init(question: Data, expectedType: DNSRecordType, promise: EventLoopPromise<[DNSRecord]>) {
    self.question = question
    self.expectedType = expectedType
    self.promise = promise
  }

  func channelActive(context: ChannelHandlerContext) {
    var outbound = context.channel.allocator.buffer(capacity: question.count + 2)
    outbound.writeInteger(UInt16(question.count))
    outbound.writeBytes(question)
    context.writeAndFlush(self.wrapOutboundOut(outbound), promise: nil)
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var incoming = unwrapInboundIn(data)
    buffer.writeBuffer(&incoming)

    guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self) else { return }
    guard buffer.readableBytes >= Int(length) + 2 else { return }

    buffer.moveReaderIndex(forwardBy: 2)
    guard let slice = buffer.readSlice(length: Int(length)) else { return }

    do {
      let records = try DNSWireCodec.decodeResponse(Data(slice.readableBytesView), expectedType: expectedType)
      promise.succeed(records)
      context.close(promise: nil)
    } catch {
      promise.fail(error)
      context.close(promise: nil)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    promise.fail(error)
    context.close(promise: nil)
  }
}
