import Foundation

public enum DNSRecordType: UInt16, Codable, CaseIterable, Sendable {
  case a = 1
  case aaaa = 28

  public var name: String {
    switch self {
    case .a: "A"
    case .aaaa: "AAAA"
    }
  }
}

public struct DNSRecord: Equatable, Sendable, Codable {
  public var type: DNSRecordType
  public var value: String
  public var ttl: Int

  public init(type: DNSRecordType, value: String, ttl: Int) {
    self.type = type
    self.value = value
    self.ttl = ttl
  }
}

public enum DNSResolverError: Error, LocalizedError, Equatable {
  case invalidHostname
  case invalidResponse
  case timeout
  case allServersFailed

  public var errorDescription: String? {
    switch self {
    case .invalidHostname:
      "Invalid hostname."
    case .invalidResponse:
      "Invalid DNS response."
    case .timeout:
      "DNS query timed out."
    case .allServersFailed:
      "All configured DNS servers failed to respond."
    }
  }
}

public struct DNSLookupResult: Equatable, Sendable {
  public var hostname: String
  public var recordType: DNSRecordType
  public var records: [DNSRecord]
  public var source: String
  public var latencyMilliseconds: Int
  public var fromCache: Bool

  public init(
    hostname: String,
    recordType: DNSRecordType,
    records: [DNSRecord],
    source: String,
    latencyMilliseconds: Int,
    fromCache: Bool
  ) {
    self.hostname = hostname
    self.recordType = recordType
    self.records = records
    self.source = source
    self.latencyMilliseconds = latencyMilliseconds
    self.fromCache = fromCache
  }
}

public struct DNSCacheEntrySnapshot: Identifiable, Equatable, Sendable {
  public var id: String { key }
  public var key: String
  public var hostname: String
  public var recordType: DNSRecordType
  public var records: [DNSRecord]
  public var expiresAt: Date

  public init(
    key: String,
    hostname: String,
    recordType: DNSRecordType,
    records: [DNSRecord],
    expiresAt: Date
  ) {
    self.key = key
    self.hostname = hostname
    self.recordType = recordType
    self.records = records
    self.expiresAt = expiresAt
  }
}

public protocol DNSResolver: Sendable {
  func resolve(hostname: String, type: DNSRecordType) async throws -> DNSLookupResult
}
