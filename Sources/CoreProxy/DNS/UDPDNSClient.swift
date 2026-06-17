import Darwin
import Foundation

enum UDPDNSClient {
  static func query(
    server: String,
    question: Data,
    timeout: TimeInterval
  ) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let response = try querySync(server: server, question: question, timeout: timeout)
          continuation.resume(returning: response)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func querySync(server: String, question: Data, timeout: TimeInterval) throws -> Data {
    let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard socketFD >= 0 else { throw DNSResolverError.timeout }

    defer { close(socketFD) }

    var timeoutVal = timeval(
      tv_sec: Int(timeout),
      tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
    )
    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeoutVal, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(53).bigEndian
    guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else {
      throw DNSResolverError.invalidResponse
    }

    let sent = question.withUnsafeBytes { buffer in
      withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
          sendto(
            socketFD,
            buffer.baseAddress,
            question.count,
            0,
            sockaddrPointer,
            socklen_t(MemoryLayout<sockaddr_in>.size)
          )
        }
      }
    }
    guard sent == question.count else { throw DNSResolverError.timeout }

    var response = Data(count: 4096)
    let received: ssize_t = response.withUnsafeMutableBytes { buffer in
      withUnsafeMutablePointer(to: &addr) { pointer in
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        return pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
          recvfrom(socketFD, buffer.baseAddress, 4096, 0, sockaddrPointer, &length)
        }
      }
    }

    guard received > 0 else { throw DNSResolverError.timeout }
    response.count = Int(received)
    return response
  }
}
