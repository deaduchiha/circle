import Foundation

enum DoHDNSClient {
  static func query(
    endpoint: String,
    hostname: String,
    type: DNSRecordType,
    wireQuestion: Data,
    timeout: TimeInterval
  ) async throws -> [DNSRecord] {
    if let records = try? await queryJSON(endpoint: endpoint, hostname: hostname, type: type, timeout: timeout),
      !records.isEmpty
    {
      return records
    }
    return try await queryWire(endpoint: endpoint, wireQuestion: wireQuestion, type: type, timeout: timeout)
  }

  private static func queryJSON(
    endpoint: String,
    hostname: String,
    type: DNSRecordType,
    timeout: TimeInterval
  ) async throws -> [DNSRecord] {
    var components = URLComponents(string: endpoint) ?? URLComponents()
    if components.scheme == nil {
      components = URLComponents(string: "https://\(endpoint)") ?? components
    }
    components.queryItems = [
      URLQueryItem(name: "name", value: hostname),
      URLQueryItem(name: "type", value: type.name),
    ]
    guard let url = components.url else { throw DNSResolverError.invalidResponse }

    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw DNSResolverError.invalidResponse
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let answers = json["Answer"] as? [[String: Any]]
    else {
      return []
    }

    return answers.compactMap { answer in
      guard let answerType = answer["type"] as? Int,
        let recordType = DNSRecordType(rawValue: UInt16(answerType)),
        recordType == type,
        let data = answer["data"] as? String
      else { return nil }
      let ttl = answer["TTL"] as? Int ?? 60
      return DNSRecord(type: recordType, value: data, ttl: ttl)
    }
  }

  private static func queryWire(
    endpoint: String,
    wireQuestion: Data,
    type: DNSRecordType,
    timeout: TimeInterval
  ) async throws -> [DNSRecord] {
    let urlString = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
    guard let url = URL(string: urlString) else { throw DNSResolverError.invalidResponse }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.httpBody = wireQuestion
    request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
    request.setValue("application/dns-message", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw DNSResolverError.invalidResponse
    }

    return try DNSWireCodec.decodeResponse(data, expectedType: type)
  }
}
