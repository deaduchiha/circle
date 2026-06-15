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

  public init(
    httpPort: Int = 8888, socksPort: Int? = nil, dashboardPort: Int = 8234,
    logLevel: String = "info"
  ) {
    self.httpPort = httpPort
    self.socksPort = socksPort
    self.dashboardPort = dashboardPort
    self.logLevel = logLevel
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

  public init(
    id: UUID = UUID(), name: String, type: PolicyGroupType, policies: [String],
    selectedPolicy: String? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.policies = policies
    self.selectedPolicy = selectedPolicy
  }
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
