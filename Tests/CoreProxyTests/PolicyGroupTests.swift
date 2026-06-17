@testable import CoreProxy
import XCTest

final class PolicyGroupManagerTests: XCTestCase {
  private func makeProfile() -> Profile {
    Profile(
      proxies: [
        ProxyConfig(name: "Fast", type: .http, host: "127.0.0.1", port: 7890),
        ProxyConfig(name: "Slow", type: .http, host: "127.0.0.1", port: 7891),
      ],
      proxyGroups: [
        PolicyGroup(name: "Manual", type: .select, policies: ["Fast", "DIRECT"]),
        PolicyGroup(name: "Auto", type: .urlTest, policies: ["Fast", "Slow", "DIRECT"], tolerance: 50),
        PolicyGroup(name: "Backup", type: .fallback, policies: ["Fast", "Slow", "DIRECT"]),
        PolicyGroup(name: "Spread", type: .loadBalance, policies: ["Fast", "Slow"]),
      ]
    )
  }

  func testSelectGroupUsesManualSelection() {
    let manager = PolicyGroupManager()
    let profile = makeProfile()
    manager.sync(from: profile)

    guard let group = profile.proxyGroups.first(where: { $0.name == "Manual" }) else {
      return XCTFail("Missing select group")
    }

    manager.setManualSelection(groupName: "Manual", policy: "DIRECT")
    XCTAssertEqual(manager.selectMember(for: group, profile: profile), "DIRECT")
  }

  func testURLTestGroupPicksFastestWithTolerance() {
    let manager = PolicyGroupManager()
    let profile = makeProfile()
    manager.sync(from: profile)

    guard let group = profile.proxyGroups.first(where: { $0.name == "Auto" }) else {
      return XCTFail("Missing url-test group")
    }

    manager.updateLatencyResults(for: group, results: ["Fast": 120, "Slow": 400, "DIRECT": 80])
    XCTAssertEqual(manager.selectMember(for: group, profile: profile), "DIRECT")

    manager.updateLatencyResults(for: group, results: ["Fast": 50, "Slow": 400, "DIRECT": 80])
    XCTAssertEqual(manager.selectMember(for: group, profile: profile), "DIRECT")

    manager.updateLatencyResults(for: group, results: ["Fast": 10, "Slow": 400, "DIRECT": 80])
    XCTAssertEqual(manager.selectMember(for: group, profile: profile), "Fast")
  }

  func testFallbackGroupSkipsUnavailableMembers() {
    let manager = PolicyGroupManager()
    let profile = makeProfile()
    manager.sync(from: profile)

    guard let group = profile.proxyGroups.first(where: { $0.name == "Backup" }) else {
      return XCTFail("Missing fallback group")
    }

    manager.markUnavailable("Fast")
    XCTAssertEqual(manager.selectMember(for: group, profile: profile), "Slow")
  }

  func testLoadBalanceGroupRotatesMembers() {
    let manager = PolicyGroupManager()
    let profile = makeProfile()
    manager.sync(from: profile)

    guard let group = profile.proxyGroups.first(where: { $0.name == "Spread" }) else {
      return XCTFail("Missing load-balance group")
    }

    let first = manager.selectMember(for: group, profile: profile)
    let second = manager.selectMember(for: group, profile: profile)
    XCTAssertNotEqual(first, second)
  }

  func testRuntimeStatesIncludeLatencyBadges() {
    let manager = PolicyGroupManager()
    let profile = makeProfile()
    manager.sync(from: profile)

    guard let group = profile.proxyGroups.first(where: { $0.name == "Auto" }) else {
      return XCTFail("Missing url-test group")
    }

    manager.updateLatencyResults(for: group, results: ["Fast": 42, "Slow": nil, "DIRECT": 90])
    let state = manager.runtimeStates(for: profile).first { $0.groupName == "Auto" }

    XCTAssertEqual(state?.activePolicy, "Fast")
    XCTAssertEqual(state?.members.first { $0.name == "Fast" }?.latencyMilliseconds, 42)
    XCTAssertNil(state?.members.first { $0.name == "Slow" }?.latencyMilliseconds)
  }
}

final class ProfileParserPolicyGroupTests: XCTestCase {
  func testParsesURLTestParameters() throws {
    let text = """
    [Proxy Group]
    Auto, url-test, US, JP, url=http://cp.cloudflare.com/generate_204, interval=300, tolerance=50
    """

    let profile = try ProfileParser().parse(text)
    let group = try XCTUnwrap(profile.proxyGroups.first)

    XCTAssertEqual(group.type, .urlTest)
    XCTAssertEqual(group.policies, ["US", "JP"])
    XCTAssertEqual(group.testURL, "http://cp.cloudflare.com/generate_204")
    XCTAssertEqual(group.testInterval, 300)
    XCTAssertEqual(group.tolerance, 50)
  }
}
