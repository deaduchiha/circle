import XCTest
@testable import CoreProxy

final class RuleFormatterTests: XCTestCase {
  func testSummaryForDomainRule() {
    let rule = Rule(type: .domainSuffix, value: "example.com", policy: "Proxy")
    XCTAssertEqual(RuleFormatter.summary(rule), "DOMAIN-SUFFIX, example.com → Proxy")
  }

  func testSummaryForLogicalRule() {
    let rule = Rule(
      type: .and,
      value: "((DOMAIN,example.com))",
      policy: "REJECT"
    )
    XCTAssertTrue(RuleFormatter.summary(rule).hasPrefix("AND"))
    XCTAssertTrue(RuleFormatter.summary(rule).contains("REJECT"))
  }

  func testRouteDescription() {
    XCTAssertEqual(RuleFormatter.routeDescription(.direct), "DIRECT")
    XCTAssertEqual(
      RuleFormatter.routeDescription(.upstream(ProxyConfig(name: "US", type: .http, host: "1.2.3.4", port: 8080))),
      "Proxy (US)"
    )
  }
}
