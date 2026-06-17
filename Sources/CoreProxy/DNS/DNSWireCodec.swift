import Foundation

enum DNSWireCodec {
  static func encodeQuery(hostname: String, type: DNSRecordType) throws -> Data {
    let labels = hostname.split(separator: ".").map(String.init)
    guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else {
      throw DNSResolverError.invalidHostname
    }

    var data = Data()
    data.append(contentsOf: [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    for label in labels {
      data.append(UInt8(label.utf8.count))
      data.append(contentsOf: label.utf8)
    }
    data.append(0)

    data.append(UInt8(type.rawValue >> 8))
    data.append(UInt8(type.rawValue & 0xff))
    data.append(0)
    data.append(1)

    return data
  }

  static func decodeResponse(_ data: Data, expectedType: DNSRecordType) throws -> [DNSRecord] {
    guard data.count >= 12 else { throw DNSResolverError.invalidResponse }

    let questionCount = Int(data[4]) << 8 | Int(data[5])
    let answerCount = Int(data[6]) << 8 | Int(data[7])
    guard answerCount > 0 else { return [] }

    var offset = 12
    offset = try skipName(in: data, offset: offset)
    offset += 4

    for _ in 1..<questionCount {
      offset = try skipName(in: data, offset: offset)
      offset += 4
    }

    var records: [DNSRecord] = []
    for _ in 0..<answerCount {
      offset = try skipName(in: data, offset: offset)
      guard offset + 10 <= data.count else { throw DNSResolverError.invalidResponse }

      let type = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
      let recordType = DNSRecordType(rawValue: type)
      offset += 2
      offset += 2
      let ttl = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
      offset += 4
      let rdLength = Int(data[offset]) << 8 | Int(data[offset + 1])
      offset += 2
      guard offset + rdLength <= data.count else { throw DNSResolverError.invalidResponse }

      let rdata = data.subdata(in: offset..<(offset + rdLength))
      offset += rdLength

      guard let recordType, recordType == expectedType else { continue }

      switch recordType {
      case .a where rdLength == 4:
        let ip = rdata.map(String.init).joined(separator: ".")
        records.append(DNSRecord(type: .a, value: ip, ttl: ttl))
      case .aaaa where rdLength == 16:
        var bytes = [UInt8](rdata)
        var parts: [String] = []
        for index in stride(from: 0, to: 16, by: 2) {
          parts.append(String(format: "%02x%02x", bytes[index], bytes[index + 1]))
        }
        records.append(DNSRecord(type: .aaaa, value: parts.joined(separator: ":"), ttl: ttl))
      default:
        continue
      }
    }

    return records
  }

  private static func skipName(in data: Data, offset: Int) throws -> Int {
    var index = offset
    guard index < data.count else { throw DNSResolverError.invalidResponse }

    while index < data.count {
      let length = Int(data[index])
      if length == 0 {
        return index + 1
      }
      if length & 0xC0 == 0xC0 {
        guard index + 1 < data.count else { throw DNSResolverError.invalidResponse }
        return index + 2
      }
      index += 1 + length
    }

    throw DNSResolverError.invalidResponse
  }
}
