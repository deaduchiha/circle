import Foundation

public struct PolicyGroupMemberStatus: Equatable, Sendable, Identifiable {
  public var name: String
  public var latencyMilliseconds: Int?
  public var isAvailable: Bool
  public var lastCheckedAt: Date?

  public var id: String { name }

  public init(
    name: String,
    latencyMilliseconds: Int? = nil,
    isAvailable: Bool = true,
    lastCheckedAt: Date? = nil
  ) {
    self.name = name
    self.latencyMilliseconds = latencyMilliseconds
    self.isAvailable = isAvailable
    self.lastCheckedAt = lastCheckedAt
  }
}

public struct PolicyGroupRuntimeState: Equatable, Sendable, Identifiable {
  public var groupName: String
  public var type: PolicyGroupType
  public var activePolicy: String
  public var members: [PolicyGroupMemberStatus]
  public var lastUpdatedAt: Date?

  public var id: String { groupName }

  public init(
    groupName: String,
    type: PolicyGroupType,
    activePolicy: String,
    members: [PolicyGroupMemberStatus],
    lastUpdatedAt: Date? = nil
  ) {
    self.groupName = groupName
    self.type = type
    self.activePolicy = activePolicy
    self.members = members
    self.lastUpdatedAt = lastUpdatedAt
  }
}

public final class PolicyGroupManager: @unchecked Sendable {
  private let lock = NSLock()
  private var manualSelections: [String: String] = [:]
  private var autoSelections: [String: String] = [:]
  private var loadBalanceIndexes: [String: Int] = [:]
  private var unavailableUntil: [String: Date] = [:]
  private var memberStatuses: [String: [String: PolicyGroupMemberStatus]] = [:]
  private var urlTestInitialized: Set<String> = []

  public init() {}

  public func sync(from profile: Profile) {
    lock.lock()
    defer { lock.unlock() }

    for group in profile.proxyGroups {
      switch group.type {
      case .select:
        if manualSelections[group.name] == nil {
          manualSelections[group.name] = group.selectedPolicy ?? group.policies.first
        }
      case .urlTest:
        if autoSelections[group.name] == nil {
          autoSelections[group.name] = group.selectedPolicy ?? group.policies.first
        }
        urlTestInitialized.remove(group.name)
      case .fallback, .loadBalance:
        break
      }

      if memberStatuses[group.name] == nil {
        memberStatuses[group.name] = Dictionary(
          uniqueKeysWithValues: group.policies.map {
            ($0, PolicyGroupMemberStatus(name: $0))
          }
        )
      } else {
        var statuses = memberStatuses[group.name] ?? [:]
        for policy in group.policies where statuses[policy] == nil {
          statuses[policy] = PolicyGroupMemberStatus(name: policy)
        }
        memberStatuses[group.name] = statuses
      }
    }
  }

  public func selectMember(for group: PolicyGroup, profile: Profile) -> String {
    lock.lock()
    defer { lock.unlock() }

    let policies = group.policies
    guard !policies.isEmpty else { return "DIRECT" }

    switch group.type {
    case .select:
      return manualSelections[group.name] ?? group.selectedPolicy ?? policies[0]
    case .urlTest:
      return autoSelections[group.name] ?? group.selectedPolicy ?? policies[0]
    case .fallback:
      return policies.first { isAvailableLocked($0) } ?? policies[0]
    case .loadBalance:
      let available = policies.filter { isAvailableLocked($0) }
      let pool = available.isEmpty ? policies : available
      let index = loadBalanceIndexes[group.name, default: 0]
      let selected = pool[index % pool.count]
      loadBalanceIndexes[group.name] = index + 1
      return selected
    }
  }

  public func setManualSelection(groupName: String, policy: String) {
    lock.lock()
    manualSelections[groupName] = policy
    lock.unlock()
  }

  public func manualSelection(for groupName: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return manualSelections[groupName]
  }

  public func markUnavailable(_ policyName: String) {
    lock.lock()
    unavailableUntil[policyName] = Date().addingTimeInterval(PolicyGroupDefaults.unavailableTTL)
    lock.unlock()
  }

  public func markAvailable(_ policyName: String) {
    lock.lock()
    unavailableUntil.removeValue(forKey: policyName)
    lock.unlock()
  }

  public func updateLatencyResults(
    for group: PolicyGroup,
    results: [String: Int?],
    checkedAt: Date = Date()
  ) {
    lock.lock()
    defer { lock.unlock() }

    var statuses = memberStatuses[group.name] ?? [:]
    for (policy, latency) in results {
      statuses[policy] = PolicyGroupMemberStatus(
        name: policy,
        latencyMilliseconds: latency,
        isAvailable: latency != nil && isAvailableLocked(policy),
        lastCheckedAt: checkedAt
      )
    }
    memberStatuses[group.name] = statuses

    guard group.type == .urlTest else { return }
    applyURLTestSelectionLocked(for: group, results: results)
  }

  public func runtimeStates(for profile: Profile, now: Date = Date()) -> [PolicyGroupRuntimeState] {
    lock.lock()
    defer { lock.unlock() }

    return profile.proxyGroups.map { group in
      let statuses = group.policies.map { policy in
        var status = memberStatuses[group.name]?[policy] ?? PolicyGroupMemberStatus(name: policy)
        status.isAvailable = isAvailableLocked(policy, now: now)
        return status
      }

      return PolicyGroupRuntimeState(
        groupName: group.name,
        type: group.type,
        activePolicy: activePolicyLocked(for: group),
        members: statuses,
        lastUpdatedAt: statuses.compactMap(\.lastCheckedAt).max()
      )
    }
  }

  private func activePolicyLocked(for group: PolicyGroup) -> String {
    switch group.type {
    case .select:
      return manualSelections[group.name] ?? group.selectedPolicy ?? group.policies.first ?? "DIRECT"
    case .urlTest:
      return autoSelections[group.name] ?? group.selectedPolicy ?? group.policies.first ?? "DIRECT"
    case .fallback:
      return group.policies.first { isAvailableLocked($0) } ?? group.policies.first ?? "DIRECT"
    case .loadBalance:
      return group.policies.first ?? "DIRECT"
    }
  }

  private func applyURLTestSelectionLocked(for group: PolicyGroup, results: [String: Int?]) {
    let tolerance = group.effectiveTolerance
    let ranked = results.compactMap { policy, latency -> (String, Int)? in
      guard let latency else { return nil }
      return (policy, latency)
    }.sorted { $0.1 < $1.1 }

    guard let best = ranked.first else { return }

    if !urlTestInitialized.contains(group.name) {
      autoSelections[group.name] = best.0
      urlTestInitialized.insert(group.name)
      return
    }

    let current = autoSelections[group.name]
    if let current, let currentLatency = results[current] ?? nil {
      if best.0 != current, best.1 + tolerance < currentLatency {
        autoSelections[group.name] = best.0
      }
    } else {
      autoSelections[group.name] = best.0
    }
  }

  private func isAvailableLocked(_ policyName: String, now: Date = Date()) -> Bool {
    guard let until = unavailableUntil[policyName] else { return true }
    if now >= until {
      unavailableUntil.removeValue(forKey: policyName)
      return true
    }
    return false
  }
}
