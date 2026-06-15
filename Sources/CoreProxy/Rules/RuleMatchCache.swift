import Foundation

final class RuleMatchCache: @unchecked Sendable {
  private struct CacheKey: Hashable {
    var host: String
    var urlString: String?
    var processName: String?
    var ipAddress: String?
  }

  private struct Entry {
    var match: RuleMatch?
    var expiresAt: Date
  }

  private let lock = NSLock()
  private var entries: [CacheKey: Entry] = [:]
  private let ttl: TimeInterval

  init(ttl: TimeInterval) {
    self.ttl = ttl
  }

  func lookup(context: RuleEvaluationContext, urlString: String?) -> RuleMatch?? {
    let key = CacheKey(
      host: context.host,
      urlString: urlString,
      processName: context.processName,
      ipAddress: context.ipAddress
    )

    lock.lock()
    defer { lock.unlock() }

    guard let entry = entries[key] else { return nil }
    if entry.expiresAt <= Date() {
      entries.removeValue(forKey: key)
      return nil
    }
    return entry.match
  }

  func store(context: RuleEvaluationContext, urlString: String?, match: RuleMatch?) {
    let key = CacheKey(
      host: context.host,
      urlString: urlString,
      processName: context.processName,
      ipAddress: context.ipAddress
    )

    lock.lock()
    entries[key] = Entry(match: match, expiresAt: Date().addingTimeInterval(ttl))
    lock.unlock()
  }

  func flush() {
    lock.lock()
    entries.removeAll()
    lock.unlock()
  }
}
