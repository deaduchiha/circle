import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOWebSocket

public struct DashboardServerConfiguration: Sendable {
  public var host: String
  public var port: Int
  public var snapshotProvider: @Sendable () -> DashboardSnapshot
  public var onClientMessage: @Sendable (DashboardClientMessage) -> Void

  public init(
    host: String = "127.0.0.1",
    port: Int,
    snapshotProvider: @escaping @Sendable () -> DashboardSnapshot,
    onClientMessage: @escaping @Sendable (DashboardClientMessage) -> Void
  ) {
    self.host = host
    self.port = port
    self.snapshotProvider = snapshotProvider
    self.onClientMessage = onClientMessage
  }
}

public final class DashboardServer: @unchecked Sendable {
  private let configuration: DashboardServerConfiguration
  private let group: MultiThreadedEventLoopGroup
  private var channel: Channel?
  private let connectionsLock = NSLock()
  private var connections: [ObjectIdentifier: Channel] = [:]
  private let log = ProxyLogger.logger("dashboard")

  public init(configuration: DashboardServerConfiguration) {
    self.configuration = configuration
    self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  }

  public func start() throws {
    let snapshotProvider = configuration.snapshotProvider
    let onClientMessage = configuration.onClientMessage

    let upgrader = NIOWebSocketServerUpgrader(
      shouldUpgrade: { channel, _ in
        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
      },
      upgradePipelineHandler: { channel, _ in
        channel.pipeline.addHandler(
          DashboardWebSocketHandler(
            server: self,
            snapshotProvider: snapshotProvider,
            onClientMessage: onClientMessage
          )
        )
      }
    )

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline(
          withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
      }

    channel = try bootstrap.bind(host: configuration.host, port: configuration.port).wait()
    if let localAddress = channel?.localAddress {
      log.info("Dashboard listening", metadata: ["address": "\(localAddress)"])
    }
  }

  public func stop() throws {
    log.info("Stopping dashboard server")
    try channel?.close().wait()
    channel = nil
    try group.syncShutdownGracefully()
  }

  fileprivate func register(connection: Channel) {
    connectionsLock.lock()
    connections[ObjectIdentifier(connection)] = connection
    connectionsLock.unlock()
  }

  fileprivate func unregister(connection: Channel) {
    connectionsLock.lock()
    connections.removeValue(forKey: ObjectIdentifier(connection))
    connectionsLock.unlock()
  }

  public func broadcast(_ message: DashboardServerMessage) {
    guard let data = try? JSONEncoder().encode(message) else { return }
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)

    connectionsLock.lock()
    let targets = Array(connections.values)
    connectionsLock.unlock()

    for connection in targets {
      connection.eventLoop.execute {
        guard connection.isActive else { return }
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        connection.writeAndFlush(frame, promise: nil)
      }
    }
  }
}

private final class DashboardWebSocketHandler: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame

  private weak var server: DashboardServer?
  private let snapshotProvider: @Sendable () -> DashboardSnapshot
  private let onClientMessage: @Sendable (DashboardClientMessage) -> Void

  init(
    server: DashboardServer,
    snapshotProvider: @escaping @Sendable () -> DashboardSnapshot,
    onClientMessage: @escaping @Sendable (DashboardClientMessage) -> Void
  ) {
    self.server = server
    self.snapshotProvider = snapshotProvider
    self.onClientMessage = onClientMessage
  }

  func handlerAdded(context: ChannelHandlerContext) {
    server?.register(connection: context.channel)
    send(.snapshot(snapshotProvider()), on: context.channel)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    server?.unregister(connection: context.channel)
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    guard frame.opcode == .text,
      var bytes = frame.data.getBytes(at: 0, length: frame.data.readableBytes)
    else {
      return
    }

    guard let message = try? JSONDecoder().decode(DashboardClientMessage.self, from: Data(bytes))
    else {
      return
    }

    onClientMessage(message)

    if case .clear = message {
      send(.cleared, on: context.channel)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    server?.unregister(connection: context.channel)
  }

  private func send(_ message: DashboardServerMessage, on channel: Channel) {
    guard let data = try? JSONEncoder().encode(message) else { return }
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
    channel.writeAndFlush(frame, promise: nil)
  }
}
