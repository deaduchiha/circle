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
  @Published public private(set) var geoIPStatus: GeoIPDatabaseStatus = GeoIPDatabaseStatus(isLoaded: false)
  @Published public private(set) var policyGroupStates: [PolicyGroupRuntimeState] = []
  @Published public private(set) var profileDocuments: [ProfileDocument] = []
  @Published public private(set) var activeProfileID: UUID?
  @Published public var profileEditorText: String = ""
  @Published public var iCloudSyncEnabled: Bool = ProfileCloudSync.isFeatureEnabled

  private let parser = ProfileParser()
  private let profileStore: ProfileStore
  private let certificateManager = CertificateManager.shared
  private let bandwidthMonitor = BandwidthMonitor()
  private let requestLogStore: RequestLogStore
  private let geoIPService: GeoIPService
  private let policyGroupManager: PolicyGroupManager
  private let log = ProxyLogger.logger("controller")
  private var proxyServer: ProxyServer?
  private var dashboardServer: DashboardServer?
  private var systemProxyEnabled = false
  private var bandwidthTimer: Timer?
  private var policyGroupTimer: Timer?
  private var policyGroupLastTestRun: [String: Date] = [:]
  private let dashboardSnapshotCache = DashboardSnapshotCache()
  private var ruleEngine: RuleEngine

  public init(
    profile: Profile? = nil,
    requestLogStore: RequestLogStore? = nil,
    geoIPService: GeoIPService? = nil,
    policyGroupManager: PolicyGroupManager? = nil,
    profileStore: ProfileStore? = nil
  ) {
    let store = try! (profileStore ?? ProfileStore())
    self.profileStore = store
    self.profileDocuments = store.profiles
    self.activeProfileID = store.activeProfileID
    self.iCloudSyncEnabled = ProfileCloudSync.isFeatureEnabled

    let resolvedProfile: Profile
    let resolvedEditorText: String
    if let profile {
      resolvedProfile = profile
      resolvedEditorText = ProfileParser().serialize(profile)
    } else if let activeID = store.activeProfileID,
      let parsed = try? store.parseProfile(id: activeID),
      let source = try? store.loadSource(id: activeID)
    {
      resolvedProfile = parsed
      resolvedEditorText = source
    } else {
      resolvedProfile = ProfileLoader.loadDefault()
      resolvedEditorText = ProfileParser().serialize(resolvedProfile)
    }

    self.profile = resolvedProfile
    self.profileEditorText = resolvedEditorText

    self.geoIPService = geoIPService ?? GeoIPService()
    self.policyGroupManager = policyGroupManager ?? PolicyGroupManager()

    if let requestLogStore {
      self.requestLogStore = requestLogStore
    } else {
      let url = RequestLogStore.defaultDatabaseURL()
      self.requestLogStore = try! RequestLogStore(databaseURL: url)
    }

    self.ruleEngine = RuleEngine(
      rules: resolvedProfile.rules,
      configuration: RuleEngineConfiguration(geoIPLookup: self.geoIPService.lookup)
    )
    ProxyLogger.configure(logLevel: resolvedProfile.general.logLevel)

    if let stored = try? self.requestLogStore.fetchRecent() {
      requests = stored
    }

    self.policyGroupManager.sync(from: self.profile)
    syncPolicyGroupStates()
    refreshMITMStatus()
    refreshGeoIPStatus()
    scheduleGeoIPRefreshIfNeeded()
    log.info("ProxyController initialized", metadata: ["requests": "\(requests.count)"])
  }

  public func loadProfile(text: String) throws {
    if let activeProfileID {
      profileEditorText = text
      _ = try profileStore.saveSource(id: activeProfileID, text: text)
      profile = try profileStore.parseProfile(id: activeProfileID, sourceText: text)
    } else {
      profile = try profileStore.parseProfileText(text, baseDirectory: nil)
      profileEditorText = text
    }
    applyLoadedProfile()
  }

  public func saveProfileEditor() throws {
    guard let activeProfileID else {
      throw ProfileStoreError.profileNotFound(UUID())
    }
    _ = try profileStore.saveSource(id: activeProfileID, text: profileEditorText)
    profile = try profileStore.parseProfile(id: activeProfileID, sourceText: profileEditorText)
    reloadProfileLibrary()
    applyLoadedProfile()
  }

  public func reloadProfileLibrary() {
    profileDocuments = profileStore.profiles
    activeProfileID = profileStore.activeProfileID
  }

  public func createProfile(name: String) throws {
    let document = try profileStore.createProfile(name: name)
    reloadProfileLibrary()
    try selectProfile(id: document.id)
  }

  public func duplicateProfile(id: UUID) throws {
    let document = try profileStore.duplicateProfile(id: id)
    reloadProfileLibrary()
    try selectProfile(id: document.id)
  }

  public func renameProfile(id: UUID, name: String) throws {
    try profileStore.renameProfile(id: id, name: name)
    reloadProfileLibrary()
  }

  public func deleteProfile(id: UUID) throws {
    try profileStore.deleteProfile(id: id)
    reloadProfileLibrary()
    if activeProfileID == nil, let nextID = profileDocuments.first?.id {
      try selectProfile(id: nextID)
    } else if let activeProfileID {
      profileEditorText = try profileStore.loadSource(id: activeProfileID)
    }
  }

  public func selectProfile(id: UUID) throws {
    try profileStore.setActiveProfile(id: id)
    activeProfileID = id
    profileEditorText = try profileStore.loadSource(id: id)
    profile = try profileStore.parseProfile(id: id)
    reloadProfileLibrary()
    applyLoadedProfile()
  }

  public func importProfileFromURL(_ urlString: String, name: String? = nil) {
    Task {
      do {
        let document = try await profileStore.importFromURL(urlString, name: name)
        await MainActor.run {
          reloadProfileLibrary()
          try? selectProfile(id: document.id)
          lastError = nil
        }
      } catch {
        await MainActor.run {
          lastError = error.localizedDescription
        }
      }
    }
  }

  public func updateProfileModules(_ modules: ProfileModuleSettings) throws {
    guard let activeProfileID else { return }
    try profileStore.updateModules(for: activeProfileID, modules: modules)
    profile = try profileStore.parseProfile(id: activeProfileID, sourceText: profileEditorText, modules: modules)
    reloadProfileLibrary()
    applyLoadedProfile()
  }

  public func setiCloudSyncEnabled(_ enabled: Bool) {
    Task {
      do {
        try ProfileCloudSync.migrateProfiles(toICloud: enabled)
        await MainActor.run {
          iCloudSyncEnabled = enabled
          reloadProfileLibrary()
          if let activeProfileID {
            profileEditorText = (try? profileStore.loadSource(id: activeProfileID)) ?? profileEditorText
          }
        }
      } catch {
        await MainActor.run {
          lastError = error.localizedDescription
        }
      }
    }
  }

  public func exportProfile() -> String {
    profileEditorText.isEmpty ? parser.serialize(profile) : profileEditorText
  }

  private func applyLoadedProfile() {
    rebuildRuleEngine()
    policyGroupManager.sync(from: profile)
    policyGroupLastTestRun.removeAll()
    syncPolicyGroupStates()
    ProxyLogger.configure(logLevel: profile.general.logLevel)
    requests.removeAll()
    try? requestLogStore.clear()
    broadcastCleared()
    scheduleGeoIPRefreshIfNeeded()
    runPolicyGroupTests(force: true)
    log.info("Profile applied", metadata: ["rules": "\(profile.rules.count)"])
  }

  public func start() {
    guard state != .running && state != .starting else { return }

    lastError = nil
    state = .starting
    broadcastState()
    log.info("Starting proxy", metadata: ["port": "\(profile.general.httpPort)"])

    let profileSnapshot = profile
    let ruleEngineSnapshot = ruleEngine
    let policyGroupManagerSnapshot = policyGroupManager
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
            policyGroupManager: policyGroupManagerSnapshot,
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
          self?.startPolicyGroupTimer()
          self?.runPolicyGroupTests(force: true)
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
        self?.stopPolicyGroupTimer()
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
      engine: ruleEngine,
      groupManager: policyGroupManager
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

  public func syncPolicyGroupStates() {
    policyGroupStates = policyGroupManager.runtimeStates(for: profile)
  }

  public func selectPolicyGroupMember(groupName: String, policy: String) {
    policyGroupManager.setManualSelection(groupName: groupName, policy: policy)
    if let index = profile.proxyGroups.firstIndex(where: { $0.name == groupName }) {
      profile.proxyGroups[index].selectedPolicy = policy
    }
    syncPolicyGroupStates()
  }

  public func policyGroupSelection(for groupName: String) -> String? {
    policyGroupManager.manualSelection(for: groupName)
  }

  public func runPolicyGroupTests(force: Bool = false) {
    Task {
      await refreshPolicyGroups(force: force)
    }
  }

  private func refreshPolicyGroups(force: Bool) async {
    let profileSnapshot = profile
    let now = Date()

    for group in profileSnapshot.proxyGroups where group.type == .urlTest {
      let interval = TimeInterval(group.effectiveTestInterval)
      if !force,
        let lastRun = policyGroupLastTestRun[group.name],
        now.timeIntervalSince(lastRun) < interval
      {
        continue
      }

      let results = await ProxyLatencyTester.measureGroup(group, profile: profileSnapshot)
      policyGroupManager.updateLatencyResults(for: group, results: results, checkedAt: now)
      policyGroupLastTestRun[group.name] = now
    }

    await MainActor.run {
      syncPolicyGroupStates()
    }
  }

  private func startPolicyGroupTimer() {
    stopPolicyGroupTimer()
    policyGroupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.runPolicyGroupTests(force: false)
      }
    }
  }

  private func stopPolicyGroupTimer() {
    policyGroupTimer?.invalidate()
    policyGroupTimer = nil
  }

  public func refreshGeoIPStatus() {
    geoIPStatus = geoIPService.status()
  }

  public func lookupGeoIPCountry(for ip: String) -> String? {
    geoIPService.countryCode(for: ip)
  }

  public func updateGeoIPDatabase() {
    Task {
      await refreshGeoIPDatabase(force: true)
    }
  }

  public func setGeoLite2LicenseKey(_ licenseKey: String?) {
    profile.general.geolite2LicenseKey = licenseKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    scheduleGeoIPRefreshIfNeeded()
  }

  private func rebuildRuleEngine() {
    ruleEngine = RuleEngine(
      rules: profile.rules,
      configuration: RuleEngineConfiguration(geoIPLookup: geoIPService.lookup)
    )
  }

  private func scheduleGeoIPRefreshIfNeeded() {
    Task {
      await refreshGeoIPDatabase(force: false)
    }
  }

  private func refreshGeoIPDatabase(force: Bool) async {
    let licenseKey = GeoIPDatabasePaths.resolveLicenseKey(from: profile.general)
    let databaseURL = GeoIPDatabasePaths.databaseURL()
    let shouldDownload =
      force
      || (licenseKey != nil
        && (!FileManager.default.fileExists(atPath: databaseURL.path)
          || GeoIPDatabaseUpdater.isStale(at: databaseURL)))

    if shouldDownload, let licenseKey {
      do {
        let updatedURL = try await GeoIPDatabaseUpdater.downloadAndInstall(licenseKey: licenseKey)
        try geoIPService.load(from: updatedURL)
        await MainActor.run {
          rebuildRuleEngine()
          refreshGeoIPStatus()
          lastError = nil
          log.info("GeoIP database updated", metadata: ["path": "\(updatedURL.path)"])
        }
      } catch {
        await MainActor.run {
          refreshGeoIPStatus()
          if force {
            lastError = error.localizedDescription
          }
          log.warning(
            "GeoIP database update failed",
            metadata: ["error": "\(error.localizedDescription)"]
          )
        }
      }
      return
    }

    do {
      let installedURL = try GeoIPDatabaseUpdater.ensureInstalled()
      try geoIPService.load(from: installedURL)
      await MainActor.run {
        rebuildRuleEngine()
        refreshGeoIPStatus()
      }
    } catch {
      await MainActor.run {
        refreshGeoIPStatus()
        if force {
          lastError = error.localizedDescription
        }
      }
    }
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
