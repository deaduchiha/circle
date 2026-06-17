import Foundation

public enum ProfileLoader {
  public static func loadDefault() -> Profile {
    guard let url = Bundle.module.url(forResource: "DefaultProfile", withExtension: "conf"),
      let text = try? String(contentsOf: url, encoding: .utf8),
      let profile = try? load(text: text, baseDirectory: url.deletingLastPathComponent())
    else {
      return Profile()
    }
    return profile
  }

  public static func load(
    text: String,
    baseDirectory: URL? = nil,
    modules: ProfileModuleSettings = .allEnabled
  ) throws -> Profile {
    let expanded = try ProfileIncludeResolver.expand(text, baseDirectory: baseDirectory)
    let profile = try ProfileParser().parse(expanded)
    return ProfileModuleFilter.apply(profile, modules: modules)
  }
}
