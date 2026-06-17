import Foundation

public struct RuleEngineConfiguration: Sendable {
  public var profileDirectory: URL?
  public var geoIPLookup: GeoIPLookup
  public var hostResolver: HostResolver
  public var enableMatchCache: Bool
  public var cacheTTL: TimeInterval

  public init(
    profileDirectory: URL? = nil,
    geoIPLookup: GeoIPLookup = .none,
    hostResolver: HostResolver = .system,
    enableMatchCache: Bool = true,
    cacheTTL: TimeInterval = 300
  ) {
    self.profileDirectory = profileDirectory
    self.geoIPLookup = geoIPLookup
    self.hostResolver = hostResolver
    self.enableMatchCache = enableMatchCache
    self.cacheTTL = cacheTTL
  }

  public static let `default` = RuleEngineConfiguration()
}

public struct GeoIPLookup: Sendable {
  public var countryCode: @Sendable (String) -> String?

  public init(countryCode: @escaping @Sendable (String) -> String?) {
    self.countryCode = countryCode
  }

  public static let none = GeoIPLookup { _ in nil }
}

public enum RulePattern: Equatable, Sendable {
  case domain(String)
  case domainSuffix(String)
  case domainKeyword(String)
  case urlRegex(String)
  case ipCIDR(String)
  case ipCIDR6(String)
  case geoIP(String)
  case processName(String)
}
