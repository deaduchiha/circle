import Foundation
import Logging

public enum ProxyLogger {
  private static let lock = NSLock()
  private nonisolated(unsafe) static var bootstrapped = false

  public static func configure(logLevel: String) {
    lock.lock()
    defer { lock.unlock() }
    guard !bootstrapped else { return }

    let level = parseLevel(logLevel)
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardOutput(label: label)
      handler.logLevel = level
      return handler
    }
    bootstrapped = true
  }

  public static func logger(_ category: String) -> Logger {
    Logger(label: "circle.\(category)")
  }

  private static func parseLevel(_ value: String) -> Logger.Level {
    switch value.lowercased() {
    case "trace", "verbose":
      return .trace
    case "debug":
      return .debug
    case "warning", "warn", "notify":
      return .warning
    case "error":
      return .error
    case "critical":
      return .critical
    default:
      return .info
    }
  }
}
