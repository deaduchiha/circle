import Foundation

public struct RuleEvaluationContext: Sendable {
  public var host: String
  public var url: URL?
  public var processName: String?
  public var ipAddress: String?

  public init(host: String, url: URL? = nil, processName: String? = nil, ipAddress: String? = nil) {
    self.host = host.lowercased()
    self.url = url
    self.processName = processName
    self.ipAddress = ipAddress
  }
}

public struct RuleMatch: Equatable, Sendable {
  public var rule: Rule
  public var policy: String

  public init(rule: Rule, policy: String) {
    self.rule = rule
    self.policy = policy
  }
}

public struct RuleEngine: Sendable {
  public var rules: [Rule]

  public init(rules: [Rule]) {
    self.rules = rules
  }

  public func evaluate(_ context: RuleEvaluationContext) -> RuleMatch? {
    for rule in rules where matches(rule, context: context) {
      return RuleMatch(rule: rule, policy: rule.policy)
    }
    return nil
  }

  private func matches(_ rule: Rule, context: RuleEvaluationContext) -> Bool {
    switch rule.type {
    case .domain:
      return context.host == rule.value.lowercased()
    case .domainSuffix:
      return context.host == normalizedSuffix(rule.value)
        || context.host.hasSuffix("." + normalizedSuffix(rule.value))
    case .domainKeyword:
      return context.host.contains(rule.value.lowercased())
    case .urlRegex:
      guard let url = context.url?.absoluteString else { return false }
      return url.range(of: rule.value, options: .regularExpression) != nil
    case .processName:
      return context.processName?.caseInsensitiveCompare(rule.value) == .orderedSame
    case .ipCIDR, .ipCIDR6:
      guard let ipAddress = context.ipAddress else { return false }
      return CIDRMatcher.contains(ipAddress: ipAddress, in: rule.value)
    case .final:
      return true
    case .domainSet, .geoIP, .ruleSet:
      return false
    }
  }

  private func normalizedSuffix(_ value: String) -> String {
    value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
  }
}

enum CIDRMatcher {
  static func contains(ipAddress: String, in cidr: String) -> Bool {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, let prefix = Int(parts[1]) else {
      return ipAddress == cidr
    }

    if let ip = ipv4ToUInt32(ipAddress), let network = ipv4ToUInt32(String(parts[0])), prefix >= 0,
      prefix <= 32
    {
      let mask = prefix == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefix)
      return (ip & mask) == (network & mask)
    }

    return false
  }

  private static func ipv4ToUInt32(_ string: String) -> UInt32? {
    let parts = string.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return nil }
    return parts.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
  }
}
