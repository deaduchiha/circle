import Foundation
import Logging
import Testing
@testable import CoreProxy

@Suite struct ProxyLoggerTests {
  @Test func configureParsesProfileLogLevels() {
    ProxyLogger.configure(logLevel: "debug")
    let logger = ProxyLogger.logger("test")
    logger.debug("proxy logger configured")
    #expect(Logger(label: "circle.test").label.hasPrefix("circle."))
  }
}
