import Foundation

enum CIDRMatcher {
  static func contains(ipAddress: String, in cidr: String, allowIPv6: Bool = true) -> Bool {
    let trimmed = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "/")

    if parts.count == 1 {
      return ipAddress.caseInsensitiveCompare(trimmed) == .orderedSame
    }

    guard parts.count == 2, let prefix = Int(parts[1]) else {
      return false
    }

    let network = String(parts[0])

    if let ip = ipv4ToUInt32(ipAddress), let networkValue = ipv4ToUInt32(network), prefix >= 0,
      prefix <= 32
    {
      let mask = prefix == 0 ? UInt32(0) : (UInt32.max << UInt32(32 - prefix))
      return (ip & mask) == (networkValue & mask)
    }

    if allowIPv6, prefix >= 0, prefix <= 128 {
      guard let ip = parseIPv6(ipAddress), let networkValue = parseIPv6(network) else {
        return false
      }
      return ipv6Matches(ip: ip, network: networkValue, prefix: prefix)
    }

    return false
  }

  private static func ipv4ToUInt32(_ string: String) -> UInt32? {
    let parts = string.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return nil }
    return parts.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
  }

  private static func parseIPv6(_ string: String) -> [UInt8]? {
    var address = in6_addr()
    let result = string.withCString { inet_pton(AF_INET6, $0, &address) }
    guard result == 1 else { return nil }
    return withUnsafeBytes(of: address) { Array($0) }
  }

  private static func ipv6Matches(ip: [UInt8], network: [UInt8], prefix: Int) -> Bool {
    guard ip.count == 16, network.count == 16 else { return false }

    let fullBytes = prefix / 8
    let remainingBits = prefix % 8

    if fullBytes > 0, ip[..<fullBytes] != network[..<fullBytes] {
      return false
    }

    if remainingBits == 0 {
      return true
    }

    guard fullBytes < 16 else { return true }
    let mask = UInt8(0xFF << (8 - remainingBits))
    return (ip[fullBytes] & mask) == (network[fullBytes] & mask)
  }
}
