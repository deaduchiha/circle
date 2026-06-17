import XCTest
@testable import CoreProxy

final class PolicyRouterTests: XCTestCase {
    func testResolvesDirectPolicy() {
        let route = PolicyRouter.resolve(policy: "DIRECT", in: Profile())
        XCTAssertEqual(route, .direct)
    }

    func testResolvesRejectPolicy() {
        let route = PolicyRouter.resolve(policy: "REJECT", in: Profile())
        XCTAssertEqual(route, .reject)
    }

    func testResolvesNamedProxy() {
        let profile = Profile(proxies: [
            ProxyConfig(name: "Demo", type: .http, host: "127.0.0.1", port: 7890)
        ])
        let route = PolicyRouter.resolve(policy: "Demo", in: profile)
        XCTAssertEqual(route, .upstream(profile.proxies[0]))
    }

    func testResolvesPolicyGroupSelection() {
        let manager = PolicyGroupManager()
        let profile = Profile(
            proxies: [ProxyConfig(name: "Demo", type: .http, host: "127.0.0.1", port: 7890)],
            proxyGroups: [PolicyGroup(name: "Proxy", type: .select, policies: ["Demo", "DIRECT"], selectedPolicy: "DIRECT")]
        )
        manager.sync(from: profile)

        XCTAssertEqual(PolicyRouter.resolve(policy: "Proxy", in: profile, groupManager: manager), .direct)
    }

    func testResolvesNestedPolicyGroupThroughURLTestSelection() {
        let manager = PolicyGroupManager()
        let profile = Profile(
            proxies: [ProxyConfig(name: "Demo", type: .http, host: "127.0.0.1", port: 7890)],
            proxyGroups: [
                PolicyGroup(name: "Auto", type: .urlTest, policies: ["Demo", "DIRECT"]),
                PolicyGroup(name: "Proxy", type: .select, policies: ["Auto", "DIRECT"]),
            ]
        )
        manager.sync(from: profile)
        manager.updateLatencyResults(
            for: profile.proxyGroups[0],
            results: ["Demo": 100, "DIRECT": 200]
        )

        let route = PolicyRouter.resolve(policy: "Proxy", in: profile, groupManager: manager)
        XCTAssertEqual(route, .upstream(profile.proxies[0]))
    }

    func testEvaluatesHostAgainstRules() {
        let profile = Profile(rules: [
            Rule(type: .domainKeyword, value: "ads", policy: "REJECT"),
            Rule(type: .final, policy: "DIRECT")
        ])

        let evaluation = PolicyRouter.evaluate(host: "ads.example.com", path: "/", profile: profile)
        XCTAssertEqual(evaluation.route, .reject)
        XCTAssertEqual(evaluation.match?.rule.type, .domainKeyword)
    }
}
