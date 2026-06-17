import Foundation

public enum GeoIPDatabasePaths {
  public static let databaseFileName = "GeoLite2-Country.mmdb"
  public static let editionID = "GeoLite2-Country"
  public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

  public static func applicationSupportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("circle", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  public static func databaseURL() -> URL {
    applicationSupportDirectory().appendingPathComponent(databaseFileName, isDirectory: false)
  }

  public static func bundledDatabaseURL() -> URL? {
    Bundle.module.url(forResource: "GeoLite2-Country", withExtension: "mmdb")
  }

  public static func resolveLicenseKey(from general: GeneralConfig) -> String? {
    if let key = general.geolite2LicenseKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
      return key
    }
    if let env = ProcessInfo.processInfo.environment["MAXMIND_LICENSE_KEY"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !env.isEmpty
    {
      return env
    }
    return nil
  }
}
