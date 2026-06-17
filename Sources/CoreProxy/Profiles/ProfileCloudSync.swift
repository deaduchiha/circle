import Foundation

public enum ProfileCloudSync {
  public static let featureFlagKey = "circle.profile.iCloudSyncEnabled"

  public static var isFeatureEnabled: Bool {
    UserDefaults.standard.bool(forKey: featureFlagKey)
  }

  public static func setFeatureEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: featureFlagKey)
  }

  public static func profilesRoot(fileManager: FileManager = .default) -> URL {
    if isFeatureEnabled,
      let ubiquity = fileManager.url(forUbiquityContainerIdentifier: nil)?
        .appendingPathComponent("Documents/circle/profiles", isDirectory: true)
    {
      return ubiquity
    }

    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return base.appendingPathComponent("circle/profiles", isDirectory: true)
  }

  public static func migrateProfiles(toICloud enabled: Bool, fileManager: FileManager = .default) throws {
    let local = localProfilesRoot(fileManager: fileManager)
    let target = enabled ? cloudProfilesRoot(fileManager: fileManager) : localProfilesRoot(fileManager: fileManager)
    let source = enabled ? local : cloudProfilesRoot(fileManager: fileManager)

    guard source != target, fileManager.fileExists(atPath: source.path) else {
      setFeatureEnabled(enabled)
      return
    }

    if fileManager.fileExists(atPath: target.path) {
      let backup = target.deletingLastPathComponent()
        .appendingPathComponent("profiles-backup-\(UUID().uuidString)", isDirectory: true)
      try fileManager.moveItem(at: target, to: backup)
    }

    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.copyItem(at: source, to: target)
    setFeatureEnabled(enabled)
  }

  private static func localProfilesRoot(fileManager: FileManager) -> URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return base.appendingPathComponent("circle/profiles", isDirectory: true)
  }

  private static func cloudProfilesRoot(fileManager: FileManager) -> URL {
    fileManager.url(forUbiquityContainerIdentifier: nil)?
      .appendingPathComponent("Documents/circle/profiles", isDirectory: true)
      ?? localProfilesRoot(fileManager: fileManager)
  }
}
