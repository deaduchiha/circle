import XCTest

@testable import CoreProxy

final class CertificateManagerTests: XCTestCase {
  func testGenerateCAAndIssueLeafCertificate() throws {
    let manager = CertificateManager.shared
    let status = try manager.generateCA()

    XCTAssertFalse(status.fingerprintSHA256.isEmpty)
    XCTAssertTrue(status.notValidAfter > status.notValidBefore)

    let leaf = try manager.leafMaterial(for: "example.com")
    XCTAssertTrue(leaf.certificate.subject.description.contains("example.com"))
  }

  func testLeafCertificateCacheReturnsSameMaterial() throws {
    let manager = CertificateManager.shared
    _ = try manager.generateCA()

    let first = try manager.leafMaterial(for: "cached.example.com")
    let second = try manager.leafMaterial(for: "cached.example.com")

    XCTAssertEqual(
      try first.certificate.serializeAsPEM().pemString,
      try second.certificate.serializeAsPEM().pemString
    )
  }

  func testShouldInterceptRespectsHostnameFilters() throws {
    let manager = CertificateManager.shared

    let allHosts = MITMConfig(enabled: true)
    XCTAssertTrue(manager.shouldIntercept(hostname: "api.apple.com", mitm: allHosts))

    let filtered = MITMConfig(enabled: true, hostnames: ["*.example.com", "exact.test"])
    XCTAssertTrue(manager.shouldIntercept(hostname: "www.example.com", mitm: filtered))
    XCTAssertTrue(manager.shouldIntercept(hostname: "exact.test", mitm: filtered))
    XCTAssertFalse(manager.shouldIntercept(hostname: "apple.com", mitm: filtered))
  }

  func testServerTLSConfigurationBuilds() throws {
    let manager = CertificateManager.shared
    _ = try manager.generateCA()

    let config = try manager.serverTLSConfiguration(for: "tls.example.com")
    XCTAssertFalse(config.certificateChain.isEmpty)
  }
}
