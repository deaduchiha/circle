import Foundation

public enum SystemProxyError: Error, LocalizedError {
  case commandFailed(String, Int32)
  case noNetworkService

  public var errorDescription: String? {
    switch self {
    case .commandFailed(let command, let code):
      "Command failed (\(code)): \(command)"
    case .noNetworkService:
      "No active network service found for system proxy configuration."
    }
  }
}

public enum SystemProxyManager {
  private static let networkSetupPath = "/usr/sbin/networksetup"

  public static func enable(host: String = "127.0.0.1", port: Int) throws {
    let service = try primaryNetworkService()
    try runNetworkSetup("-setwebproxy", service, host, "\(port)")
    try runNetworkSetup("-setsecurewebproxy", service, host, "\(port)")
    try runNetworkSetup("-setwebproxystate", service, "on")
    try runNetworkSetup("-setsecurewebproxystate", service, "on")
  }

  public static func disable() throws {
    let service = try primaryNetworkService()
    try runNetworkSetup("-setwebproxystate", service, "off")
    try runNetworkSetup("-setsecurewebproxystate", service, "off")
  }

  public static func isEnabled(host: String = "127.0.0.1", port: Int) -> Bool {
    guard let service = try? primaryNetworkService(),
      let output = try? runNetworkSetupOutput(["-getwebproxy", service])
    else {
      return false
    }

    return output.contains("Enabled: Yes")
      && output.contains("Server: \(host)")
      && output.contains("Port: \(port)")
  }

  private static func primaryNetworkService() throws -> String {
    let output = try runNetworkSetupOutput(["-listallnetworkservices"])
    let services =
      output
      .components(separatedBy: .newlines)
      .dropFirst()
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.hasPrefix("An asterisk") }

    guard let service = services.first else {
      throw SystemProxyError.noNetworkService
    }
    return service
  }

  @discardableResult
  private static func runNetworkSetup(_ arguments: String...) throws -> String {
    try runNetworkSetupOutput(Array(arguments))
  }

  private static func runNetworkSetupOutput(_ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: networkSetupPath)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
      throw SystemProxyError.commandFailed(
        arguments.joined(separator: " "), process.terminationStatus)
    }

    return output
  }
}
