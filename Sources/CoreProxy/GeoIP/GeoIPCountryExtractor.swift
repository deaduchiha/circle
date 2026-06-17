import Foundation

enum GeoIPCountryExtractor {
  static func countryCode(from data: [String: Any]) -> String? {
    if let country = data["country"] as? [String: Any],
      let code = country["iso_code"] as? String,
      !code.isEmpty
    {
      return code.uppercased()
    }

    if let registered = data["registered_country"] as? [String: Any],
      let code = registered["iso_code"] as? String,
      !code.isEmpty
    {
      return code.uppercased()
    }

    return nil
  }
}
