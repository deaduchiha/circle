@testable import CoreProxy
import XCTest

final class ProfileIncludeResolverTests: XCTestCase {
  func testExpandsLocalInclude() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let included = directory.appendingPathComponent("rules.conf")
    try """
    [Rule]
    DOMAIN-SUFFIX, included.test, DIRECT
    """.write(to: included, atomically: true, encoding: .utf8)

    let main = """
    [General]
    http-port = 8888

    #!include rules.conf

    [Rule]
    FINAL, DIRECT
    """

    let expanded = try ProfileIncludeResolver.expand(main, baseDirectory: directory)
    let profile = try ProfileParser().parse(expanded)

    XCTAssertEqual(profile.general.httpPort, 8888)
    XCTAssertEqual(profile.rules.count, 2)
    XCTAssertEqual(profile.rules.first?.type, .domainSuffix)
  }

  func testDetectsCircularInclude() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let a = directory.appendingPathComponent("a.conf")
    let b = directory.appendingPathComponent("b.conf")
    try "#!include b.conf".write(to: a, atomically: true, encoding: .utf8)
    try "#!include a.conf".write(to: b, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try ProfileIncludeResolver.expand("#!include a.conf", baseDirectory: directory)) { error in
      XCTAssertEqual(error as? ProfileIncludeError, .circularInclude(a.standardizedFileURL.path))
    }
  }
}

final class ProfileModuleFilterTests: XCTestCase {
  func testDisablesRulesModule() {
    let profile = Profile(
      proxies: [ProxyConfig(name: "Demo", type: .http, host: "127.0.0.1", port: 7890)],
      proxyGroups: [PolicyGroup(name: "Proxy", type: .select, policies: ["Demo"])],
      rules: [Rule(type: .domain, value: "example.com", policy: "REJECT")],
      hosts: ["localhost": "127.0.0.1"],
      dnsConfig: DNSConfig(fakeIPEnabled: true),
      mitm: MITMConfig(enabled: true),
      scripts: [ScriptConfig(name: "test", event: "http-request", path: "test.js")]
    )

    var modules = ProfileModuleSettings.allEnabled
    modules.rules = false
    modules.proxies = false
    modules.proxyGroups = false
    modules.hosts = false
    modules.dns = false
    modules.mitm = false
    modules.scripts = false

    let filtered = ProfileModuleFilter.apply(profile, modules: modules)

    XCTAssertTrue(filtered.proxies.isEmpty)
    XCTAssertTrue(filtered.proxyGroups.isEmpty)
    XCTAssertEqual(filtered.rules.count, 1)
    XCTAssertEqual(filtered.rules.first?.type, .final)
    XCTAssertTrue(filtered.hosts.isEmpty)
    XCTAssertFalse(filtered.dnsConfig.fakeIPEnabled)
    XCTAssertFalse(filtered.mitm.enabled)
    XCTAssertTrue(filtered.scripts.isEmpty)
  }
}

final class ProfileStoreTests: XCTestCase {
  func testCreateDuplicateRenameDelete() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try ProfileStore(customRootDirectory: root)

    let first = try store.createProfile(name: "Primary", sourceText: "[General]\nhttp-port = 9000\n\n[Rule]\nFINAL, DIRECT")
    let duplicate = try store.duplicateProfile(id: first.id)
    XCTAssertEqual(duplicate.name, "Primary Copy")

    try store.renameProfile(id: duplicate.id, name: "Secondary")
    XCTAssertEqual(store.profiles.first { $0.id == duplicate.id }?.name, "Secondary")

    try store.deleteProfile(id: duplicate.id)
    XCTAssertEqual(store.profiles.count, 1)
  }

  func testParseProfileAppliesModules() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try ProfileStore(customRootDirectory: root)
    let document = try store.createProfile(
      name: "Modules",
      sourceText: """
      [General]
      http-port = 8888

      [Proxy]
      Demo, http, 127.0.0.1, 7890

      [Rule]
      DOMAIN, example.com, REJECT
      FINAL, DIRECT
      """
    )

    var modules = document.modules
    modules.proxies = false
    modules.rules = false
    try store.updateModules(for: document.id, modules: modules)

    let profile = try store.parseProfile(id: document.id)
    XCTAssertTrue(profile.proxies.isEmpty)
    XCTAssertEqual(profile.rules.count, 1)
    XCTAssertEqual(profile.rules.first?.type, .final)
  }
}
