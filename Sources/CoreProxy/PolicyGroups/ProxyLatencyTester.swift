import CFNetwork
import Foundation

public enum ProxyLatencyTester {
  public static func measure(
    policyName: String,
    profile: Profile,
    testURL: URL,
    timeout: TimeInterval = PolicyGroupDefaults.testTimeout
  ) async -> Int? {
    switch policyName.uppercased() {
    case "REJECT", "REJECT-TINYGIF":
      return nil
    case "DIRECT":
      return await measure(testURL: testURL, proxyDictionary: nil, timeout: timeout)
    default:
      if let proxy = profile.proxies.first(where: { $0.name == policyName }) {
        return await measure(
          testURL: testURL,
          proxyDictionary: proxyDictionary(for: proxy),
          timeout: timeout
        )
      }

      if profile.proxyGroups.contains(where: { $0.name == policyName }) {
        return nil
      }

      return nil
    }
  }

  public static func measureGroup(
    _ group: PolicyGroup,
    profile: Profile,
    timeout: TimeInterval = PolicyGroupDefaults.testTimeout
  ) async -> [String: Int?] {
    guard let testURL = URL(string: group.effectiveTestURL) else {
      return Dictionary(uniqueKeysWithValues: group.policies.map { ($0, nil) })
    }

    var results: [String: Int?] = [:]
    for policy in group.policies {
      results[policy] = await measure(
        policyName: policy,
        profile: profile,
        testURL: testURL,
        timeout: timeout
      )
    }
    return results
  }

  private static func measure(
    testURL: URL,
    proxyDictionary: [String: Any]?,
    timeout: TimeInterval
  ) async -> Int? {
    var config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    if let proxyDictionary {
      config.connectionProxyDictionary = proxyDictionary
    }

    let session = URLSession(configuration: config)
    let startedAt = Date()

    do {
      var request = URLRequest(url: testURL)
      request.httpMethod = "HEAD"
      request.cachePolicy = .reloadIgnoringLocalCacheData

      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { return nil }
      guard (200...399).contains(http.statusCode) || http.statusCode == 204 else { return nil }
      return max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
    } catch {
      return nil
    }
  }

  private static func proxyDictionary(for proxy: ProxyConfig) -> [String: Any] {
    switch proxy.type {
    case .http, .https:
      return [
        kCFNetworkProxiesHTTPEnable as String: true,
        kCFNetworkProxiesHTTPProxy as String: proxy.host,
        kCFNetworkProxiesHTTPPort as String: proxy.port,
        kCFNetworkProxiesHTTPSEnable as String: true,
        kCFNetworkProxiesHTTPSProxy as String: proxy.host,
        kCFNetworkProxiesHTTPSPort as String: proxy.port,
      ]
    case .socks5, .socks5TLS:
      return [
        kCFNetworkProxiesSOCKSEnable as String: true,
        kCFNetworkProxiesSOCKSProxy as String: proxy.host,
        kCFNetworkProxiesSOCKSPort as String: proxy.port,
      ]
    default:
      return [
        kCFNetworkProxiesHTTPEnable as String: true,
        kCFNetworkProxiesHTTPProxy as String: proxy.host,
        kCFNetworkProxiesHTTPPort as String: proxy.port,
      ]
    }
  }
}
