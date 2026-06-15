import Foundation

final class RegexRuleCache: @unchecked Sendable {
  private let lock = NSLock()
  private var cache: [String: NSRegularExpression] = [:]

  func expression(for pattern: String) -> NSRegularExpression? {
    lock.lock()
    if let cached = cache[pattern] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return nil
    }

    lock.lock()
    cache[pattern] = regex
    lock.unlock()
    return regex
  }

  func matches(pattern: String, in text: String) -> Bool {
    guard let regex = expression(for: pattern) else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, range: range) != nil
  }
}
