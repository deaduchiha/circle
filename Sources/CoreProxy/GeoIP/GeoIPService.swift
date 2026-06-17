import Foundation
import MaxMindDB

public enum GeoIPServiceError: Error, LocalizedError {
  case databaseMissing
  case openFailed(String)

  public var errorDescription: String? {
    switch self {
    case .databaseMissing:
      "GeoLite2-Country.mmdb was not found. Add it to Resources/ or configure a MaxMind license key."
    case .openFailed(let message):
      "Failed to open GeoIP database: \(message)"
    }
  }
}

public struct GeoIPDatabaseStatus: Equatable, Sendable {
  public var isLoaded: Bool
  public var databasePath: String?
  public var modifiedAt: Date?
  public var isStale: Bool
  public var lastError: String?

  public init(
    isLoaded: Bool,
    databasePath: String? = nil,
    modifiedAt: Date? = nil,
    isStale: Bool = false,
    lastError: String? = nil
  ) {
    self.isLoaded = isLoaded
    self.databasePath = databasePath
    self.modifiedAt = modifiedAt
    self.isStale = isStale
    self.lastError = lastError
  }
}

public final class GeoIPService: @unchecked Sendable {
  private let lock = NSLock()
  private var reader: GeoIP2?
  private var lastError: String?

  public init(databaseURL: URL? = nil) {
    if let databaseURL {
      try? load(from: databaseURL)
    } else if FileManager.default.fileExists(atPath: GeoIPDatabasePaths.databaseURL().path) {
      try? load(from: GeoIPDatabasePaths.databaseURL())
    } else if let bundled = GeoIPDatabasePaths.bundledDatabaseURL() {
      try? installBundledDatabase(from: bundled)
      try? load(from: GeoIPDatabasePaths.databaseURL())
    }
  }

  public var lookup: GeoIPLookup {
    GeoIPLookup { [weak self] ip in
      self?.countryCode(for: ip)
    }
  }

  public func status() -> GeoIPDatabaseStatus {
    let url = GeoIPDatabasePaths.databaseURL()
    let exists = FileManager.default.fileExists(atPath: url.path)
    let modifiedAt = GeoIPDatabaseUpdater.modificationDate(at: url)
    let isStale = exists ? GeoIPDatabaseUpdater.isStale(at: url) : true

    lock.lock()
    defer { lock.unlock() }

    return GeoIPDatabaseStatus(
      isLoaded: reader != nil,
      databasePath: exists ? url.path : nil,
      modifiedAt: modifiedAt,
      isStale: isStale,
      lastError: lastError
    )
  }

  public func countryCode(for ip: String) -> String? {
    lock.lock()
    let reader = reader
    lock.unlock()

    guard let reader else { return nil }

    do {
      let result = try reader.lookup(ip: ip)
      return GeoIPCountryExtractor.countryCode(from: result.data)
    } catch {
      lock.lock()
      lastError = error.localizedDescription
      lock.unlock()
      return nil
    }
  }

  @discardableResult
  public func load(from url: URL) throws -> GeoIPDatabaseStatus {
    let reader = try GeoIP2(databasePath: url.path)

    lock.lock()
    self.reader = reader
    lastError = nil
    lock.unlock()

    return status()
  }

  @discardableResult
  public func installBundledDatabase(from bundledURL: URL? = GeoIPDatabasePaths.bundledDatabaseURL()) throws
    -> URL
  {
    guard let bundledURL else {
      throw GeoIPServiceError.databaseMissing
    }

    let destination = GeoIPDatabasePaths.databaseURL()
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }

    try FileManager.default.copyItem(at: bundledURL, to: destination)
    return destination
  }
}
