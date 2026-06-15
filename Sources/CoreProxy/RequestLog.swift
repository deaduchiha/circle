import Foundation
import Logging

public enum ProxyRunState: String, Codable, Sendable {
  case stopped
  case starting
  case running
  case failed
}

public struct TrafficRequest: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var timestamp: Date
  public var method: String
  public var host: String
  public var path: String
  public var statusCode: Int?
  public var bytesIn: Int
  public var bytesOut: Int
  public var policy: String
  public var latencyMilliseconds: Int?
  public var matchedRule: String?
  public var detail: TrafficRequestDetail?

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    method: String,
    host: String,
    path: String,
    statusCode: Int? = nil,
    bytesIn: Int = 0,
    bytesOut: Int = 0,
    policy: String,
    latencyMilliseconds: Int? = nil,
    matchedRule: String? = nil,
    detail: TrafficRequestDetail? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.method = method
    self.host = host
    self.path = path
    self.statusCode = statusCode
    self.bytesIn = bytesIn
    self.bytesOut = bytesOut
    self.policy = policy
    self.latencyMilliseconds = latencyMilliseconds
    self.matchedRule = matchedRule
    self.detail = detail
  }
}

@MainActor
public final class ProxyController: ObservableObject {
  @Published public private(set) var state: ProxyRunState = .stopped
  @Published public private(set) var requests: [TrafficRequest] = []
  @Published public private(set) var bandwidthSamples: [BandwidthSample] = []
  @Published public var profile: Profile
  @Published public private(set) var lastError: String?
  @Published public private(set) var mitmCertificateStatus: MITMCertificateStatus?

  private let parser = ProfileParser()
  private let certificateManager = CertificateManager.shared
  private let bandwidthMonitor = BandwidthMonitor()
  private let requestLogStore: RequestLogStore
  private let log = ProxyLogger.logger("controller")
  private var proxyServer: ProxyServer?
  private var dashboardServer: DashboardServer?
  private var systemProxyEnabled = false
  private var bandwidthTimer: Timer?
  private let dashboardSnapshotCache = DashboardSnapshotCache()
  private var ruleEngine: RuleEngine

  public init(profile: Profile = ProfileLoader.loadDefault(), requestLogStore: RequestLogStore? = nil) {
    self.profile = profile
    self.ruleEngine = RuleEngine(rules: profile.rules)
    ProxyLogger.configure(logLevel: profile.general.logLevel)

    if let requestLogStore {
      self.requestLogStore = requestLogStore
    } else {
      let url = RequestLogStore.defaultDatabaseURL()
      self.requestLogStore = try! RequestLogStore(databaseURL: url)
    }

    if let stored = try? self.requestLogStore.fetchRecent() {
      requests = stored
    }

    refreshMITMStatus()
    log.info("ProxyController initialized", metadata: ["requests": "\(requests.count)"])
  }

  public func loadProfile(text: String) throws {
    profile = try parser.parse(text)
    ruleEngine = RuleEngine(rules: profile.rules)
    requests.removeAll()
    try requestLogStore.clear()
    broadcastCleared()
    log.info("Profile loaded", metadata: ["rules": "\(profile.rules.count)"])
  }

  public func exportProfile() -> String {
    parser.serialize(profile)
  }

  public func start() {
    guard state != .running && state != .starting else { return }

    lastError = nil
    state = .starting
    broadcastState()
    log.info("Starting proxy", metadata: ["port": "\(profile.general.httpPort)"])

    let profileSnapshot = profile
    let ruleEngineSnapshot = ruleEngine
    let port = profile.general.httpPort
    let dashboardPort = profile.general.dashboardPort

    Task.detached { [weak self] in
      do {
        let dashboard = await MainActor.run {
          self?.makeDashboardServer(port: dashboardPort)
        }
        if let dashboard {
          try dashboard.start()
          await MainActor.run {
            self?.dashboardServer = dashboard
          }
        }

        let server = ProxyServer(
          configuration: ProxyServerConfiguration(
            port: port,
            profile: profileSnapshot,
            ruleEngine: ruleEngineSnapshot,
            onRequest: { request in
              Task { @MainActor in
                self?.record(request)
              }
            }
          )
        )

        try server.start()

        await MainActor.run {
          self?.proxyServer = server
        }

        try SystemProxyManager.enable(port: port)

        await MainActor.run {
          self?.systemProxyEnabled = true
          self?.state = .running
          self?.syncDashboardSnapshot()
          self?.startBandwidthTimer()
          self?.broadcastState()
          self?.log.info("Proxy running")
        }
      } catch {
        await MainActor.run {
          self?.lastError = error.localizedDescription
          self?.state = .failed
          self?.broadcastState()
          self?.log.error("Proxy failed to start", metadata: ["error": "\(error.localizedDescription)"])
        }
      }
    }
  }

  public func stop() {
    guard state == .running || state == .starting || state == .failed else { return }
    log.info("Stopping proxy")

    Task.detached { [weak self] in
      if let server = await MainActor.run(body: { self?.proxyServer }) {
        try? server.stop()
      }

      if let dashboard = await MainActor.run(body: { self?.dashboardServer }) {
        try? dashboard.stop()
      }

      if await MainActor.run(body: { self?.systemProxyEnabled }) == true {
        try? SystemProxyManager.disable()
      }

      await MainActor.run {
        self?.proxyServer = nil
        self?.dashboardServer = nil
        self?.systemProxyEnabled = false
        self?.state = .stopped
        self?.stopBandwidthTimer()
        self?.broadcastState()
        self?.log.info("Proxy stopped")
      }
    }
  }

  public func evaluate(host: String, path: String = "/") -> RuleMatch? {
    ruleEngine.evaluate(
      RuleEvaluationContext(host: host, url: URL(string: "https://\(host)\(path)"))
    )
  }

  public func testRule(host: String, path: String = "/") -> RuleTestResult {
    let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
    let evaluation = PolicyRouter.evaluate(
      host: host,
      path: normalizedPath,
      profile: profile,
      engine: ruleEngine
    )
    return RuleTestResult(
      host: host.lowercased(),
      path: normalizedPath,
      policy: evaluation.match?.policy ?? "DIRECT",
      ruleSummary: evaluation.match.map { RuleFormatter.summary($0.rule) },
      routeDescription: RuleFormatter.routeDescription(evaluation.route)
    )
  }

  public func flushRuleCache() {
    ruleEngine.flushCache()
  }

  public func record(_ request: TrafficRequest) {
    do {
      try requestLogStore.insert(request)
    } catch {
      log.error("Failed to persist request", metadata: ["error": "\(error.localizedDescription)"])
    }

    requests.insert(request, at: 0)
    if requests.count > RequestLogStore.maxEntries {
      requests.removeLast(requests.count - RequestLogStore.maxEntries)
    }
    bandwidthMonitor.record(bytesIn: request.bytesIn, bytesOut: request.bytesOut)
    syncDashboardSnapshot()
    dashboardServer?.broadcast(.request(request))
    log.debug(
      "Request recorded",
      metadata: [
        "method": "\(request.method)",
        "host": "\(request.host)",
        "policy": "\(request.policy)",
      ]
    )
  }

  public func clearLog() {
    do {
      try requestLogStore.clear()
    } catch {
      log.error("Failed to clear request log", metadata: ["error": "\(error.localizedDescription)"])
    }
    requests.removeAll()
    syncDashboardSnapshot()
    broadcastCleared()
    log.info("Request log cleared")
  }

  public func refreshMITMStatus() {
    mitmCertificateStatus = try? certificateManager.certificateStatus()
  }

  public func generateMITMCA() {
    do {
      mitmCertificateStatus = try certificateManager.generateCA()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func installMITMCA() {
    do {
      try certificateManager.installCAInKeychain()
      refreshMITMStatus()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func exportMITMCAPEM() throws -> String {
    try certificateManager.exportCAPEM()
  }

  public func exportMITMCATo(url: URL) {
    do {
      try certificateManager.exportCAPEM(to: url)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func makeDashboardServer(port: Int) -> DashboardServer {
    let cache = dashboardSnapshotCache
    return DashboardServer(
      configuration: DashboardServerConfiguration(
        port: port,
        snapshotProvider: {
          cache.current()
        },
        onClientMessage: { [weak self] message in
          Task { @MainActor in
            switch message {
            case .clear:
              self?.clearLog()
            case .subscribe:
              break
            }
          }
        }
      )
    )
  }

  private func syncDashboardSnapshot() {
    dashboardSnapshotCache.update(
      DashboardSnapshot(
        requests: requests,
        state: state,
        bandwidth: bandwidthSamples
      )
    )
  }

  private func startBandwidthTimer() {
    stopBandwidthTimer()
    bandwidthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        let sample = self.bandwidthMonitor.tick()
        self.bandwidthSamples.append(sample)
        if self.bandwidthSamples.count > 120 {
          self.bandwidthSamples.removeFirst(self.bandwidthSamples.count - 120)
        }
        self.syncDashboardSnapshot()
        self.dashboardServer?.broadcast(.bandwidth([sample]))
      }
    }
  }

  private func stopBandwidthTimer() {
    bandwidthTimer?.invalidate()
    bandwidthTimer = nil
  }

  private func broadcastState() {
    syncDashboardSnapshot()
    dashboardServer?.broadcast(.state(state))
  }

  private func broadcastCleared() {
    dashboardServer?.broadcast(.cleared)
  }
}
