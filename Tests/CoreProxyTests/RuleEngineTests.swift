import XCTest
@testable import CoreProxy

final class RuleEngineTests: XCTestCase {
    func testFirstMatchingRuleWins() {
        let engine = RuleEngine(rules: [
            Rule(type: .domainSuffix, value: "example.com", policy: "DIRECT"),
            Rule(type: .final, policy: "Proxy")
        ])

        let match = engine.evaluate(RuleEvaluationContext(host: "api.example.com"))

        XCTAssertEqual(match?.policy, "DIRECT")
        XCTAssertEqual(match?.rule.type, .domainSuffix)
    }

    func testFinalRuleMatchesFallback() {
        let engine = RuleEngine(rules: [
            Rule(type: .final, policy: "Proxy")
        ])

        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "openai.com"))?.policy, "Proxy")
    }

    func testIPv4CIDRRule() {
        let engine = RuleEngine(rules: [
            Rule(type: .ipCIDR, value: "192.168.1.0/24", policy: "DIRECT"),
            Rule(type: .final, policy: "Proxy")
        ])

        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "router.local", ipAddress: "192.168.1.42"))?.policy, "DIRECT")
    }
}
