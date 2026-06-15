import Foundation

enum RuleResourceLoader {
  static func cacheDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("circle/rule-sets", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func loadText(from reference: String, profileDirectory: URL?) throws -> String {
    if reference.hasPrefix("http://") || reference.hasPrefix("https://") {
      return try loadRemote(reference)
    }

    let fileURL = resolveLocalURL(for: reference, profileDirectory: profileDirectory)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  static func resolveLocalURL(for reference: String, profileDirectory: URL?) -> URL {
    let expanded = NSString(string: reference).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    if url.path.hasPrefix("/") {
      return url
    }

    if let profileDirectory {
      return profileDirectory.appendingPathComponent(expanded)
    }

    if let resource = Bundle.module.url(forResource: expanded, withExtension: nil) {
      return resource
    }

    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(expanded)
  }

  private static func loadRemote(_ urlString: String) throws -> String {
    let cacheURL = cacheDirectory().appendingPathComponent(cacheFileName(for: urlString))
    if let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
      let modified = attributes[.modificationDate] as? Date,
      Date().timeIntervalSince(modified) < 86_400,
      let cached = try? String(contentsOf: cacheURL, encoding: .utf8)
    {
      return cached
    }

    guard let url = URL(string: urlString) else {
      throw RuleResourceLoaderError.invalidReference(urlString)
    }

    let (data, _) = try URLSession.shared.syncData(from: url)
    guard let text = String(data: data, encoding: .utf8) else {
      throw RuleResourceLoaderError.invalidEncoding(urlString)
    }

    try data.write(to: cacheURL)
    return text
  }

  private static func cacheFileName(for urlString: String) -> String {
    let hash = urlString.data(using: .utf8)?.base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      ?? UUID().uuidString
    return "\(hash).txt"
  }
}

enum RuleResourceLoaderError: Error, LocalizedError {
  case invalidReference(String)
  case invalidEncoding(String)

  var errorDescription: String? {
    switch self {
    case .invalidReference(let value):
      "Invalid rule resource reference: \(value)"
    case .invalidEncoding(let value):
      "Could not decode rule resource: \(value)"
    }
  }
}

private extension URLSession {
  func syncData(from url: URL) throws -> (Data, URLResponse) {
    var result: Result<(Data, URLResponse), Error>?
    let semaphore = DispatchSemaphore(value: 0)
    let task = dataTask(with: url) { data, response, error in
      if let error {
        result = .failure(error)
      } else if let data, let response {
        result = .success((data, response))
      } else {
        result = .failure(RuleResourceLoaderError.invalidEncoding(url.absoluteString))
      }
      semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    return try result!.get()
  }
}

struct DomainSetIndex: Sendable {
  private(set) var exactHosts: Set<String> = []
  private(set) var suffix = DomainTrie()

  init(contents: String) {
    var hosts: Set<String> = []
    var suffixTrie = DomainTrie()
    for rawLine in contents.components(separatedBy: .newlines) {
      let line = Self.stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }

      if line.hasPrefix(".") || line.hasPrefix("*.") {
        let suffixValue = line.trimmingCharacters(in: CharacterSet(charactersIn: ".*"))
        suffixTrie.insert(suffixValue, suffix: true)
      } else {
        hosts.insert(line.lowercased())
      }
    }
    exactHosts = hosts
    suffix = suffixTrie
  }

  func matches(_ host: String) -> Bool {
    exactHosts.contains(host.lowercased()) || suffix.longestSuffixMatch(for: host)
  }

  private static func stripComment(_ line: String) -> String {
    guard let comment = line.firstIndex(of: "#") else { return line }
    return String(line[..<comment])
  }
}

struct RuleSetPatterns: Sendable {
  let patterns: [RulePattern]

  init(contents: String) {
    var parsed: [RulePattern] = []
    for rawLine in contents.components(separatedBy: .newlines) {
      let line = Self.stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      if let pattern = LogicalRuleParser.parsePatternRule(line) {
        parsed.append(pattern)
      }
    }
    patterns = parsed
  }

  private static func stripComment(_ line: String) -> String {
    guard let comment = line.firstIndex(of: "#") else { return line }
    return String(line[..<comment])
  }
}
