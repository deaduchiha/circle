import Foundation

public enum ProfileParserError: Error, LocalizedError, Equatable {
  case invalidLine(Int, String)
  case invalidProxy(Int, String)
  case invalidRule(Int, String)

  public var errorDescription: String? {
    switch self {
    case .invalidLine(let line, let value):
      "Line \(line) is not a valid key/value or section: \(value)"
    case .invalidProxy(let line, let value):
      "Line \(line) is not a valid proxy definition: \(value)"
    case .invalidRule(let line, let value):
      "Line \(line) is not a valid rule definition: \(value)"
    }
  }
}

public struct ProfileParser: Sendable {
  public init() {}

  public func parse(_ text: String) throws -> Profile {
    var profile = Profile()
    var section = ""

    for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
      let lineNumber = offset + 1
      let line = stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)

      if line.isEmpty || line.hasPrefix("#!include") {
        continue
      }

      if line.hasPrefix("[") && line.hasSuffix("]") {
        section = String(line.dropFirst().dropLast()).lowercased()
        continue
      }

      switch section {
      case "general":
        try parseGeneral(line, into: &profile.general, lineNumber: lineNumber)
      case "proxy":
        profile.proxies.append(try parseProxy(line, lineNumber: lineNumber))
      case "proxy group":
        profile.proxyGroups.append(try parseProxyGroup(line, lineNumber: lineNumber))
      case "rule":
        profile.rules.append(try parseRule(line, lineNumber: lineNumber))
      case "host":
        try parseKeyValue(line, lineNumber: lineNumber) { profile.hosts[$0] = $1 }
      case "dns":
        try parseDNS(line, into: &profile.dnsConfig, lineNumber: lineNumber)
      case "mitm":
        try parseMITM(line, into: &profile.mitm, lineNumber: lineNumber)
      case "script":
        profile.scripts.append(try parseScript(line, lineNumber: lineNumber))
      default:
        throw ProfileParserError.invalidLine(lineNumber, rawLine)
      }
    }

    return profile
  }

  public func serialize(_ profile: Profile) -> String {
    var lines: [String] = []

    lines.append("[General]")
    lines.append("http-port = \(profile.general.httpPort)")
    lines.append("dashboard-port = \(profile.general.dashboardPort)")
    if let socksPort = profile.general.socksPort {
      lines.append("socks-port = \(socksPort)")
    }
    lines.append("log-level = \(profile.general.logLevel)")

    if !profile.proxies.isEmpty {
      lines.append("")
      lines.append("[Proxy]")
      for proxy in profile.proxies {
        var parts = [proxy.name, proxy.type.rawValue, proxy.host, "\(proxy.port)"]
        parts.append(
          contentsOf: proxy.parameters.sorted(by: { $0.key < $1.key }).map {
            "\($0.key)=\($0.value)"
          })
        lines.append(parts.joined(separator: ", "))
      }
    }

    if !profile.proxyGroups.isEmpty {
      lines.append("")
      lines.append("[Proxy Group]")
      for group in profile.proxyGroups {
        lines.append(([group.name, group.type.rawValue] + group.policies).joined(separator: ", "))
      }
    }

    if !profile.rules.isEmpty {
      lines.append("")
      lines.append("[Rule]")
      for rule in profile.rules {
        if rule.type == .final {
          lines.append("\(rule.type.rawValue), \(rule.policy)")
        } else {
          lines.append("\(rule.type.rawValue), \(rule.value), \(rule.policy)")
        }
      }
    }

    if !profile.hosts.isEmpty {
      lines.append("")
      lines.append("[Host]")
      for (host, value) in profile.hosts.sorted(by: { $0.key < $1.key }) {
        lines.append("\(host) = \(value)")
      }
    }

    lines.append("")
    lines.append("[DNS]")
    lines.append("server = \(profile.dnsConfig.servers.joined(separator: ", "))")
    if !profile.dnsConfig.dohServers.isEmpty {
      lines.append("doh-server = \(profile.dnsConfig.dohServers.joined(separator: ", "))")
    }
    lines.append("fake-ip = \(profile.dnsConfig.fakeIPEnabled ? "true" : "false")")

    lines.append("")
    lines.append("[MITM]")
    lines.append("enabled = \(profile.mitm.enabled ? "true" : "false")")
    if !profile.mitm.hostnames.isEmpty {
      lines.append("hostname = \(profile.mitm.hostnames.joined(separator: ", "))")
    }

    return lines.joined(separator: "\n") + "\n"
  }

  private func parseGeneral(_ line: String, into general: inout GeneralConfig, lineNumber: Int)
    throws
  {
    try parseKeyValue(line, lineNumber: lineNumber) { key, value in
      switch key.lowercased() {
      case "http-port":
        general.httpPort = Int(value) ?? general.httpPort
      case "socks-port":
        general.socksPort = Int(value)
      case "dashboard-port":
        general.dashboardPort = Int(value) ?? general.dashboardPort
      case "log-level":
        general.logLevel = value
      default:
        break
      }
    }
  }

  private func parseProxy(_ line: String, lineNumber: Int) throws -> ProxyConfig {
    let parts = csvParts(line)
    guard parts.count >= 4,
      let type = ProxyType(rawValue: parts[1].lowercased()),
      let port = Int(parts[3])
    else {
      throw ProfileParserError.invalidProxy(lineNumber, line)
    }

    return ProxyConfig(
      name: parts[0],
      type: type,
      host: parts[2],
      port: port,
      parameters: parseParameters(Array(parts.dropFirst(4)))
    )
  }

  private func parseProxyGroup(_ line: String, lineNumber: Int) throws -> PolicyGroup {
    let parts = csvParts(line)
    guard parts.count >= 3,
      let type = PolicyGroupType(rawValue: parts[1].lowercased())
    else {
      throw ProfileParserError.invalidLine(lineNumber, line)
    }

    return PolicyGroup(name: parts[0], type: type, policies: Array(parts.dropFirst(2)))
  }

  private func parseRule(_ line: String, lineNumber: Int) throws -> Rule {
    let parts = csvParts(line)
    guard let typeName = parts.first, let type = RuleType(rawValue: typeName.uppercased()) else {
      throw ProfileParserError.invalidRule(lineNumber, line)
    }

    if type == .final, parts.count >= 2 {
      return Rule(type: .final, policy: parts[1])
    }

    guard parts.count >= 3 else {
      throw ProfileParserError.invalidRule(lineNumber, line)
    }

    return Rule(
      type: type, value: parts[1], policy: parts[2],
      options: parseParameters(Array(parts.dropFirst(3))))
  }

  private func parseDNS(_ line: String, into dns: inout DNSConfig, lineNumber: Int) throws {
    try parseKeyValue(line, lineNumber: lineNumber) { key, value in
      switch key.lowercased() {
      case "server":
        dns.servers = csvParts(value)
      case "doh-server":
        dns.dohServers = csvParts(value)
      case "fake-ip":
        dns.fakeIPEnabled = value.lowercased() == "true"
      default:
        break
      }
    }
  }

  private func parseMITM(_ line: String, into mitm: inout MITMConfig, lineNumber: Int) throws {
    try parseKeyValue(line, lineNumber: lineNumber) { key, value in
      switch key.lowercased() {
      case "enabled":
        mitm.enabled = value.lowercased() == "true"
      case "hostname":
        mitm.hostnames = csvParts(value)
      default:
        break
      }
    }
  }

  private func parseScript(_ line: String, lineNumber: Int) throws -> ScriptConfig {
    let parts = csvParts(line)
    guard parts.count >= 3 else {
      throw ProfileParserError.invalidLine(lineNumber, line)
    }
    return ScriptConfig(name: parts[0], event: parts[1], path: parts[2])
  }

  private func parseKeyValue(_ line: String, lineNumber: Int, apply: (String, String) -> Void)
    throws
  {
    guard let equals = line.firstIndex(of: "=") else {
      throw ProfileParserError.invalidLine(lineNumber, line)
    }

    let key = line[..<equals].trimmingCharacters(in: .whitespaces)
    let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    apply(String(key), String(value))
  }

  private func parseParameters(_ parts: [String]) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: parts.compactMap { part in
        guard let equals = part.firstIndex(of: "=") else { return nil }
        let key = part[..<equals].trimmingCharacters(in: .whitespaces)
        let value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return (String(key), String(value))
      })
  }

  private func csvParts(_ line: String) -> [String] {
    line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
      !$0.isEmpty
    }
  }

  private func stripComment(_ line: String) -> String {
    guard let comment = line.firstIndex(of: "#") else { return line }
    return String(line[..<comment])
  }
}
