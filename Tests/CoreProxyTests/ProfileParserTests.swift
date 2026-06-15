import XCTest
@testable import CoreProxy

final class ProfileParserTests: XCTestCase {
    func testParsesSurgeStyleProfile() throws {
        let text = """
        [General]
        http-port = 8888
        dashboard-port = 8234

        [Proxy]
        Demo, http, 127.0.0.1, 7890, username=me

        [Proxy Group]
        Proxy, select, Demo, DIRECT, REJECT

        [Rule]
        DOMAIN-SUFFIX, apple.com, DIRECT
        DOMAIN-KEYWORD, ads, REJECT
        FINAL, Proxy

        [DNS]
        server = 1.1.1.1, 8.8.8.8
        fake-ip = true
        """

        let profile = try ProfileParser().parse(text)

        XCTAssertEqual(profile.general.httpPort, 8888)
        XCTAssertEqual(profile.proxies.first?.name, "Demo")
        XCTAssertEqual(profile.proxyGroups.first?.policies, ["Demo", "DIRECT", "REJECT"])
        XCTAssertEqual(profile.rules.count, 3)
        XCTAssertTrue(profile.dnsConfig.fakeIPEnabled)
    }

    func testSerializesProfile() {
        let profile = Profile(rules: [Rule(type: .final, policy: "DIRECT")])
        let text = ProfileParser().serialize(profile)

        XCTAssertTrue(text.contains("[General]"))
        XCTAssertTrue(text.contains("FINAL, DIRECT"))
    }
}
