import Foundation

public enum ResolvedRoute: Equatable, Sendable {
  case direct
  case reject
  case rejectTinyGIF
  case upstream(ProxyConfig)
}

public enum PolicyRouter {
  public static func resolve(policy: String, in profile: Profile) -> ResolvedRoute {
    switch policy.uppercased() {
    case "DIRECT":
      return .direct
    case "REJECT":
      return .reject
    case "REJECT-TINYGIF":
      return .rejectTinyGIF
    default:
      if let proxy = profile.proxies.first(where: { $0.name == policy }) {
        return .upstream(proxy)
      }

      if let group = profile.proxyGroups.first(where: { $0.name == policy }) {
        let next = group.selectedPolicy ?? group.policies.first ?? "DIRECT"
        return resolve(policy: next, in: profile)
      }

      return .direct
    }
  }

  public static func evaluate(host: String, path: String, profile: Profile) -> (
    route: ResolvedRoute, match: RuleMatch?
  ) {
    let match = RuleEngine(rules: profile.rules).evaluate(
      RuleEvaluationContext(host: host, url: URL(string: "https://\(host)\(path)"))
    )
    let policy = match?.policy ?? "DIRECT"
    return (resolve(policy: policy, in: profile), match)
  }
}
