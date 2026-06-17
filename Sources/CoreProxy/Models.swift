import Foundation

public struct Profile: Codable, Equatable, Sendable {
  public var general: GeneralConfig
  public var proxies: [ProxyConfig]
  public var proxyGroups: [PolicyGroup]
  public var rules: [Rule]
  public var hosts: [String: String]
  public var dnsConfig: DNSConfig
  public var mitm: MITMConfig
  public var scripts: [ScriptConfig]

  public init(
    general: GeneralConfig = GeneralConfig(),
    proxies: [ProxyConfig] = [],
    proxyGroups: [PolicyGroup] = [],
    rules: [Rule] = [],
    hosts: [String: String] = [:],
    dnsConfig: DNSConfig = DNSConfig(),
    mitm: MITMConfig = MITMConfig(),
    scripts: [ScriptConfig] = []
  ) {
    self.general = general
    self.proxies = proxies
    self.proxyGroups = proxyGroups
    self.rules = rules
    self.hosts = hosts
    self.dnsConfig = dnsConfig
    self.mitm = mitm
    self.scripts = scripts
  }
}

public struct GeneralConfig: Codable, Equatable, Sendable {
  public var httpPort: Int
  public var socksPort: Int?
  public var dashboardPort: Int
  public var logLevel: String
  public var geolite2LicenseKey: String?

  public init(
    httpPort: Int = 8888, socksPort: Int? = nil, dashboardPort: Int = 8234,
    logLevel: String = "info", geolite2LicenseKey: String? = nil
  ) {
    self.httpPort = httpPort
    self.socksPort = socksPort
    self.dashboardPort = dashboardPort
    self.logLevel = logLevel
    self.geolite2LicenseKey = geolite2LicenseKey
  }
}

public enum RuleType: String, Codable, CaseIterable, Sendable {
  case domain = "DOMAIN"
  case domainSuffix = "DOMAIN-SUFFIX"
  case domainKeyword = "DOMAIN-KEYWORD"
  case domainSet = "DOMAIN-SET"
  case ipCIDR = "IP-CIDR"
  case ipCIDR6 = "IP-CIDR6"
  case geoIP = "GEOIP"
  case processName = "PROCESS-NAME"
  case urlRegex = "URL-REGEX"
  case ruleSet = "RULE-SET"
  case and = "AND"
  case or = "OR"
  case not = "NOT"
  case final = "FINAL"
}

public struct Rule: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var type: RuleType
  public var value: String
  public var policy: String
  public var options: [String: String]

  public init(
    id: UUID = UUID(), type: RuleType, value: String = "", policy: String,
    options: [String: String] = [:]
  ) {
    self.id = id
    self.type = type
    self.value = value
    self.policy = policy
    self.options = options
  }
}

public enum ProxyType: String, Codable, CaseIterable, Sendable {
  case http
  case https
  case socks5
  case socks5TLS = "socks5-tls"
  case shadowsocks = "ss"
  case vmess
  case trojan
  case tuic
  case hysteria2
  case wireGuard = "wireguard"
  case ssh
  case anyTLS = "anytls"
}

public struct ProxyConfig: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var type: ProxyType
  public var host: String
  public var port: Int
  public var parameters: [String: String]

  public init(
    id: UUID = UUID(), name: String, type: ProxyType, host: String, port: Int,
    parameters: [String: String] = [:]
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.host = host
    self.port = port
    self.parameters = parameters
  }
}

public enum PolicyGroupType: String, Codable, CaseIterable, Sendable {
  case select
  case urlTest = "url-test"
  case fallback
  case loadBalance = "load-balance"
}

public struct PolicyGroup: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var type: PolicyGroupType
  public var policies: [String]
  public var selectedPolicy: String?
  public var testURL: String?
  public var testInterval: Int?
  public var tolerance: Int?

  public init(
    id: UUID = UUID(), name: String, type: PolicyGroupType, policies: [String],
    selectedPolicy: String? = nil, testURL: String? = nil, testInterval: Int? = nil,
    tolerance: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.policies = policies
    self.selectedPolicy = selectedPolicy
    self.testURL = testURL
    self.testInterval = testInterval
    self.tolerance = tolerance
  }

  public var effectiveTestURL: String {
    testURL ?? PolicyGroupDefaults.testURL
  }

  public var effectiveTestInterval: Int {
    testInterval ?? PolicyGroupDefaults.testInterval
  }

  public var effectiveTolerance: Int {
    tolerance ?? PolicyGroupDefaults.tolerance
  }
}

public enum PolicyGroupDefaults {
  public static let testURL = "http://cp.cloudflare.com/generate_204"
  public static let testInterval = 300
  public static let tolerance = 50
  public static let unavailableTTL: TimeInterval = 60
  public static let testTimeout: TimeInterval = 5
}

public struct DNSConfig: Codable, Equatable, Sendable {
  public var servers: [String]
  public var dohServers: [String]
  public var fakeIPEnabled: Bool

  public init(
    servers: [String] = ["1.1.1.1", "8.8.8.8"], dohServers: [String] = [],
    fakeIPEnabled: Bool = false
  ) {
    self.servers = servers
    self.dohServers = dohServers
    self.fakeIPEnabled = fakeIPEnabled
  }
}

public struct MITMConfig: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var hostnames: [String]

  public init(enabled: Bool = false, hostnames: [String] = []) {
    self.enabled = enabled
    self.hostnames = hostnames
  }
}

public struct MITMCertificateStatus: Equatable, Sendable {
  public var commonName: String
  public var fingerprintSHA256: String
  public var notValidBefore: Date
  public var notValidAfter: Date
  public var isInstalledInKeychain: Bool

  public init(
    commonName: String,
    fingerprintSHA256: String,
    notValidBefore: Date,
    notValidAfter: Date,
    isInstalledInKeychain: Bool
  ) {
    self.commonName = commonName
    self.fingerprintSHA256 = fingerprintSHA256
    self.notValidBefore = notValidBefore
    self.notValidAfter = notValidAfter
    self.isInstalledInKeychain = isInstalledInKeychain
  }
}

public struct ScriptConfig: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var event: String
  public var path: String

  public init(id: UUID = UUID(), name: String, event: String, path: String) {
    self.id = id
    self.name = name
    self.event = event
    self.path = path
  }
}

public struct ProfileModuleSettings: Codable, Equatable, Sendable {
  public var proxies: Bool
  public var proxyGroups: Bool
  public var rules: Bool
  public var hosts: Bool
  public var dns: Bool
  public var mitm: Bool
  public var scripts: Bool

  public init(
    proxies: Bool = true,
    proxyGroups: Bool = true,
    rules: Bool = true,
    hosts: Bool = true,
    dns: Bool = true,
    mitm: Bool = true,
    scripts: Bool = true
  ) {
    self.proxies = proxies
    self.proxyGroups = proxyGroups
    self.rules = rules
    self.hosts = hosts
    self.dns = dns
    self.mitm = mitm
    self.scripts = scripts
  }

  public static let allEnabled = ProfileModuleSettings()
}

public struct ProfileDocument: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var sourceURL: String?
  public var modules: ProfileModuleSettings
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    sourceURL: String? = nil,
    modules: ProfileModuleSettings = .allEnabled,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.sourceURL = sourceURL
    self.modules = modules
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
