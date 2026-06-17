@testable import CoreProxy
import XCTest

final class GeoIPCountryExtractorTests: XCTestCase {
  func testExtractsCountryISOCode() {
    let data: [String: Any] = [
      "country": ["iso_code": "CN", "names": ["en": "China"]]
    ]

    XCTAssertEqual(GeoIPCountryExtractor.countryCode(from: data), "CN")
  }

  func testFallsBackToRegisteredCountry() {
    let data: [String: Any] = [
      "registered_country": ["iso_code": "US"]
    ]

    XCTAssertEqual(GeoIPCountryExtractor.countryCode(from: data), "US")
  }

  func testReturnsNilWhenMissing() {
    XCTAssertNil(GeoIPCountryExtractor.countryCode(from: [:]))
  }
}

final class GeoIPDatabaseUpdaterTests: XCTestCase {
  func testDetectsStaleDatabase() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appendingPathComponent(GeoIPDatabasePaths.databaseFileName)
    FileManager.default.createFile(atPath: databaseURL.path, contents: Data("test".utf8))

    let oldDate = Date().addingTimeInterval(-(GeoIPDatabasePaths.maxAge + 60))
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: databaseURL.path)

    XCTAssertTrue(GeoIPDatabaseUpdater.isStale(at: databaseURL))
  }

  func testFreshDatabaseIsNotStale() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appendingPathComponent(GeoIPDatabasePaths.databaseFileName)
    FileManager.default.createFile(atPath: databaseURL.path, contents: Data("test".utf8))

    XCTAssertFalse(GeoIPDatabaseUpdater.isStale(at: databaseURL))
  }
}

final class GeoIPServiceTests: XCTestCase {
  func testLookupUsesInstalledDatabaseWhenPresent() throws {
    guard let bundled = GeoIPDatabasePaths.bundledDatabaseURL() else {
      throw XCTSkip("GeoLite2-Country.mmdb is not bundled in Resources/")
    }

    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let databaseURL = tempDir.appendingPathComponent(GeoIPDatabasePaths.databaseFileName)
    try FileManager.default.copyItem(at: bundled, to: databaseURL)

    let service = GeoIPService(databaseURL: databaseURL)

    XCTAssertTrue(service.status().isLoaded)
    XCTAssertEqual(service.countryCode(for: "1.1.1.1"), "US")
  }
}
