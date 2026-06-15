import Foundation
import Testing
@testable import CoreProxy

@Suite struct RequestLogStoreTests {
  private func makeStore() throws -> RequestLogStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("circle-test-\(UUID().uuidString).sqlite")
    return try RequestLogStore(databaseURL: url)
  }

  private func sampleRequest(
    host: String = "example.com",
    detail: TrafficRequestDetail? = nil
  ) -> TrafficRequest {
    TrafficRequest(
      method: "GET",
      host: host,
      path: "/",
      statusCode: 200,
      bytesIn: 128,
      bytesOut: 64,
      policy: "DIRECT",
      latencyMilliseconds: 12,
      matchedRule: "DOMAIN-SUFFIX,example.com,DIRECT",
      detail: detail
    )
  }

  @Test func insertAndFetchRecent() throws {
    let store = try makeStore()
    let request = sampleRequest()

    try store.insert(request)
    let fetched = try store.fetchRecent()

    #expect(fetched.count == 1)
    #expect(fetched[0].id == request.id)
    #expect(fetched[0].host == "example.com")
    #expect(fetched[0].policy == "DIRECT")
  }

  @Test func persistsDetailJSON() throws {
    let store = try makeStore()
    let detail = TrafficRequestDetail(
      requestHeaders: ["User-Agent": "circle-test"],
      responseHeaders: ["Content-Type": "text/plain"],
      requestBody: "hello",
      responseBody: "world",
      timing: RequestTiming(totalMilliseconds: 42)
    )
    let request = sampleRequest(detail: detail)

    try store.insert(request)
    let fetched = try store.fetchRecent()

    #expect(fetched[0].detail == detail)
  }

  @Test func clearRemovesAllEntries() throws {
    let store = try makeStore()
    try store.insert(sampleRequest())
    try store.insert(sampleRequest(host: "other.test"))

    try store.clear()

    #expect(try store.count() == 0)
    #expect(try store.fetchRecent().isEmpty)
  }

  @Test func rotationKeepsLastTenThousandRequests() throws {
    let store = try makeStore()

    for index in 0..<10_050 {
      try store.insert(
        TrafficRequest(
          timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
          method: "GET",
          host: "host-\(index).test",
          path: "/",
          policy: "DIRECT"
        )
      )
    }

    #expect(try store.count() == RequestLogStore.maxEntries)

    let fetched = try store.fetchRecent()
    #expect(fetched.count == RequestLogStore.maxEntries)
    #expect(fetched.first?.host == "host-10049.test")
    #expect(fetched.last?.host == "host-50.test")
  }
}
