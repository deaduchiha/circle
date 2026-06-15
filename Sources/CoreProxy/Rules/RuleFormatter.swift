import Foundation

public enum RuleFormatter {
  public static func summary(_ rule: Rule) -> String {
    switch rule.type {
    case .final:
      return "FINAL → \(rule.policy)"
    case .and, .or, .not:
      return "\(rule.type.rawValue) \(compactValue(rule.value)) → \(rule.policy)\(optionsSuffix(rule.options))"
    default:
      if rule.value.isEmpty {
        return "\(rule.type.rawValue) → \(rule.policy)\(optionsSuffix(rule.options))"
      }
      return "\(rule.type.rawValue), \(rule.value) → \(rule.policy)\(optionsSuffix(rule.options))"
    }
  }

  public static func iconName(for type: RuleType) -> String {
    switch type {
    case .domain, .domainSuffix, .domainKeyword, .domainSet:
      "globe"
    case .ipCIDR, .ipCIDR6:
      "network"
    case .geoIP:
      "map"
    case .processName:
      "app"
    case .urlRegex:
      "link"
    case .ruleSet:
      "doc.text"
    case .and, .or, .not:
      "arrow.triangle.branch"
    case .final:
      "flag.checkered"
    }
  }

  public static func routeDescription(_ route: ResolvedRoute) -> String {
    switch route {
    case .direct:
      "DIRECT"
    case .reject:
      "REJECT"
    case .rejectTinyGIF:
      "REJECT-TINYGIF"
    case .upstream(let proxy):
      "Proxy (\(proxy.name))"
    }
  }

  private static func compactValue(_ value: String, limit: Int = 48) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit)) + "…"
  }

  private static func optionsSuffix(_ options: [String: String]) -> String {
    guard !options.isEmpty else { return "" }
    let flags = options.keys.sorted().joined(separator: ", ")
    return " [\(flags)]"
  }
}

public struct RuleTestResult: Equatable, Sendable {
  public var host: String
  public var path: String
  public var policy: String
  public var ruleSummary: String?
  public var routeDescription: String

  public init(
    host: String,
    path: String,
    policy: String,
    ruleSummary: String? = nil,
    routeDescription: String
  ) {
    self.host = host
    self.path = path
    self.policy = policy
    self.ruleSummary = ruleSummary
    self.routeDescription = routeDescription
  }
}
