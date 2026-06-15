import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOSSL

enum MITMEngine {
  private static let log = ProxyLogger.logger("mitm")

  static func upgradeClientChannel(
    _ channel: Channel,
    hostname: String,
    profile: Profile,
    ruleEngine: RuleEngine,
    certificateManager: CertificateManager,
    onRequest: @escaping @Sendable (TrafficRequest) -> Void
  ) -> EventLoopFuture<Void> {
    do {
      let serverTLS = try certificateManager.serverTLSConfiguration(for: hostname)
      let sslContext = try NIOSSLContext(configuration: serverTLS)
      let clientTLS = certificateManager.clientTLSConfiguration()
      let clientSSLContext = try NIOSSLContext(configuration: clientTLS)

      return channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext)).flatMap {
        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false)
      }.flatMap {
        channel.pipeline.addHandler(
          MITMHTTPProxyHandler(
            hostname: hostname,
            profile: profile,
            ruleEngine: ruleEngine,
            clientSSLContext: clientSSLContext,
            onRequest: onRequest
          )
        )
      }
    } catch {
      log.error(
        "MITM upgrade failed",
        metadata: ["host": "\(hostname)", "error": "\(error.localizedDescription)"]
      )
      return channel.eventLoop.makeFailedFuture(error)
    }
  }
}

private final class MITMHTTPProxyHandler: ChannelDuplexHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundIn = Never
  typealias OutboundOut = HTTPServerResponsePart

  private let hostname: String
  private let profile: Profile
  private let ruleEngine: RuleEngine
  private let clientSSLContext: NIOSSLContext
  private let onRequest: @Sendable (TrafficRequest) -> Void

  private var requestHead: HTTPRequestHead?
  private var requestBody = ByteBuffer()
  private var startedAt = Date()
  private var upstreamConnectedAt: Date?

  init(
    hostname: String,
    profile: Profile,
    ruleEngine: RuleEngine,
    clientSSLContext: NIOSSLContext,
    onRequest: @escaping @Sendable (TrafficRequest) -> Void
  ) {
    self.hostname = hostname
    self.profile = profile
    self.ruleEngine = ruleEngine
    self.clientSSLContext = clientSSLContext
    self.onRequest = onRequest
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let part = unwrapInboundIn(data)

    switch part {
    case .head(let head):
      requestHead = head
      startedAt = Date()
    case .body(var buffer):
      requestBody.writeBuffer(&buffer)
    case .end:
      guard let head = requestHead else {
        context.close(promise: nil)
        return
      }
      forwardDecryptedRequest(head: head, body: requestBody, context: context)
      requestHead = nil
      requestBody.clear()
    }
  }

  private func forwardDecryptedRequest(
    head: HTTPRequestHead, body: ByteBuffer, context: ChannelHandlerContext
  ) {
    let path = head.uri.contains("://") ? (URL(string: head.uri)?.path ?? head.uri) : head.uri
    let evaluation = PolicyRouter.evaluate(
      host: hostname,
      path: path,
      profile: profile,
      engine: ruleEngine
    )

    switch evaluation.route {
    case .reject:
      onRequest(
        TrafficRequest(
          method: head.method.rawValue,
          host: hostname,
          path: path,
          statusCode: 403,
          bytesIn: body.readableBytes,
          policy: evaluation.match?.policy ?? "DIRECT",
          matchedRule: evaluation.match.map { RuleFormatter.summary($0.rule) },
          detail: TrafficRequestDetail(
            requestHeaders: TrafficCapture.headers(from: head),
            requestBody: TrafficCapture.bodyPreview(from: body)
          )
        )
      )
      respond(context: context, status: .forbidden, body: "Rejected by policy")
    case .rejectTinyGIF:
      onRequest(
        TrafficRequest(
          method: head.method.rawValue,
          host: hostname,
          path: path,
          statusCode: 200,
          bytesIn: body.readableBytes,
          policy: evaluation.match?.policy ?? "DIRECT",
          matchedRule: evaluation.match.map { RuleFormatter.summary($0.rule) },
          detail: TrafficRequestDetail(
            requestHeaders: TrafficCapture.headers(from: head),
            requestBody: TrafficCapture.bodyPreview(from: body)
          )
        )
      )
      let gif = Data([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
      ])
      respond(context: context, status: .ok, body: gif, contentType: "image/gif")
    case .direct, .upstream:
      connectAndForward(
        head: head,
        body: body,
        context: context,
        evaluation: evaluation,
        path: path
      )
    }
  }

  private func connectAndForward(
    head: HTTPRequestHead,
    body: ByteBuffer,
    context: ChannelHandlerContext,
    evaluation: (route: ResolvedRoute, match: RuleMatch?),
    path: String
  ) {
    ClientBootstrap(group: context.eventLoop)
      .channelInitializer { outbound in
        do {
          let sslHandler = try NIOSSLClientHandler(
            context: self.clientSSLContext,
            serverHostname: self.hostname
          )
          return outbound.pipeline.addHandler(sslHandler).flatMap {
            outbound.pipeline.addHTTPClientHandlers()
          }
        } catch {
          return outbound.eventLoop.makeFailedFuture(error)
        }
      }
      .connect(host: hostname, port: 443)
      .flatMap { outbound in
        self.upstreamConnectedAt = Date()
        var forwardedHead = head
        if forwardedHead.uri.hasPrefix("/") {
          forwardedHead.uri = forwardedHead.uri
        } else if let url = URL(string: forwardedHead.uri), url.path.isEmpty == false {
          forwardedHead.uri = url.path
        }

        return outbound.write(HTTPClientRequestPart.head(forwardedHead)).flatMap {
          if body.readableBytes > 0 {
            return outbound.write(HTTPClientRequestPart.body(.byteBuffer(body)))
          }
          return outbound.eventLoop.makeSucceededVoidFuture()
        }.flatMap {
          outbound.writeAndFlush(HTTPClientRequestPart.end(nil))
        }.flatMap {
          self.relayHTTPResponse(
            from: outbound,
            to: context,
            requestHead: head,
            requestBody: body,
            evaluation: evaluation,
            path: path
          )
        }
      }
      .whenFailure { _ in
        self.respond(context: context, status: .badGateway, body: "MITM upstream connection failed")
      }
  }

  private func relayHTTPResponse(
    from upstream: Channel,
    to client: ChannelHandlerContext,
    requestHead: HTTPRequestHead,
    requestBody: ByteBuffer,
    evaluation: (route: ResolvedRoute, match: RuleMatch?),
    path: String
  ) -> EventLoopFuture<Void> {
    let collector = MITMResponseCollector(eventLoop: upstream.eventLoop)
    let responseStartedAt = Date()

    return upstream.pipeline.addHandler(collector).flatMap {
      collector.future
    }.flatMap { parts in
      let finishedAt = Date()
      self.onRequest(
        TrafficCapture.buildMITMRequest(
          startedAt: self.startedAt,
          upstreamConnectedAt: self.upstreamConnectedAt,
          responseStartedAt: responseStartedAt,
          finishedAt: finishedAt,
          method: requestHead.method.rawValue,
          host: self.hostname,
          path: path,
          policy: evaluation.match?.policy ?? "DIRECT",
          matchedRule: evaluation.match.map { RuleFormatter.summary($0.rule) },
          requestHead: requestHead,
          requestBody: requestBody,
          responseParts: parts
        )
      )

      var writeFuture = client.eventLoop.makeSucceededVoidFuture()
      for part in parts {
        switch part {
        case .head(let head):
          writeFuture = writeFuture.flatMap {
            client.write(self.wrapOutboundOut(.head(head)))
          }
        case .body(let buffer):
          writeFuture = writeFuture.flatMap {
            client.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))))
          }
        case .end:
          writeFuture = writeFuture.flatMap {
            client.writeAndFlush(self.wrapOutboundOut(.end(nil)))
          }
        }
      }
      return writeFuture
    }.flatMap {
      upstream.close()
    }
  }

  private func respond(
    context: ChannelHandlerContext, status: HTTPResponseStatus, body: String,
    contentType: String = "text/plain"
  ) {
    respond(context: context, status: status, body: Data(body.utf8), contentType: contentType)
  }

  private func respond(
    context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data, contentType: String
  ) {
    var head = HTTPResponseHead(version: .http1_1, status: status)
    head.headers.add(name: "Content-Type", value: contentType)
    head.headers.add(name: "Content-Length", value: "\(body.count)")
    head.headers.add(name: "Connection", value: "close")

    var buffer = context.channel.allocator.buffer(capacity: body.count)
    buffer.writeBytes(body)

    context.write(wrapOutboundOut(.head(head)), promise: nil)
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      context.close(promise: nil)
    }
  }
}

private final class MITMResponseCollector: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPClientResponsePart

  private let promise: EventLoopPromise<[HTTPClientResponsePart]>
  private var parts: [HTTPClientResponsePart] = []

  init(eventLoop: EventLoop) {
    promise = eventLoop.makePromise()
  }

  var future: EventLoopFuture<[HTTPClientResponsePart]> {
    promise.futureResult
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let part = unwrapInboundIn(data)
    parts.append(part)
    if case .end = part {
      promise.succeed(parts)
      context.pipeline.removeHandler(self, promise: nil)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    promise.fail(error)
    context.close(promise: nil)
  }
}
