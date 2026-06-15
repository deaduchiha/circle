import XCTest
@testable import CoreProxy

final class DashboardTests: XCTestCase {
  func testDashboardServerMessageRoundTrip() throws {
    let request = TrafficRequest(
      method: "GET",
      host: "example.com",
      path: "/",
      statusCode: 200,
      bytesIn: 10,
      bytesOut: 20,
      policy: "DIRECT",
      detail: TrafficRequestDetail(
        requestHeaders: ["Host": "example.com"],
        responseHeaders: ["Content-Type": "text/html"]
      )
    )

    let messages: [DashboardServerMessage] = [
      .snapshot(DashboardSnapshot(requests: [request], state: .running, bandwidth: [])),
      .request(request),
      .state(.running),
      .bandwidth([BandwidthSample(bytesInPerSecond: 100, bytesOutPerSecond: 50)]),
      .cleared,
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for message in messages {
      let data = try encoder.encode(message)
      _ = try decoder.decode(DashboardServerMessage.self, from: data)
    }
  }

  func testBandwidthMonitorTicks() {
    let monitor = BandwidthMonitor()
    monitor.record(bytesIn: 100, bytesOut: 50)
    let sample = monitor.tick()
    XCTAssertEqual(sample.bytesInPerSecond, 100)
    XCTAssertEqual(sample.bytesOutPerSecond, 50)

    let idle = monitor.tick()
    XCTAssertEqual(idle.bytesInPerSecond, 0)
    XCTAssertEqual(idle.bytesOutPerSecond, 0)
  }
}
