import Foundation

enum LogicalCombinator: Sendable {
  case and
  case or
  case not
}

enum LogicalRuleItem: Equatable, Sendable {
  case pattern(RulePattern)
  case group(LogicalCombinator, [LogicalRuleItem])
}

enum LogicalRuleParser {
  static func parseGroupItems(_ text: String) -> [LogicalRuleItem]? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("("), value.hasSuffix(")") else { return nil }

    value.removeFirst()
    value.removeLast()

    var items: [LogicalRuleItem] = []
    var depth = 0
    var start: String.Index?

    for index in value.indices {
      let character = value[index]
      if character == "(" {
        if depth == 0 {
          start = value.index(after: index)
        }
        depth += 1
      } else if character == ")" {
        depth -= 1
        if depth == 0, let tokenStart = start {
          let token = String(value[tokenStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
          if let pattern = parsePatternRule(token) {
            items.append(.pattern(pattern))
          }
          start = nil
        }
      }
    }

    return items.isEmpty ? nil : items
  }

  static func parsePatternRule(_ line: String) -> RulePattern? {
    let parts = csvParts(line)
    guard let typeName = parts.first,
      let type = RuleType(rawValue: typeName.uppercased()),
      parts.count >= 2
    else {
      return nil
    }

    let value = parts[1]

    switch type {
    case .domain:
      return .domain(value.lowercased())
    case .domainSuffix:
      return .domainSuffix(value.lowercased())
    case .domainKeyword:
      return .domainKeyword(value.lowercased())
    case .urlRegex:
      return .urlRegex(value)
    case .ipCIDR:
      return .ipCIDR(value)
    case .ipCIDR6:
      return .ipCIDR6(value)
    case .geoIP:
      return .geoIP(value.uppercased())
    case .processName:
      return .processName(value)
    default:
      return nil
    }
  }

  private static func csvParts(_ line: String) -> [String] {
    line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
      !$0.isEmpty
    }
  }
}
