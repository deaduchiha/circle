import Foundation

public enum DashboardMessageType: String, Codable, Sendable {
  case snapshot
  case request
  case state
  case bandwidth
  case cleared
}

public struct DashboardSnapshot: Codable, Sendable {
  public var requests: [TrafficRequest]
  public var state: ProxyRunState
  public var bandwidth: [BandwidthSample]

  public init(requests: [TrafficRequest], state: ProxyRunState, bandwidth: [BandwidthSample]) {
    self.requests = requests
    self.state = state
    self.bandwidth = bandwidth
  }
}

public enum DashboardServerMessage: Codable, Sendable {
  case snapshot(DashboardSnapshot)
  case request(TrafficRequest)
  case state(ProxyRunState)
  case bandwidth([BandwidthSample])
  case cleared

  private enum CodingKeys: String, CodingKey {
    case type
    case payload
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .snapshot(let value):
      try container.encode(DashboardMessageType.snapshot, forKey: .type)
      try container.encode(value, forKey: .payload)
    case .request(let value):
      try container.encode(DashboardMessageType.request, forKey: .type)
      try container.encode(value, forKey: .payload)
    case .state(let value):
      try container.encode(DashboardMessageType.state, forKey: .type)
      try container.encode(value, forKey: .payload)
    case .bandwidth(let value):
      try container.encode(DashboardMessageType.bandwidth, forKey: .type)
      try container.encode(value, forKey: .payload)
    case .cleared:
      try container.encode(DashboardMessageType.cleared, forKey: .type)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(DashboardMessageType.self, forKey: .type)
    switch type {
    case .snapshot:
      self = .snapshot(try container.decode(DashboardSnapshot.self, forKey: .payload))
    case .request:
      self = .request(try container.decode(TrafficRequest.self, forKey: .payload))
    case .state:
      self = .state(try container.decode(ProxyRunState.self, forKey: .payload))
    case .bandwidth:
      self = .bandwidth(try container.decode([BandwidthSample].self, forKey: .payload))
    case .cleared:
      self = .cleared
    }
  }
}

public enum DashboardClientMessage: Codable, Sendable {
  case subscribe
  case clear

  private enum CodingKeys: String, CodingKey {
    case type
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "clear":
      self = .clear
    default:
      self = .subscribe
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .subscribe:
      try container.encode("subscribe", forKey: .type)
    case .clear:
      try container.encode("clear", forKey: .type)
    }
  }
}
