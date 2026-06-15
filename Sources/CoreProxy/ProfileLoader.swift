import Foundation

public enum ProfileLoader {
  public static func loadDefault() -> Profile {
    guard let url = Bundle.module.url(forResource: "DefaultProfile", withExtension: "conf"),
      let text = try? String(contentsOf: url, encoding: .utf8),
      let profile = try? ProfileParser().parse(text)
    else {
      return Profile()
    }
    return profile
  }
}
