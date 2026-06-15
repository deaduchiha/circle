import Foundation
import Logging
import NIO
import NIOHTTP1

public struct ProxyServerConfiguration: Sendable {
  public var host: String
  public var port: Int
  public var profile: Profile
  public var ruleEngine: RuleEngine
  public var certificateManager: CertificateManager
  public var onRequest: @Sendable (TrafficRequest) -> Void

  public init(
    host: String = "127.0.0.1",
    port: Int,
    profile: Profile,
    ruleEngine: RuleEngine? = nil,
    certificateManager: CertificateManager = .shared,
    onRequest: @escaping @Sendable (TrafficRequest) -> Void
  ) {
    self.host = host
    self.port = port
    self.profile = profile
    self.ruleEngine = ruleEngine ?? RuleEngine(rules: profile.rules)
    self.certificateManager = certificateManager
    self.onRequest = onRequest
  }
}

public final class ProxyServer: @unchecked Sendable {
  private let configuration: ProxyServerConfiguration
  private let group: MultiThreadedEventLoopGroup
  private var channel: Channel?
  private let log = ProxyLogger.logger("proxy")

  public init(configuration: ProxyServerConfiguration) {
    self.configuration = configuration
    self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
  }

  public func start() throws {
    let profile = configuration.profile
    let ruleEngine = configuration.ruleEngine
    let certificateManager = configuration.certificateManager
    let onRequest = configuration.onRequest

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 256)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          let sync = channel.pipeline.syncOperations
          try sync.addHandler(
            ByteToMessageHandler(
              HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)
            ),
            name: "httpDecoder",
            position: .last
          )
          try sync.addHandler(HTTPResponseEncoder(), name: "httpEncoder", position: .last)
          try sync.addHandler(
            HTTPProxyHandler(
              profile: profile,
              ruleEngine: ruleEngine,
              certificateManager: certificateManager,
              onRequest: onRequest
            ),
            name: "httpProxy",
            position: .last
          )
        }
      }

    channel = try bootstrap.bind(host: configuration.host, port: configuration.port).wait()
    if let localAddress = channel?.localAddress {
      log.info("Proxy listening", metadata: ["address": "\(localAddress)"])
    }
  }

  public func stop() throws {
    log.info("Stopping proxy server")
    try channel?.close().wait()
    channel = nil
    try group.syncShutdownGracefully()
  }
}

private final class HTTPProxyHandler: ChannelDuplexHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundIn = Never
  typealias OutboundOut = HTTPServerResponsePart

  private let profile: Profile
  private let ruleEngine: RuleEngine
  private let certificateManager: CertificateManager
  private let onRequest: @Sendable (TrafficRequest) -> Void
  private var requestHead: HTTPRequestHead?
  private var requestBody = ByteBuffer()
  private var startedAt = Date()

  init(
    profile: Profile,
    ruleEngine: RuleEngine,
    certificateManager: CertificateManager,
    onRequest: @escaping @Sendable (TrafficRequest) -> Void
  ) {
    self.profile = profile
    self.ruleEngine = ruleEngine
    self.certificateManager = certificateManager
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
      handleRequest(head: head, body: requestBody, context: context)
      requestHead = nil
      requestBody.clear()
    }
  }

  private func handleRequest(
    head: HTTPRequestHead, body: ByteBuffer, context: ChannelHandlerContext
  ) {
    let target = parseTarget(from: head)
    let evaluation = PolicyRouter.evaluate(
      host: target.host,
      path: target.path,
      profile: profile,
      engine: ruleEngine
    )

    switch evaluation.route {
    case .reject:
      logRequest(head: head, body: body, target: target, evaluation: evaluation)
      respond(context: context, status: .forbidden, body: "Rejected by policy")
    case .rejectTinyGIF:
      logRequest(head: head, body: body, target: target, evaluation: evaluation)
      let gif = Data([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
      ])
      respond(context: context, status: .ok, body: gif, contentType: "image/gif")
    case .direct:
      if head.method == .CONNECT {
        if shouldMITM(target: target, proxy: nil) {
          openMITMTunnel(to: target, clientContext: context)
        } else {
          logRequest(head: head, body: body, target: target, evaluation: evaluation)
          openTunnel(to: target, through: nil, clientContext: context)
        }
      } else {
        logRequest(head: head, body: body, target: target, evaluation: evaluation)
        forwardHTTP(head: head, body: body, to: target, through: nil, context: context)
      }
    case .upstream(let proxy):
      if head.method == .CONNECT {
        logRequest(head: head, body: body, target: target, evaluation: evaluation)
        openTunnel(to: target, through: proxy, clientContext: context)
      } else {
        logRequest(head: head, body: body, target: target, evaluation: evaluation)
        forwardHTTP(head: head, body: body, to: target, through: proxy, context: context)
      }
    }
  }

  private func logRequest(
    head: HTTPRequestHead,
    body: ByteBuffer,
    target: ProxyTarget,
    evaluation: (route: ResolvedRoute, match: RuleMatch?)
  ) {
    let latency = Int(Date().timeIntervalSince(startedAt) * 1000)

    onRequest(
      TrafficRequest(
        method: head.method.rawValue,
        host: target.host,
        path: target.port == 443 ? ":\(target.port)" : target.path,
        statusCode: routeStatusCode(evaluation.route),
        bytesIn: body.readableBytes,
        bytesOut: 0,
        policy: evaluation.match?.policy ?? "DIRECT",
        latencyMilliseconds: latency,
        matchedRule: evaluation.match.map { RuleFormatter.summary($0.rule) }
      )
    )
  }

  private func shouldMITM(target: ProxyTarget, proxy: ProxyConfig?) -> Bool {
    proxy == nil
      && target.port == 443
      && certificateManager.shouldIntercept(hostname: target.host, mitm: profile.mitm)
  }

  private func openMITMTunnel(to target: ProxyTarget, clientContext: ChannelHandlerContext) {
    var response = HTTPResponseHead(version: .http1_1, status: .ok)
    response.headers.add(name: "Connection", value: "close")
    clientContext.write(wrapOutboundOut(.head(response)), promise: nil)

    clientContext.writeAndFlush(wrapOutboundOut(.end(nil)))
      .flatMap {
        self.removeHTTPServerCodec(from: clientContext.channel)
      }
      .flatMap {
        MITMEngine.upgradeClientChannel(
          clientContext.channel,
          hostname: target.host,
          profile: self.profile,
          ruleEngine: self.ruleEngine,
          certificateManager: self.certificateManager,
          onRequest: self.onRequest
        )
      }
      .whenFailure { _ in
        self.respond(
          context: clientContext, status: .badGateway, body: "Unable to start HTTPS decryption")
      }
  }

  private func removeHTTPServerCodec(from channel: Channel) -> EventLoopFuture<Void> {
    channel.pipeline.removeHandler(name: "httpProxy").flatMap {
      channel.pipeline.removeHandler(name: "httpEncoder")
    }.flatMap {
      channel.pipeline.removeHandler(name: "httpDecoder")
    }
  }

  private func openTunnel(
    to target: ProxyTarget, through proxy: ProxyConfig?, clientContext: ChannelHandlerContext
  ) {
    let outboundFuture: EventLoopFuture<Channel>
    if let proxy {
      outboundFuture = connectToProxy(proxy, eventLoop: clientContext.eventLoop)
    } else {
      outboundFuture = connectDirect(to: target, eventLoop: clientContext.eventLoop)
    }

    outboundFuture
      .flatMap { outbound in
        if let proxy {
          return self.sendProxyConnect(target: target, through: proxy, on: outbound).map {
            outbound
          }
        }
        return clientContext.eventLoop.makeSucceededFuture(outbound)
      }
      .flatMap { outbound in
        var response = HTTPResponseHead(version: .http1_1, status: .ok)
        response.headers.add(name: "Connection", value: "close")
        clientContext.write(self.wrapOutboundOut(.head(response)), promise: nil)
        return clientContext.writeAndFlush(self.wrapOutboundOut(.end(nil))).map { outbound }
      }
      .flatMap { outbound in
        self.stripHTTPCodec(from: clientContext.channel).flatMap {
          self.stripHTTPCodec(from: outbound)
        }.map { outbound }
      }
      .flatMap { outbound in
        self.installRelay(client: clientContext.channel, remote: outbound)
      }
      .whenFailure { _ in
        self.respond(
          context: clientContext, status: .badGateway, body: "Unable to establish tunnel")
      }
  }

  private func forwardHTTP(
    head: HTTPRequestHead, body: ByteBuffer, to target: ProxyTarget, through proxy: ProxyConfig?,
    context: ChannelHandlerContext
  ) {
    let outboundFuture: EventLoopFuture<Channel>
    if let proxy {
      outboundFuture = connectToProxy(proxy, eventLoop: context.eventLoop)
    } else {
      outboundFuture = connectDirect(to: target, eventLoop: context.eventLoop)
    }

    outboundFuture
      .flatMap { outbound in
        outbound.pipeline.addHTTPClientHandlers().flatMap {
          var forwardedHead = head
          forwardedHead.uri = proxy == nil ? target.path : self.absoluteURI(for: target)
          forwardedHead.headers.remove(name: "proxy-connection")

          return outbound.write(HTTPClientRequestPart.head(forwardedHead)).flatMap {
            if body.readableBytes > 0 {
              return outbound.write(HTTPClientRequestPart.body(.byteBuffer(body)))
            }
            return outbound.eventLoop.makeSucceededVoidFuture()
          }.flatMap {
            outbound.writeAndFlush(HTTPClientRequestPart.end(nil))
          }.map { outbound }
        }
      }
      .flatMap { outbound in
        self.stripHTTPCodec(from: context.channel).flatMap {
          self.stripHTTPCodec(from: outbound)
        }.map { outbound }
      }
      .flatMap { outbound in
        self.installRelay(client: context.channel, remote: outbound)
      }
      .whenFailure { _ in
        self.respond(context: context, status: .badGateway, body: "Unable to forward request")
      }
  }

  private func connectDirect(to target: ProxyTarget, eventLoop: EventLoop) -> EventLoopFuture<
    Channel
  > {
    ClientBootstrap(group: eventLoop)
      .connect(host: target.host, port: target.port)
  }

  private func connectToProxy(_ proxy: ProxyConfig, eventLoop: EventLoop) -> EventLoopFuture<
    Channel
  > {
    ClientBootstrap(group: eventLoop)
      .connect(host: proxy.host, port: proxy.port)
  }

  private func sendProxyConnect(
    target: ProxyTarget, through proxy: ProxyConfig, on channel: Channel
  ) -> EventLoopFuture<Void> {
    var head = HTTPRequestHead(
      version: .http1_1, method: .CONNECT, uri: "\(target.host):\(target.port)")
    head.headers.add(name: "Host", value: "\(target.host):\(target.port)")
    if let username = proxy.parameters["username"], let password = proxy.parameters["password"] {
      let token = Data("\(username):\(password)".utf8).base64EncodedString()
      head.headers.add(name: "Proxy-Authorization", value: "Basic \(token)")
    }

    let requestHead = head
    let collector = HTTPResponseCollector(eventLoop: channel.eventLoop)

    return channel.pipeline.addHTTPClientHandlers().flatMap {
      channel.pipeline.addHandler(collector)
    }.flatMap {
      channel.write(HTTPClientRequestPart.head(requestHead))
    }.flatMap {
      channel.writeAndFlush(HTTPClientRequestPart.end(nil))
    }.flatMap {
      collector.future
    }.flatMap { response in
      guard response.status == .ok else {
        return channel.eventLoop.makeFailedFuture(ProxyForwardingError.upstreamRejected)
      }
      return channel.eventLoop.makeSucceededVoidFuture()
    }
  }

  private func installRelay(client: Channel, remote: Channel) -> EventLoopFuture<Void> {
    client.pipeline.addHandler(ByteRelayHandler(partner: remote)).flatMap { _ in
      remote.pipeline.addHandler(ByteRelayHandler(partner: client))
    }.map { _ in () }
  }

  private func stripHTTPCodec(from channel: Channel) -> EventLoopFuture<Void> {
    channel.eventLoop.makeSucceededVoidFuture()
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

  private func parseTarget(from head: HTTPRequestHead) -> ProxyTarget {
    if head.method == .CONNECT {
      let parts = head.uri.split(separator: ":", maxSplits: 1)
      let host = String(parts.first ?? "")
      let port = parts.count > 1 ? Int(parts[1]) ?? 443 : 443
      return ProxyTarget(host: host, port: port, path: "/")
    }

    if let url = URL(string: head.uri), let host = url.host {
      let port = url.port ?? (url.scheme == "https" ? 443 : 80)
      return ProxyTarget(host: host, port: port, path: url.path.isEmpty ? "/" : url.path)
    }

    let hostHeader = head.headers.first(name: "Host") ?? "localhost"
    let hostParts = hostHeader.split(separator: ":")
    let host = String(hostParts.first ?? "localhost")
    let port = hostParts.dropFirst().first.flatMap { Int($0) } ?? 80
    return ProxyTarget(host: host, port: port, path: head.uri)
  }

  private func absoluteURI(for target: ProxyTarget) -> String {
    let scheme = target.port == 443 ? "https" : "http"
    return "\(scheme)://\(target.host):\(target.port)\(target.path)"
  }

  private func routeStatusCode(_ route: ResolvedRoute) -> Int? {
    switch route {
    case .reject:
      return 403
    case .rejectTinyGIF:
      return 200
    case .direct, .upstream:
      return nil
    }
  }
}

private struct ProxyTarget: Equatable {
  var host: String
  var port: Int
  var path: String
}

private enum ProxyForwardingError: Error {
  case upstreamRejected
}

private final class ByteRelayHandler: ChannelDuplexHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private let partner: Channel

  init(partner: Channel) {
    self.partner = partner
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    partner.writeAndFlush(unwrapInboundIn(data), promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    partner.close(mode: .all, promise: nil)
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    context.fireErrorCaught(error)
    partner.close(mode: .all, promise: nil)
  }
}

private final class HTTPResponseCollector: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPClientResponsePart

  private let promise: EventLoopPromise<HTTPResponseHead>

  init(eventLoop: EventLoop) {
    promise = eventLoop.makePromise()
  }

  var future: EventLoopFuture<HTTPResponseHead> {
    promise.futureResult
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let part = unwrapInboundIn(data)
    switch part {
    case .head(let head):
      promise.succeed(head)
      context.pipeline.removeHandler(self, promise: nil)
    case .body, .end:
      break
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    promise.fail(error)
    context.close(promise: nil)
  }
}
