import Foundation

public enum ProfileStoreError: Error, LocalizedError, Equatable {
  case profileNotFound(UUID)
  case cannotDeleteLastProfile
  case invalidRemoteURL(String)
  case downloadFailed(String)

  public var errorDescription: String? {
    switch self {
    case .profileNotFound(let id):
      "Profile not found: \(id.uuidString)"
    case .cannotDeleteLastProfile:
      "At least one profile must remain."
    case .invalidRemoteURL(let url):
      "Invalid profile URL: \(url)"
    case .downloadFailed(let url):
      "Failed to download profile from \(url)"
    }
  }
}

public final class ProfileStore: @unchecked Sendable {
  public struct Index: Codable, Equatable, Sendable {
    public var profiles: [ProfileDocument]
    public var activeProfileID: UUID?
    public var iCloudSyncEnabled: Bool

    public init(
      profiles: [ProfileDocument] = [],
      activeProfileID: UUID? = nil,
      iCloudSyncEnabled: Bool = false
    ) {
      self.profiles = profiles
      self.activeProfileID = activeProfileID
      self.iCloudSyncEnabled = iCloudSyncEnabled
    }
  }

  private struct ProfileBundle: Codable {
    var document: ProfileDocument
    var sourceText: String
  }

  private let customRootDirectory: URL?
  private let fileManager: FileManager
  private let parser = ProfileParser()
  private let lock = NSLock()
  private var index: Index

  private var rootDirectory: URL {
    customRootDirectory ?? ProfileCloudSync.profilesRoot(fileManager: fileManager)
  }

  public init(customRootDirectory: URL? = nil, fileManager: FileManager = .default) throws {
    self.customRootDirectory = customRootDirectory
    self.fileManager = fileManager
    let resolvedRoot = customRootDirectory ?? ProfileCloudSync.profilesRoot(fileManager: fileManager)
    try fileManager.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)

    let indexURL = resolvedRoot.appendingPathComponent("index.json")
    if let data = try? Data(contentsOf: indexURL),
      let decoded = try? JSONDecoder().decode(Index.self, from: data)
    {
      index = decoded
    } else {
      index = Index()
    }

    if index.profiles.isEmpty && customRootDirectory == nil {
      let document = try createProfileLocked(name: "Default", sourceText: Self.defaultTemplateText())
      index.activeProfileID = document.id
      try saveIndexLocked()
    }
  }

  public var profiles: [ProfileDocument] {
    lock.lock()
    defer { lock.unlock() }
    return index.profiles
  }

  public var activeProfileID: UUID? {
    lock.lock()
    defer { lock.unlock() }
    return index.activeProfileID
  }

  public var iCloudSyncEnabled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return index.iCloudSyncEnabled
  }

  public func profileDirectory(for id: UUID) -> URL {
    rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  @discardableResult
  public func createProfile(name: String, sourceText: String? = nil) throws -> ProfileDocument {
    lock.lock()
    defer { lock.unlock() }
    return try createProfileLocked(name: name, sourceText: sourceText ?? Self.blankTemplateText())
  }

  @discardableResult
  public func duplicateProfile(id: UUID) throws -> ProfileDocument {
    lock.lock()
    defer { lock.unlock() }

    guard let existing = index.profiles.first(where: { $0.id == id }) else {
      throw ProfileStoreError.profileNotFound(id)
    }

    let sourceText = try loadSourceLocked(id: id)
    var copy = existing
    copy.id = UUID()
    copy.name = "\(existing.name) Copy"
    copy.createdAt = Date()
    copy.updatedAt = Date()
    copy.sourceURL = nil
    try saveBundleLocked(document: copy, sourceText: sourceText)
    index.profiles.append(copy)
    try saveIndexLocked()
    return copy
  }

  public func renameProfile(id: UUID, name: String) throws {
    lock.lock()
    defer { lock.unlock() }

    guard let indexPosition = index.profiles.firstIndex(where: { $0.id == id }) else {
      throw ProfileStoreError.profileNotFound(id)
    }

    index.profiles[indexPosition].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    index.profiles[indexPosition].updatedAt = Date()
    let sourceText = try loadSourceLocked(id: id)
    try saveBundleLocked(document: index.profiles[indexPosition], sourceText: sourceText)
    try saveIndexLocked()
  }

  public func deleteProfile(id: UUID) throws {
    lock.lock()
    defer { lock.unlock() }

    guard index.profiles.count > 1 else {
      throw ProfileStoreError.cannotDeleteLastProfile
    }
    guard let indexPosition = index.profiles.firstIndex(where: { $0.id == id }) else {
      throw ProfileStoreError.profileNotFound(id)
    }

    index.profiles.remove(at: indexPosition)
    try fileManager.removeItem(at: profileDirectory(for: id))

    if index.activeProfileID == id {
      index.activeProfileID = index.profiles.first?.id
    }

    try saveIndexLocked()
  }

  public func setActiveProfile(id: UUID) throws {
    lock.lock()
    defer { lock.unlock() }

    guard index.profiles.contains(where: { $0.id == id }) else {
      throw ProfileStoreError.profileNotFound(id)
    }

    index.activeProfileID = id
    try saveIndexLocked()
  }

  public func updateModules(for id: UUID, modules: ProfileModuleSettings) throws {
    lock.lock()
    defer { lock.unlock() }

    guard let indexPosition = index.profiles.firstIndex(where: { $0.id == id }) else {
      throw ProfileStoreError.profileNotFound(id)
    }

    index.profiles[indexPosition].modules = modules
    index.profiles[indexPosition].updatedAt = Date()
    let sourceText = try loadSourceLocked(id: id)
    try saveBundleLocked(document: index.profiles[indexPosition], sourceText: sourceText)
    try saveIndexLocked()
  }

  public func loadSource(id: UUID) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    return try loadSourceLocked(id: id)
  }

  public func saveSource(id: UUID, text: String) throws -> ProfileDocument {
    lock.lock()
    defer { lock.unlock() }

    guard let indexPosition = index.profiles.firstIndex(where: { $0.id == id }) else {
      throw ProfileStoreError.profileNotFound(id)
    }

    index.profiles[indexPosition].updatedAt = Date()
    try saveBundleLocked(document: index.profiles[indexPosition], sourceText: text)
    try saveIndexLocked()
    return index.profiles[indexPosition]
  }

  public func parseProfile(
    id: UUID,
    sourceText: String? = nil,
    modules overrideModules: ProfileModuleSettings? = nil
  ) throws -> Profile {
    lock.lock()
    guard let document = index.profiles.first(where: { $0.id == id }) else {
      lock.unlock()
      throw ProfileStoreError.profileNotFound(id)
    }
    let modules = overrideModules ?? document.modules
    let baseDirectory = profileDirectory(for: id)
    let text: String
    if let sourceText {
      text = sourceText
      lock.unlock()
    } else {
      do {
        text = try loadSourceLocked(id: id)
        lock.unlock()
      } catch {
        lock.unlock()
        throw error
      }
    }

    return try parseProfileText(text, baseDirectory: baseDirectory, modules: modules)
  }

  public func parseProfileText(
    _ text: String,
    baseDirectory: URL?,
    modules: ProfileModuleSettings = .allEnabled
  ) throws -> Profile {
    let expanded = try ProfileIncludeResolver.expand(text, baseDirectory: baseDirectory)
    let profile = try parser.parse(expanded)
    return ProfileModuleFilter.apply(profile, modules: modules)
  }

  public func importFromURL(_ urlString: String, name: String? = nil) async throws -> ProfileDocument {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
      throw ProfileStoreError.invalidRemoteURL(urlString)
    }

    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw ProfileStoreError.downloadFailed(trimmed)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw ProfileStoreError.downloadFailed(trimmed)
    }

    let profileName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? url.deletingPathExtension().lastPathComponent.nilIfEmpty
      ?? "Imported Profile"

    return try importDownloadedProfile(name: profileName, sourceURL: trimmed, text: text)
  }

  private func importDownloadedProfile(
    name profileName: String,
    sourceURL: String,
    text: String
  ) throws -> ProfileDocument {
    lock.lock()
    defer { lock.unlock() }

    var document = try createProfileLocked(name: profileName, sourceText: text)
    document.sourceURL = sourceURL
    if let indexPosition = index.profiles.firstIndex(where: { $0.id == document.id }) {
      index.profiles[indexPosition] = document
      try saveBundleLocked(document: document, sourceText: text)
      try saveIndexLocked()
    }
    return document
  }

  public func setiCloudSyncEnabled(_ enabled: Bool) throws {
    lock.lock()
    defer { lock.unlock() }
    index.iCloudSyncEnabled = enabled
    try saveIndexLocked()
  }

  public func activeDocument() -> ProfileDocument? {
    lock.lock()
    defer { lock.unlock() }
    guard let id = index.activeProfileID else { return index.profiles.first }
    return index.profiles.first { $0.id == id } ?? index.profiles.first
  }

  private func createProfileLocked(name: String, sourceText: String) throws -> ProfileDocument {
    let document = ProfileDocument(name: name)
    try saveBundleLocked(document: document, sourceText: sourceText)
    index.profiles.append(document)
    if index.activeProfileID == nil {
      index.activeProfileID = document.id
    }
    try saveIndexLocked()
    return document
  }

  private func saveBundleLocked(document: ProfileDocument, sourceText: String) throws {
    let directory = profileDirectory(for: document.id)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let bundle = ProfileBundle(document: document, sourceText: sourceText)
    let bundleURL = directory.appendingPathComponent("bundle.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(bundle)
    try data.write(to: bundleURL, options: .atomic)
  }

  private func loadSourceLocked(id: UUID) throws -> String {
    try loadBundleLocked(id: id).sourceText
  }

  private func loadBundleLocked(id: UUID) throws -> ProfileBundle {
    let bundleURL = profileDirectory(for: id).appendingPathComponent("bundle.json")
    guard fileManager.fileExists(atPath: bundleURL.path) else {
      throw ProfileStoreError.profileNotFound(id)
    }

    let data = try Data(contentsOf: bundleURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ProfileBundle.self, from: data)
  }

  private func saveIndexLocked() throws {
    let indexURL = rootDirectory.appendingPathComponent("index.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(index)
    try data.write(to: indexURL, options: .atomic)
  }

  private static func defaultRootDirectory(fileManager: FileManager) -> URL {
    ProfileCloudSync.profilesRoot(fileManager: fileManager)
  }

  private static func defaultTemplateText() -> String {
    guard let url = Bundle.module.url(forResource: "DefaultProfile", withExtension: "conf"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else {
      return blankTemplateText()
    }
    return text
  }

  private static func blankTemplateText() -> String {
    """
    [General]
    http-port = 8888
    dashboard-port = 8234
    log-level = info

    [Rule]
    FINAL, DIRECT
    """
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
