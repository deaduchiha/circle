import Foundation

final class DashboardSnapshotCache: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshot = DashboardSnapshot(requests: [], state: .stopped, bandwidth: [])

  func update(_ snapshot: DashboardSnapshot) {
    lock.lock()
    self.snapshot = snapshot
    lock.unlock()
  }

  func current() -> DashboardSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshot
  }
}
