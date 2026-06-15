import Foundation
import NIO
import NIOHTTP1

public struct RequestTiming: Codable, Equatable, Sendable {
  public var dnsMilliseconds: Int?
  public var tcpConnectMilliseconds: Int?
  public var tlsMilliseconds: Int?
  public var ttfbMilliseconds: Int?
  public var totalMilliseconds: Int?

  public init(
    dnsMilliseconds: Int? = nil,
    tcpConnectMilliseconds: Int? = nil,
    tlsMilliseconds: Int? = nil,
    ttfbMilliseconds: Int? = nil,
    totalMilliseconds: Int? = nil
  ) {
    self.dnsMilliseconds = dnsMilliseconds
    self.tcpConnectMilliseconds = tcpConnectMilliseconds
    self.tlsMilliseconds = tlsMilliseconds
    self.ttfbMilliseconds = ttfbMilliseconds
    self.totalMilliseconds = totalMilliseconds
  }
}

public struct TrafficRequestDetail: Codable, Equatable, Sendable {
  public var requestHeaders: [String: String]
  public var responseHeaders: [String: String]
  public var requestBody: String?
  public var responseBody: String?
  public var timing: RequestTiming

  public init(
    requestHeaders: [String: String] = [:],
    responseHeaders: [String: String] = [:],
    requestBody: String? = nil,
    responseBody: String? = nil,
    timing: RequestTiming = RequestTiming()
  ) {
    self.requestHeaders = requestHeaders
    self.responseHeaders = responseHeaders
    self.requestBody = requestBody
    self.responseBody = responseBody
    self.timing = timing
  }
}

public enum TrafficCapture {
  private static let bodyPreviewLimit = 8_192

  public static func headers(from head: HTTPRequestHead) -> [String: String] {
    Dictionary(uniqueKeysWithValues: head.headers.map { ($0.name, $0.value) })
  }

  public static func headers(from head: HTTPResponseHead) -> [String: String] {
    Dictionary(uniqueKeysWithValues: head.headers.map { ($0.name, $0.value) })
  }

  public static func bodyPreview(from buffer: ByteBuffer) -> String? {
    guard buffer.readableBytes > 0 else { return nil }
    let bytes =
      buffer.getBytes(at: buffer.readerIndex, length: min(buffer.readableBytes, bodyPreviewLimit))
      ?? []
    let text = String(decoding: bytes, as: UTF8.self)
    if buffer.readableBytes > bodyPreviewLimit {
      return text + "\n…"
    }
    return text
  }

  public static func bodyPreview(from parts: [HTTPClientResponsePart]) -> String? {
    var buffer = ByteBuffer()
    for part in parts {
      if case .body(let chunk) = part {
        var copy = chunk
        buffer.writeBuffer(&copy)
      }
    }
    return bodyPreview(from: buffer)
  }

  public static func buildMITMRequest(
    id: UUID = UUID(),
    startedAt: Date,
    upstreamConnectedAt: Date?,
    responseStartedAt: Date?,
    finishedAt: Date,
    method: String,
    host: String,
    path: String,
    policy: String,
    matchedRule: String?,
    requestHead: HTTPRequestHead,
    requestBody: ByteBuffer,
    responseParts: [HTTPClientResponsePart]
  ) -> TrafficRequest {
    let responseHead = responseParts.compactMap { part -> HTTPResponseHead? in
      if case .head(let head) = part { return head }
      return nil
    }.first

    let total = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
    let tcp = upstreamConnectedAt.map { Int($0.timeIntervalSince(startedAt) * 1000) }
    let ttfb = responseStartedAt.map { Int($0.timeIntervalSince(startedAt) * 1000) }

    return TrafficRequest(
      id: id,
      timestamp: startedAt,
      method: method,
      host: host,
      path: path,
      statusCode: responseHead.map { Int($0.status.code) },
      bytesIn: requestBody.readableBytes,
      bytesOut: responseBodyBytes(from: responseParts),
      policy: policy,
      latencyMilliseconds: total,
      matchedRule: matchedRule,
      detail: TrafficRequestDetail(
        requestHeaders: headers(from: requestHead),
        responseHeaders: responseHead.map(headers(from:)) ?? [:],
        requestBody: bodyPreview(from: requestBody),
        responseBody: bodyPreview(from: responseParts),
        timing: RequestTiming(
          tcpConnectMilliseconds: tcp,
          tlsMilliseconds: tcp,
          ttfbMilliseconds: ttfb,
          totalMilliseconds: total
        )
      )
    )
  }

  private static func responseBodyBytes(from parts: [HTTPClientResponsePart]) -> Int {
    parts.reduce(0) { total, part in
      if case .body(let buffer) = part {
        return total + buffer.readableBytes
      }
      return total
    }
  }
}
