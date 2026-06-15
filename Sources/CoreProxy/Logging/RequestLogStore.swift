import Foundation
import GRDB

public enum RequestLogStoreError: Error, LocalizedError {
  case encodingFailed
  case decodingFailed

  public var errorDescription: String? {
    switch self {
    case .encodingFailed:
      "Failed to encode request detail for storage."
    case .decodingFailed:
      "Failed to decode request detail from storage."
    }
  }
}

public final class RequestLogStore: @unchecked Sendable {
  public static let maxEntries = 10_000

  private let dbQueue: DatabaseQueue
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(databaseURL: URL? = nil) throws {
    let url = databaseURL ?? Self.defaultDatabaseURL()
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    dbQueue = try DatabaseQueue(path: url.path)
    try migrator.migrate(dbQueue)
  }

  public static func defaultDatabaseURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("circle/request-log.sqlite", isDirectory: false)
  }

  public func insert(_ request: TrafficRequest) throws {
    let row = try makeRow(from: request)
    try dbQueue.write { db in
      try row.insert(db, onConflict: .replace)
      try Self.trim(db: db, maxEntries: Self.maxEntries)
    }
  }

  public func fetchRecent(limit: Int = maxEntries) throws -> [TrafficRequest] {
    try dbQueue.read { db in
      let rows = try StoredTrafficRequest
        .order(StoredTrafficRequest.Columns.timestamp.desc)
        .limit(limit)
        .fetchAll(db)
      return try rows.map { try makeRequest(from: $0) }
    }
  }

  public func clear() throws {
    _ = try dbQueue.write { db in
      try StoredTrafficRequest.deleteAll(db)
    }
  }

  public func count() throws -> Int {
    try dbQueue.read { db in
      try StoredTrafficRequest.fetchCount(db)
    }
  }

  // MARK: - Private

  private var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("createTrafficRequests") { db in
      try db.create(table: StoredTrafficRequest.databaseTableName) { table in
        table.column("id", .text).primaryKey()
        table.column("timestamp", .datetime).notNull().indexed()
        table.column("method", .text).notNull()
        table.column("host", .text).notNull().indexed()
        table.column("path", .text).notNull()
        table.column("statusCode", .integer)
        table.column("bytesIn", .integer).notNull()
        table.column("bytesOut", .integer).notNull()
        table.column("policy", .text).notNull()
        table.column("latencyMilliseconds", .integer)
        table.column("matchedRule", .text)
        table.column("detailJSON", .text)
      }
    }
    return migrator
  }

  private func makeRow(from request: TrafficRequest) throws -> StoredTrafficRequest {
    let detailJSON: String?
    if let detail = request.detail {
      guard let data = try? encoder.encode(detail),
            let json = String(data: data, encoding: .utf8)
      else {
        throw RequestLogStoreError.encodingFailed
      }
      detailJSON = json
    } else {
      detailJSON = nil
    }

    return StoredTrafficRequest(
      id: request.id.uuidString,
      timestamp: request.timestamp,
      method: request.method,
      host: request.host,
      path: request.path,
      statusCode: request.statusCode,
      bytesIn: request.bytesIn,
      bytesOut: request.bytesOut,
      policy: request.policy,
      latencyMilliseconds: request.latencyMilliseconds,
      matchedRule: request.matchedRule,
      detailJSON: detailJSON
    )
  }

  private func makeRequest(from row: StoredTrafficRequest) throws -> TrafficRequest {
    let detail: TrafficRequestDetail?
    if let detailJSON = row.detailJSON, let data = detailJSON.data(using: .utf8) {
      guard let decoded = try? decoder.decode(TrafficRequestDetail.self, from: data) else {
        throw RequestLogStoreError.decodingFailed
      }
      detail = decoded
    } else {
      detail = nil
    }

    guard let id = UUID(uuidString: row.id) else {
      throw RequestLogStoreError.decodingFailed
    }

    return TrafficRequest(
      id: id,
      timestamp: row.timestamp,
      method: row.method,
      host: row.host,
      path: row.path,
      statusCode: row.statusCode,
      bytesIn: row.bytesIn,
      bytesOut: row.bytesOut,
      policy: row.policy,
      latencyMilliseconds: row.latencyMilliseconds,
      matchedRule: row.matchedRule,
      detail: detail
    )
  }

  private static func trim(db: Database, maxEntries: Int) throws {
    try db.execute(
      sql: """
        DELETE FROM traffic_requests
        WHERE id NOT IN (
          SELECT id FROM traffic_requests
          ORDER BY timestamp DESC
          LIMIT ?
        )
        """,
      arguments: [maxEntries]
    )
  }
}

private struct StoredTrafficRequest: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "traffic_requests"

  var id: String
  var timestamp: Date
  var method: String
  var host: String
  var path: String
  var statusCode: Int?
  var bytesIn: Int
  var bytesOut: Int
  var policy: String
  var latencyMilliseconds: Int?
  var matchedRule: String?
  var detailJSON: String?

  enum Columns {
    static let id = Column("id")
    static let timestamp = Column("timestamp")
    static let method = Column("method")
    static let host = Column("host")
    static let path = Column("path")
    static let statusCode = Column("statusCode")
    static let bytesIn = Column("bytesIn")
    static let bytesOut = Column("bytesOut")
    static let policy = Column("policy")
    static let latencyMilliseconds = Column("latencyMilliseconds")
    static let matchedRule = Column("matchedRule")
    static let detailJSON = Column("detailJSON")
  }
}
