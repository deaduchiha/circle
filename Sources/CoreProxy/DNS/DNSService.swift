import Darwin
import Foundation

public final class DNSService: @unchecked Sendable {
  private let lock = NSLock()
  private var engine: DNSResolverEngine

  public init(config: DNSConfig = DNSConfig(), hosts: [String: String] = [:]) {
    self.engine = DNSResolverEngine(config: config, hosts: hosts)
  }

  public func update(config: DNSConfig, hosts: [String: String]) {
    lock.lock()
    let cache = engine.cache
    engine = DNSResolverEngine(config: config, hosts: hosts, cache: cache)
    lock.unlock()
  }

  public func resolve(hostname: String, type: DNSRecordType = .a) async throws -> DNSLookupResult {
    let engine = snapshotEngine()
    return try await engine.resolve(hostname: hostname, type: type)
  }

  private func snapshotEngine() -> DNSResolverEngine {
    lock.lock()
    defer { lock.unlock() }
    return engine
  }

  public func resolveIPAddress(for hostname: String) async -> String? {
    if let result = try? await resolve(hostname: hostname, type: .a), let first = result.records.first {
      return first.value
    }
    if let result = try? await resolve(hostname: hostname, type: .aaaa), let first = result.records.first {
      return first.value
    }
    return nil
  }

  public func resolveIPAddressSync(for hostname: String, timeout: TimeInterval = 2) -> String? {
    let box = SyncResultBox<String>()
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else {
        semaphore.signal()
        return
      }
      Task { @Sendable in
        box.value = await self.resolveIPAddress(for: hostname)
        semaphore.signal()
      }
    }

    _ = semaphore.wait(timeout: .now() + timeout)
    return box.value
  }

  public func cacheSnapshots() -> [DNSCacheEntrySnapshot] {
    lock.lock()
    let cache = engine.cache
    lock.unlock()
    return cache.snapshots()
  }

  public func flushCache() {
    lock.lock()
    engine.cache.flush()
    lock.unlock()
  }

  public var cacheEntryCount: Int {
    lock.lock()
    let count = engine.cache.count
    lock.unlock()
    return count
  }

  public var hostResolver: HostResolver {
    HostResolver { [weak self] hostname in
      self?.resolveIPAddressSync(for: hostname)
    }
  }
}

private final class SyncResultBox<Value>: @unchecked Sendable {
  var value: Value?
}

public struct HostResolver: Sendable {
  public var ipAddress: @Sendable (String) -> String?

  public init(ipAddress: @escaping @Sendable (String) -> String?) {
    self.ipAddress = ipAddress
  }

  public static let system = HostResolver { hostname in
    var hints = addrinfo(
      ai_flags: AI_ADDRCONFIG,
      ai_family: AF_UNSPEC,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(hostname, nil, &hints, &result)
    defer { if let result { freeaddrinfo(result) } }
    guard status == 0, let result else { return nil }

    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let rc = getnameinfo(
      result.pointee.ai_addr,
      result.pointee.ai_addrlen,
      &buffer,
      socklen_t(buffer.count),
      nil,
      0,
      NI_NUMERICHOST
    )
    guard rc == 0 else { return nil }
    return String(cString: buffer)
  }
}
