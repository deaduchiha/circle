import Foundation

public enum ProfileIncludeError: Error, LocalizedError, Equatable {
  case circularInclude(String)
  case includeNotFound(String)
  case remoteIncludeFailed(String)

  public var errorDescription: String? {
    switch self {
    case .circularInclude(let path):
      "Circular include detected: \(path)"
    case .includeNotFound(let path):
      "Include file not found: \(path)"
    case .remoteIncludeFailed(let url):
      "Failed to download include: \(url)"
    }
  }
}

public enum ProfileIncludeResolver {
  public static func expand(_ text: String, baseDirectory: URL?) throws -> String {
    var includedPaths: Set<String> = []
    return try expand(text, baseDirectory: baseDirectory, includedPaths: &includedPaths)
  }

  static func expand(
    _ text: String,
    baseDirectory: URL?,
    includedPaths: inout Set<String>
  ) throws -> String {
    var output: [String] = []

    for rawLine in text.components(separatedBy: .newlines) {
      let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("#!include") {
        let reference = trimmed.dropFirst("#!include".count).trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else { continue }

        let normalized = normalize(reference: String(reference), baseDirectory: baseDirectory)
        if includedPaths.contains(normalized) {
          throw ProfileIncludeError.circularInclude(normalized)
        }

        includedPaths.insert(normalized)
        let includedText = try loadInclude(reference: String(reference), baseDirectory: baseDirectory)
        let expanded = try expand(
          includedText,
          baseDirectory: directory(for: String(reference), baseDirectory: baseDirectory),
          includedPaths: &includedPaths
        )
        includedPaths.remove(normalized)
        output.append(contentsOf: expanded.components(separatedBy: .newlines))
      } else {
        output.append(rawLine)
      }
    }

    return output.joined(separator: "\n")
  }

  private static func loadInclude(reference: String, baseDirectory: URL?) throws -> String {
    if reference.hasPrefix("http://") || reference.hasPrefix("https://") {
      guard let url = URL(string: reference) else {
        throw ProfileIncludeError.remoteIncludeFailed(reference)
      }

      let semaphore = DispatchSemaphore(value: 0)
      var result: Result<String, Error> = .failure(ProfileIncludeError.remoteIncludeFailed(reference))

      URLSession.shared.dataTask(with: url) { data, response, error in
        defer { semaphore.signal() }
        if let error {
          result = .failure(error)
          return
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
          result = .failure(ProfileIncludeError.remoteIncludeFailed(reference))
          return
        }
        guard let data, let text = String(data: data, encoding: .utf8) else {
          result = .failure(ProfileIncludeError.remoteIncludeFailed(reference))
          return
        }
        result = .success(text)
      }.resume()

      semaphore.wait()
      return try result.get()
    }

    let fileURL = resolveLocalURL(for: reference, baseDirectory: baseDirectory)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw ProfileIncludeError.includeNotFound(fileURL.path)
    }
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private static func resolveLocalURL(for reference: String, baseDirectory: URL?) -> URL {
    let expanded = NSString(string: reference).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return URL(fileURLWithPath: expanded, isDirectory: false)
    }

    if let baseDirectory {
      return baseDirectory.appendingPathComponent(expanded, isDirectory: false)
    }

    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent(expanded, isDirectory: false)
  }

  private static func directory(for reference: String, baseDirectory: URL?) -> URL? {
    if reference.hasPrefix("http://") || reference.hasPrefix("https://") {
      return baseDirectory
    }
    return resolveLocalURL(for: reference, baseDirectory: baseDirectory).deletingLastPathComponent()
  }

  private static func normalize(reference: String, baseDirectory: URL?) -> String {
    if reference.hasPrefix("http://") || reference.hasPrefix("https://") {
      return reference
    }
    return resolveLocalURL(for: reference, baseDirectory: baseDirectory).standardizedFileURL.path
  }
}
