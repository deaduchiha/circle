@testable import CoreProxy
import XCTest

final class DNSWireCodecTests: XCTestCase {
  func testEncodesAndDecodesARecord() throws {
    let query = try DNSWireCodec.encodeQuery(hostname: "example.com", type: .a)
    XCTAssertFalse(query.isEmpty)
  }
}

final class DNSCacheTests: XCTestCase {
  func testStoresAndEvictsLRU() {
    let cache = DNSCache()
    let record = DNSRecord(type: .a, value: "1.2.3.4", ttl: 60)
    cache.store(hostname: "example.com", type: .a, records: [record])

    XCTAssertEqual(cache.lookup(hostname: "example.com", type: .a)?.first?.value, "1.2.3.4")
    XCTAssertEqual(cache.count, 1)

    cache.flush()
    XCTAssertNil(cache.lookup(hostname: "example.com", type: .a))
  }
}

final class DNSResolverEngineTests: XCTestCase {
  func testResolvesUsingHostsMapping() async throws {
    let engine = DNSResolverEngine(
      config: DNSConfig(servers: []),
      hosts: ["local.test": "127.0.0.1"]
    )

    let result = try await engine.resolve(hostname: "local.test", type: .a)
    XCTAssertEqual(result.source, "hosts")
    XCTAssertEqual(result.records.first?.value, "127.0.0.1")
  }
}
