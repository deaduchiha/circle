import Darwin
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
  private let compiled: CompiledRuleEngine

  public var rules: [Rule] {
    compiled.rules
  }

  public init(rules: [Rule], configuration: RuleEngineConfiguration = .default) {
    self.compiled = CompiledRuleEngine(rules: rules, configuration: configuration)
  }

  public func evaluate(_ context: RuleEvaluationContext) -> RuleMatch? {
    compiled.evaluate(context)
  }

  public func flushCache() {
    compiled.flushCache()
  }
}

struct CompiledRuleEngine: Sendable {
  let rules: [Rule]
  private let regexCache: RegexRuleCache
  private let matchCache: RuleMatchCache?
  private let geoIPLookup: GeoIPLookup
  private let domainSets: [String: DomainSetIndex]
  private let ruleSets: [String: RuleSetPatterns]

  init(rules: [Rule], configuration: RuleEngineConfiguration) {
    self.rules = rules
    self.regexCache = RegexRuleCache()
    self.geoIPLookup = configuration.geoIPLookup
    self.matchCache = configuration.enableMatchCache ? RuleMatchCache(ttl: configuration.cacheTTL) : nil

    var domainSets: [String: DomainSetIndex] = [:]
    var ruleSets: [String: RuleSetPatterns] = [:]

    for rule in rules {
      switch rule.type {
      case .domainSet:
        if domainSets[rule.value] == nil,
          let text = try? RuleResourceLoader.loadText(
            from: rule.value,
            profileDirectory: configuration.profileDirectory
          )
        {
          domainSets[rule.value] = DomainSetIndex(contents: text)
        }
      case .ruleSet:
        if ruleSets[rule.value] == nil,
          let text = try? RuleResourceLoader.loadText(
            from: rule.value,
            profileDirectory: configuration.profileDirectory
          )
        {
          ruleSets[rule.value] = RuleSetPatterns(contents: text)
        }
      default:
        break
      }
    }

    self.domainSets = domainSets
    self.ruleSets = ruleSets
  }

  func evaluate(_ context: RuleEvaluationContext) -> RuleMatch? {
    let urlString = context.url?.absoluteString

    if let matchCache,
      let cached = matchCache.lookup(context: context, urlString: urlString)
    {
      return cached
    }

    for rule in rules where matches(rule, context: context) {
      let match = RuleMatch(rule: rule, policy: rule.policy)
      matchCache?.store(context: context, urlString: urlString, match: match)
      return match
    }

    matchCache?.store(context: context, urlString: urlString, match: nil)
    return nil
  }

  func flushCache() {
    matchCache?.flush()
  }

  private func matches(_ rule: Rule, context: RuleEvaluationContext) -> Bool {
    switch rule.type {
    case .domain:
      return context.host == rule.value.lowercased()
    case .domainSuffix:
      return matchesSuffix(rule.value, host: context.host)
    case .domainKeyword:
      return context.host.contains(rule.value.lowercased())
    case .urlRegex:
      guard let url = context.url?.absoluteString else { return false }
      return regexCache.matches(pattern: rule.value, in: url)
    case .processName:
      let process = context.processName ?? ProcessNameMatcher.processName()
      return process?.caseInsensitiveCompare(rule.value) == .orderedSame
    case .ipCIDR:
      guard let ipAddress = resolvedIPAddress(for: context, rule: rule) else { return false }
      return CIDRMatcher.contains(ipAddress: ipAddress, in: rule.value, allowIPv6: false)
    case .ipCIDR6:
      guard let ipAddress = resolvedIPAddress(for: context, rule: rule) else { return false }
      return CIDRMatcher.contains(ipAddress: ipAddress, in: rule.value, allowIPv6: true)
    case .geoIP:
      guard let ipAddress = resolvedIPAddress(for: context, rule: rule),
        let country = geoIPLookup.countryCode(ipAddress)
      else { return false }
      return country.uppercased() == rule.value.uppercased()
    case .domainSet:
      return domainSets[rule.value]?.matches(context.host) == true
    case .ruleSet:
      return ruleSets[rule.value]?.patterns.contains { matchesPattern($0, context: context) } == true
    case .and, .or, .not:
      return matchesLogicalRule(rule, context: context)
    case .final:
      return true
    }
  }

  private func matchesLogicalRule(_ rule: Rule, context: RuleEvaluationContext) -> Bool {
    guard let items = LogicalRuleParser.parseGroupItems(rule.value) else { return false }

    switch rule.type {
    case .and:
      return items.allSatisfy { matchesLogicalItem($0, context: context) }
    case .or:
      return items.contains { matchesLogicalItem($0, context: context) }
    case .not:
      guard let first = items.first else { return false }
      return !matchesLogicalItem(first, context: context)
    default:
      return false
    }
  }

  private func matchesLogicalItem(_ item: LogicalRuleItem, context: RuleEvaluationContext) -> Bool {
    switch item {
    case .pattern(let pattern):
      return matchesPattern(pattern, context: context)
    case .group(let combinator, let children):
      switch combinator {
      case .and:
        return children.allSatisfy { matchesLogicalItem($0, context: context) }
      case .or:
        return children.contains { matchesLogicalItem($0, context: context) }
      case .not:
        guard let first = children.first else { return false }
        return !matchesLogicalItem(first, context: context)
      }
    }
  }

  private func matchesPattern(_ pattern: RulePattern, context: RuleEvaluationContext) -> Bool {
    switch pattern {
    case .domain(let value):
      return context.host == value
    case .domainSuffix(let value):
      return matchesSuffix(value, host: context.host)
    case .domainKeyword(let value):
      return context.host.contains(value)
    case .urlRegex(let value):
      guard let url = context.url?.absoluteString else { return false }
      return regexCache.matches(pattern: value, in: url)
    case .processName(let value):
      let process = context.processName ?? ProcessNameMatcher.processName()
      return process?.caseInsensitiveCompare(value) == .orderedSame
    case .ipCIDR(let value):
      guard let ipAddress = context.ipAddress else { return false }
      return CIDRMatcher.contains(ipAddress: ipAddress, in: value, allowIPv6: false)
    case .ipCIDR6(let value):
      guard let ipAddress = context.ipAddress else { return false }
      return CIDRMatcher.contains(ipAddress: ipAddress, in: value, allowIPv6: true)
    case .geoIP(let value):
      guard let ipAddress = context.ipAddress,
        let country = geoIPLookup.countryCode(ipAddress)
      else { return false }
      return country.uppercased() == value.uppercased()
    }
  }

  private func matchesSuffix(_ value: String, host: String) -> Bool {
    let suffix = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return host == suffix || host.hasSuffix("." + suffix)
  }

  private func resolvedIPAddress(for context: RuleEvaluationContext, rule: Rule) -> String? {
    if let ipAddress = context.ipAddress {
      return ipAddress
    }
    if rule.options["no-resolve"] != nil {
      return nil
    }
    return Self.resolveHost(context.host)
  }

  private static func resolveHost(_ host: String) -> String? {
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
    let status = getaddrinfo(host, nil, &hints, &result)
    defer { if let result { freeaddrinfo(result) } }
    guard status == 0, let result else { return nil }

    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let rc = getnameinfo(
      result.pointee.ai_addr,
      result.pointee.ai_addrlen,
      &hostname,
      socklen_t(hostname.count),
      nil,
      0,
      NI_NUMERICHOST
    )
    guard rc == 0 else { return nil }
    return String(cString: hostname)
  }
}
