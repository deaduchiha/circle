import Foundation
import XCTest
@testable import CoreProxy

final class RuleEngineTests: XCTestCase {
    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    func testFirstMatchingRuleWins() {
        let engine = RuleEngine(rules: [
            Rule(type: .domainSuffix, value: "example.com", policy: "DIRECT"),
            Rule(type: .final, policy: "Proxy")
        ])

        let match = engine.evaluate(RuleEvaluationContext(host: "api.example.com"))

        XCTAssertEqual(match?.policy, "DIRECT")
        XCTAssertEqual(match?.rule.type, .domainSuffix)
    }

    func testLogicalParserProducesItems() {
        XCTAssertEqual(LogicalRuleParser.parseGroupItems("((DOMAIN,apple.com))")?.count, 1)
        XCTAssertEqual(
            LogicalRuleParser.parseGroupItems("((DOMAIN,blocked.test),(DOMAIN-KEYWORD,ads))")?.count,
            2
        )
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

        XCTAssertEqual(
            engine.evaluate(RuleEvaluationContext(host: "router.local", ipAddress: "192.168.1.42"))?.policy,
            "DIRECT"
        )
    }

    func testIPv6CIDRRule() {
        let engine = RuleEngine(rules: [
            Rule(type: .ipCIDR6, value: "2001:db8::/32", policy: "DIRECT"),
            Rule(type: .final, policy: "Proxy")
        ])

        XCTAssertEqual(
            engine.evaluate(
                RuleEvaluationContext(host: "ipv6.test", ipAddress: "2001:db8:1234::1")
            )?.policy,
            "DIRECT"
        )
    }

    func testURLRegexRuleUsesCache() {
        let engine = RuleEngine(rules: [
            Rule(type: .urlRegex, value: "^https://api\\.example\\.com/v[0-9]+/", policy: "Proxy"),
            Rule(type: .final, policy: "DIRECT")
        ])

        let context = RuleEvaluationContext(
            host: "api.example.com",
            url: URL(string: "https://api.example.com/v2/users")
        )

        XCTAssertEqual(engine.evaluate(context)?.policy, "Proxy")
        XCTAssertEqual(engine.evaluate(context)?.policy, "Proxy")
    }

    func testANDRuleRequiresAllPatterns() {
        let engine = RuleEngine(rules: [
            Rule(
                type: .and,
                value: "((DOMAIN-SUFFIX,example.com),(URL-REGEX,^https://api))",
                policy: "Proxy"
            ),
            Rule(type: .final, policy: "DIRECT")
        ])

        let matching = RuleEvaluationContext(
            host: "api.example.com",
            url: URL(string: "https://api.example.com/data")
        )
        let nonMatching = RuleEvaluationContext(
            host: "api.example.com",
            url: URL(string: "http://api.example.com/data")
        )

        XCTAssertEqual(engine.evaluate(matching)?.policy, "Proxy")
        XCTAssertEqual(engine.evaluate(nonMatching)?.policy, "DIRECT")
    }

    func testORRuleMatchesAnyPattern() {
        let engine = RuleEngine(rules: [
            Rule(
                type: .or,
                value: "((DOMAIN,blocked.test),(DOMAIN-KEYWORD,ads))",
                policy: "REJECT"
            ),
            Rule(type: .final, policy: "DIRECT")
        ])

        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "blocked.test"))?.policy, "REJECT")
        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "ads.example.com"))?.policy, "REJECT")
        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "safe.example.com"))?.policy, "DIRECT")
    }

    func testNOTRuleInvertsMatch() {
        let engine = RuleEngine(rules: [
            Rule(type: .not, value: "((DOMAIN,apple.com))", policy: "Proxy"),
            Rule(type: .final, policy: "DIRECT")
        ])

        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "google.com"))?.policy, "Proxy")
        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "apple.com"))?.policy, "DIRECT")
    }

    func testDomainSetRuleLoadsLocalFile() {
        let path = fixturesDirectory.appendingPathComponent("test-domains.txt").path
        let engine = RuleEngine(
            rules: [
                Rule(type: .domainSet, value: path, policy: "REJECT"),
                Rule(type: .final, policy: "DIRECT")
            ],
            configuration: RuleEngineConfiguration(profileDirectory: fixturesDirectory)
        )

        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "example.com"))?.policy, "REJECT")
        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "cdn.example.com"))?.policy, "REJECT")
        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "ads.example.ads-network.test"))?.policy, "REJECT")
        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "other.com"))?.policy, "DIRECT")
    }

    func testRuleSetRuleLoadsLocalPatterns() {
        let path = fixturesDirectory.appendingPathComponent("test-rules.list").path
        let engine = RuleEngine(
            rules: [
                Rule(type: .ruleSet, value: path, policy: "REJECT"),
                Rule(type: .final, policy: "DIRECT")
            ],
            configuration: RuleEngineConfiguration(profileDirectory: fixturesDirectory)
        )

        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "api.blocked.test"))?.policy, "REJECT")
        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "tracker.example.com"))?.policy, "REJECT")
        XCTAssertEqual(
            engine.evaluate(RuleEvaluationContext(host: "internal", ipAddress: "10.1.2.3"))?.policy,
            "REJECT"
        )
    }

    func testGeoIPRuleUsesLookupProvider() {
        let engine = RuleEngine(
            rules: [
                Rule(type: .geoIP, value: "CN", policy: "DIRECT"),
                Rule(type: .final, policy: "Proxy")
            ],
            configuration: RuleEngineConfiguration(
                geoIPLookup: GeoIPLookup { ip in
                    ip.hasPrefix("203.0.113") ? "CN" : "US"
                }
            )
        )

        XCTAssertEqual(
            engine.evaluate(RuleEvaluationContext(host: "cn.example", ipAddress: "203.0.113.10"))?.policy,
            "DIRECT"
        )
        XCTAssertEqual(
            engine.evaluate(RuleEvaluationContext(host: "us.example", ipAddress: "198.51.100.4"))?.policy,
            "Proxy"
        )
    }

    func testMatchCacheReturnsSameResultUntilFlushed() {
        let engine = RuleEngine(
            rules: [
                Rule(type: .domain, value: "cached.test", policy: "Proxy"),
                Rule(type: .final, policy: "DIRECT")
            ],
            configuration: RuleEngineConfiguration(enableMatchCache: true, cacheTTL: 60)
        )

        let context = RuleEvaluationContext(host: "cached.test")
        XCTAssertEqual(engine.evaluate(context)?.policy, "Proxy")
        XCTAssertEqual(engine.evaluate(RuleEvaluationContext(host: "other.test"))?.policy, "DIRECT")

        engine.flushCache()
        XCTAssertEqual(engine.evaluate(context)?.policy, "Proxy")
    }

    func testDomainTrieMatchesExactAndSuffixEntries() {
        var trie = DomainTrie()
        trie.insert("example.com", suffix: false)
        trie.insert("ads.test", suffix: true)

        XCTAssertTrue(trie.contains("example.com"))
        XCTAssertFalse(trie.contains("cdn.example.com"))
        XCTAssertTrue(trie.longestSuffixMatch(for: "banner.ads.test"))
    }
}
