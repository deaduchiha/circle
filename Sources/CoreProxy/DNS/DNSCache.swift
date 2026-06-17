import Foundation

public final class DNSCache: @unchecked Sendable {
  public static let maxEntries = 10_000

  private struct Entry {
    var records: [DNSRecord]
    var expiresAt: Date
  }

  private let lock = NSLock()
  private var storage: [String: Entry] = [:]
  private var order: [String] = []

  public init() {}

  public func lookup(hostname: String, type: DNSRecordType, now: Date = Date()) -> [DNSRecord]? {
    let key = cacheKey(hostname: hostname, type: type)
    lock.lock()
    defer { lock.unlock() }

    guard let entry = storage[key] else { return nil }
    if entry.expiresAt <= now {
      storage.removeValue(forKey: key)
      order.removeAll { $0 == key }
      return nil
    }

    touch(key)
    return entry.records
  }

  public func store(hostname: String, type: DNSRecordType, records: [DNSRecord], now: Date = Date()) {
    guard !records.isEmpty else { return }
    let key = cacheKey(hostname: hostname, type: type)
    let ttl = records.map(\.ttl).max() ?? 60
    let expiresAt = now.addingTimeInterval(TimeInterval(max(ttl, 1)))

    lock.lock()
    defer { lock.unlock() }

    storage[key] = Entry(records: records, expiresAt: expiresAt)
    touch(key)

    while order.count > Self.maxEntries {
      let evicted = order.removeFirst()
      storage.removeValue(forKey: evicted)
    }
  }

  public func flush() {
    lock.lock()
    storage.removeAll()
    order.removeAll()
    lock.unlock()
  }

  public func snapshots(now: Date = Date()) -> [DNSCacheEntrySnapshot] {
    lock.lock()
    defer { lock.unlock() }

    return order.compactMap { key in
      guard let entry = storage[key], entry.expiresAt > now else { return nil }
      let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
      guard parts.count == 2, let type = DNSRecordType(rawValue: UInt16(parts[1]) ?? 0) else { return nil }
      return DNSCacheEntrySnapshot(
        key: key,
        hostname: parts[0],
        recordType: type,
        records: entry.records,
        expiresAt: entry.expiresAt
      )
    }
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage.count
  }

  private func touch(_ key: String) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  private func cacheKey(hostname: String, type: DNSRecordType) -> String {
    "\(hostname.lowercased())|\(type.rawValue)"
  }
}
