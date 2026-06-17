import Foundation

public struct DNSResolverEngine: DNSResolver, Sendable {
  public var config: DNSConfig
  public var hosts: [String: String]
  public var cache: DNSCache
  public var timeout: TimeInterval

  public init(
    config: DNSConfig,
    hosts: [String: String] = [:],
    cache: DNSCache = DNSCache(),
    timeout: TimeInterval = 5
  ) {
    self.config = config
    self.hosts = hosts
    self.cache = cache
    self.timeout = timeout
  }

  public func resolve(hostname: String, type: DNSRecordType) async throws -> DNSLookupResult {
    let normalized = hostname.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw DNSResolverError.invalidHostname }

    if let cached = cache.lookup(hostname: normalized, type: type) {
      return DNSLookupResult(
        hostname: normalized,
        recordType: type,
        records: cached,
        source: "cache",
        latencyMilliseconds: 0,
        fromCache: true
      )
    }

    if let mapped = hosts[normalized] {
      let record = DNSRecord(type: type, value: mapped, ttl: 300)
      cache.store(hostname: normalized, type: type, records: [record])
      return DNSLookupResult(
        hostname: normalized,
        recordType: type,
        records: [record],
        source: "hosts",
        latencyMilliseconds: 0,
        fromCache: false
      )
    }

    let question = try DNSWireCodec.encodeQuery(hostname: normalized, type: type)
    let startedAt = Date()

    return try await withThrowingTaskGroup(of: Result<DNSLookupResult, Error>.self) { group in
      for server in config.servers {
        let serverName = server
        group.addTask {
          do {
            let response = try await UDPDNSClient.query(
              server: serverName,
              question: question,
              timeout: timeout
            )
            let records = try DNSWireCodec.decodeResponse(response, expectedType: type)
            guard !records.isEmpty else { throw DNSResolverError.invalidResponse }
            return Result<DNSLookupResult, Error>.success(
              DNSLookupResult(
                hostname: normalized,
                recordType: type,
                records: records,
                source: "udp://\(serverName)",
                latencyMilliseconds: max(1, Int(Date().timeIntervalSince(startedAt) * 1000)),
                fromCache: false
              )
            )
          } catch {
            return Result<DNSLookupResult, Error>.failure(error)
          }
        }
      }

      for endpoint in config.dohServers {
        let endpointName = endpoint
        group.addTask {
          do {
            let records = try await DoHDNSClient.query(
              endpoint: endpointName,
              hostname: normalized,
              type: type,
              wireQuestion: question,
              timeout: timeout
            )
            guard !records.isEmpty else { throw DNSResolverError.invalidResponse }
            return Result<DNSLookupResult, Error>.success(
              DNSLookupResult(
                hostname: normalized,
                recordType: type,
                records: records,
                source: "doh://\(endpointName)",
                latencyMilliseconds: max(1, Int(Date().timeIntervalSince(startedAt) * 1000)),
                fromCache: false
              )
            )
          } catch {
            return Result<DNSLookupResult, Error>.failure(error)
          }
        }
      }

      for endpoint in config.dotServers {
        let endpointName = endpoint
        group.addTask {
          do {
            let records = try await DoTDNSClient.query(
              endpoint: endpointName,
              wireQuestion: question,
              type: type,
              timeout: timeout
            )
            guard !records.isEmpty else { throw DNSResolverError.invalidResponse }
            return Result<DNSLookupResult, Error>.success(
              DNSLookupResult(
                hostname: normalized,
                recordType: type,
                records: records,
                source: "dot://\(endpointName)",
                latencyMilliseconds: max(1, Int(Date().timeIntervalSince(startedAt) * 1000)),
                fromCache: false
              )
            )
          } catch {
            return Result<DNSLookupResult, Error>.failure(error)
          }
        }
      }

      for try await result in group {
        if case .success(let lookup) = result {
          group.cancelAll()
          cache.store(hostname: normalized, type: type, records: lookup.records)
          return lookup
        }
      }

      throw DNSResolverError.allServersFailed
    }
  }
}
