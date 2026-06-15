import Foundation

public struct BandwidthSample: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var timestamp: Date
  public var bytesInPerSecond: Int
  public var bytesOutPerSecond: Int

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    bytesInPerSecond: Int,
    bytesOutPerSecond: Int
  ) {
    self.id = id
    self.timestamp = timestamp
    self.bytesInPerSecond = bytesInPerSecond
    self.bytesOutPerSecond = bytesOutPerSecond
  }
}

public final class BandwidthMonitor: @unchecked Sendable {
  private let lock = NSLock()
  private var currentBytesIn = 0
  private var currentBytesOut = 0
  private var samples: [BandwidthSample] = []
  private let maxSamples = 120

  public init() {}

  public func record(bytesIn: Int, bytesOut: Int) {
    lock.lock()
    currentBytesIn += bytesIn
    currentBytesOut += bytesOut
    lock.unlock()
  }

  @discardableResult
  public func tick() -> BandwidthSample {
    lock.lock()
    let sample = BandwidthSample(
      bytesInPerSecond: currentBytesIn,
      bytesOutPerSecond: currentBytesOut
    )
    currentBytesIn = 0
    currentBytesOut = 0
    samples.append(sample)
    if samples.count > maxSamples {
      samples.removeFirst(samples.count - maxSamples)
    }
    lock.unlock()
    return sample
  }

  public func recentSamples() -> [BandwidthSample] {
    lock.lock()
    defer { lock.unlock() }
    return samples
  }
}
