import Foundation

struct DomainTrie: Sendable {
  private var exactHosts: Set<String> = []
  private var suffixRoots: Set<String> = []

  var isEmpty: Bool {
    exactHosts.isEmpty && suffixRoots.isEmpty
  }

  mutating func insert(_ domain: String, suffix: Bool = false) {
    let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".*"))
    guard !normalized.isEmpty else { return }

    if suffix {
      suffixRoots.insert(normalized)
    } else {
      exactHosts.insert(normalized)
    }
  }

  func contains(_ host: String) -> Bool {
    exactHosts.contains(host.lowercased())
  }

  func longestSuffixMatch(for host: String) -> Bool {
    let normalized = host.lowercased()
    for suffix in suffixRoots {
      if normalized == suffix || normalized.hasSuffix("." + suffix) {
        return true
      }
    }
    return false
  }
}
