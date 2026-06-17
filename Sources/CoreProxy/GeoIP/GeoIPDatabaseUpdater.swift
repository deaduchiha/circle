import Foundation

public enum GeoIPDatabaseUpdaterError: Error, LocalizedError {
  case missingLicenseKey
  case downloadFailed(Int)
  case invalidArchive
  case databaseNotFoundInArchive

  public var errorDescription: String? {
    switch self {
    case .missingLicenseKey:
      "MaxMind license key is required. Set geolite2-license-key in [General] or MAXMIND_LICENSE_KEY."
    case .downloadFailed(let statusCode):
      "GeoLite2 download failed with HTTP status \(statusCode)."
    case .invalidArchive:
      "Downloaded GeoLite2 archive is invalid."
    case .databaseNotFoundInArchive:
      "GeoLite2-Country.mmdb was not found in the downloaded archive."
    }
  }
}

public enum GeoIPDatabaseUpdater {
  public static func modificationDate(at url: URL) -> Date? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
  }

  public static func isStale(at url: URL = GeoIPDatabasePaths.databaseURL(), now: Date = Date()) -> Bool {
    guard let modifiedAt = modificationDate(at: url) else { return true }
    return now.timeIntervalSince(modifiedAt) > GeoIPDatabasePaths.maxAge
  }

  @discardableResult
  public static func ensureInstalled() throws -> URL {
    let destination = GeoIPDatabasePaths.databaseURL()
    if FileManager.default.fileExists(atPath: destination.path) {
      return destination
    }

    if let bundled = GeoIPDatabasePaths.bundledDatabaseURL() {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.copyItem(at: bundled, to: destination)
      return destination
    }

    throw GeoIPServiceError.databaseMissing
  }

  public static func downloadAndInstall(licenseKey: String) async throws -> URL {
    let trimmedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      throw GeoIPDatabaseUpdaterError.missingLicenseKey
    }

    var components = URLComponents(string: "https://download.maxmind.com/app/geoip_download")!
    components.queryItems = [
      URLQueryItem(name: "edition_id", value: GeoIPDatabasePaths.editionID),
      URLQueryItem(name: "license_key", value: trimmedKey),
      URLQueryItem(name: "suffix", value: "tar.gz"),
    ]

    guard let downloadURL = components.url else {
      throw GeoIPDatabaseUpdaterError.invalidArchive
    }

    let (tempArchive, response) = try await URLSession.shared.download(from: downloadURL)
    defer { try? FileManager.default.removeItem(at: tempArchive) }

    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw GeoIPDatabaseUpdaterError.downloadFailed(http.statusCode)
    }

    let extractedDatabase = try extractDatabase(fromArchive: tempArchive)
    let destination = GeoIPDatabasePaths.databaseURL()
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let staged = directory.appendingPathComponent("GeoLite2-Country.staging.mmdb")
    if FileManager.default.fileExists(atPath: staged.path) {
      try FileManager.default.removeItem(at: staged)
    }
    try FileManager.default.copyItem(at: extractedDatabase, to: staged)

    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: staged, to: destination)

    return destination
  }

  static func extractDatabase(fromArchive archiveURL: URL) throws -> URL {
    let extractionDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("circle-geolite2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: extractionDirectory) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-xzf", archiveURL.path, "-C", extractionDirectory.path]

    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw GeoIPDatabaseUpdaterError.invalidArchive
    }

    let enumerator = FileManager.default.enumerator(
      at: extractionDirectory,
      includingPropertiesForKeys: nil
    )

    while let item = enumerator?.nextObject() as? URL {
      if item.lastPathComponent == GeoIPDatabasePaths.databaseFileName {
        return item
      }
    }

    throw GeoIPDatabaseUpdaterError.databaseNotFoundInArchive
  }
}
