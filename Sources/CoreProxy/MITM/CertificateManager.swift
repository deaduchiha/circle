import Crypto
import Foundation
import Logging
import NIOSSL
import Security
import SwiftASN1
import X509

public enum CertificateManagerError: Error, LocalizedError {
  case caNotFound
  case invalidStoredMaterial
  case keychainError(OSStatus)
  case exportFailed

  public var errorDescription: String? {
    switch self {
    case .caNotFound:
      "MITM CA certificate has not been generated yet."
    case .invalidStoredMaterial:
      "Stored certificate material is invalid."
    case .keychainError(let status):
      "Keychain operation failed with status \(status)."
    case .exportFailed:
      "Failed to export certificate."
    }
  }
}

public struct LeafCertificateMaterial: Sendable {
  public var certificate: Certificate
  public var privateKeyPEM: String
}

public final class CertificateManager: @unchecked Sendable {
  public static let shared = CertificateManager()

  private let log = ProxyLogger.logger("certificate")
  private let lock = NSLock()
  private var leafCache: [String: LeafCertificateMaterial] = [:]
  private var leafCacheOrder: [String] = []
  private let maxLeafCacheEntries = 256

  private let keychainService = "circle.mitm.ca"
  private let keychainCertAccount = "ca.certificate"
  private let keychainKeyAccount = "ca.private-key"
  private let keychainInstalledAccount = "ca.installed"

  private init() {}

  public func shouldIntercept(hostname: String, mitm: MITMConfig) -> Bool {
    guard mitm.enabled, hasCA() else { return false }
    guard !hostname.isEmpty else { return false }

    if mitm.hostnames.isEmpty {
      return true
    }

    let host = hostname.lowercased()
    return mitm.hostnames.contains { pattern in
      let value = pattern.lowercased()
      if value.hasPrefix("*.") {
        let suffix = String(value.dropFirst(2))
        return host == suffix || host.hasSuffix("." + suffix)
      }
      return host == value
    }
  }

  public func hasCA() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return loadCAUnsafe() != nil
  }

  @discardableResult
  public func generateCA(commonName: String = "circle MITM CA") throws -> MITMCertificateStatus {
    let signingKey = P256.Signing.PrivateKey()
    let privateKey = Certificate.PrivateKey(signingKey)
    let now = Date()
    let notAfter =
      Calendar.current.date(byAdding: .year, value: 10, to: now)
      ?? now.addingTimeInterval(315_360_000)

    let subject = try DistinguishedName {
      OrganizationName("circle")
      CommonName(commonName)
    }

    let extensions = try Certificate.Extensions {
      Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
      KeyUsage(digitalSignature: true, keyCertSign: true, cRLSign: true)
      SubjectKeyIdentifier(
        keyIdentifier: ArraySlice(Insecure.SHA1.hash(data: signingKey.publicKey.derRepresentation))
      )
    }

    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(),
      publicKey: privateKey.publicKey,
      notValidBefore: now,
      notValidAfter: notAfter,
      issuer: subject,
      subject: subject,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: privateKey
    )

    try storeCAUnsafe(
      certificate: certificate,
      privateKey: privateKey,
      privateKeyPEM: signingKey.pemRepresentation
    )
    clearLeafCacheUnsafe()

    guard let status = try certificateStatusUnsafe() else {
      throw CertificateManagerError.invalidStoredMaterial
    }
    log.info("MITM CA generated", metadata: ["commonName": "\(commonName)"])
    return status
  }

  public func certificateStatus() throws -> MITMCertificateStatus? {
    lock.lock()
    defer { lock.unlock() }
    return try certificateStatusUnsafe()
  }

  public func exportCAPEM() throws -> String {
    lock.lock()
    defer { lock.unlock() }

    guard let material = loadCAUnsafe() else {
      throw CertificateManagerError.caNotFound
    }

    let certPEM = try material.certificate.serializeAsPEM().pemString
    return certPEM + "\n"
  }

  public func exportCAPEM(to url: URL) throws {
    try exportCAPEM().write(to: url, atomically: true, encoding: .utf8)
  }

  public func installCAInKeychain() throws {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("circle-mitm-ca-\(UUID().uuidString).pem")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    try exportCAPEM(to: tempURL)

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = [
      "add-trusted-cert",
      "-d",
      "-r", "trustRoot",
      "-p", "ssl",
      "-k", NSHomeDirectory() + "/Library/Keychains/login.keychain-db",
      tempURL.path,
    ]
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw CertificateManagerError.keychainError(OSStatus(process.terminationStatus))
    }

    try setKeychainFlag(account: keychainInstalledAccount, value: "true")
    log.info("MITM CA installed in keychain")
  }

  public func leafMaterial(for hostname: String) throws -> LeafCertificateMaterial {
    let normalized = hostname.lowercased()

    lock.lock()
    if let cached = leafCache[normalized] {
      touchLeafCacheUnsafe(hostname: normalized)
      lock.unlock()
      return cached
    }
    lock.unlock()

    let material = try issueLeafCertificate(for: normalized)

    lock.lock()
    leafCache[normalized] = material
    touchLeafCacheUnsafe(hostname: normalized)
    while leafCacheOrder.count > maxLeafCacheEntries, let evicted = leafCacheOrder.first {
      leafCacheOrder.removeFirst()
      leafCache.removeValue(forKey: evicted)
    }
    lock.unlock()

    return material
  }

  public func serverTLSConfiguration(for hostname: String) throws -> TLSConfiguration {
    let leaf = try leafMaterial(for: hostname)

    let certPEM = try leaf.certificate.serializeAsPEM().pemString
    let nioCert = try NIOSSLCertificate(bytes: Array(certPEM.utf8), format: .pem)
    let nioKey = try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyPEM.utf8), format: .pem)

    var config = TLSConfiguration.makeServerConfiguration(
      certificateChain: [.certificate(nioCert)],
      privateKey: .privateKey(nioKey)
    )
    config.applicationProtocols = ["http/1.1"]
    return config
  }

  public func clientTLSConfiguration() -> TLSConfiguration {
    var config = TLSConfiguration.makeClientConfiguration()
    config.certificateVerification = .none
    config.applicationProtocols = ["http/1.1"]
    return config
  }

  // MARK: - Private

  private struct CAMaterial {
    var certificate: Certificate
    var privateKey: Certificate.PrivateKey
    var privateKeyPEM: String
  }

  private func loadCAOrThrow() throws -> CAMaterial {
    lock.lock()
    defer { lock.unlock() }
    guard let material = loadCAUnsafe() else {
      throw CertificateManagerError.caNotFound
    }
    return material
  }

  private func loadCAUnsafe() -> CAMaterial? {
    guard let certData = readKeychain(account: keychainCertAccount),
      let keyPEMData = readKeychain(account: keychainKeyAccount),
      let keyPEM = String(data: keyPEMData, encoding: .utf8)
    else {
      return nil
    }

    do {
      let certificate = try Certificate(derEncoded: Array(certData))
      let privateKey = try Certificate.PrivateKey(pemEncoded: keyPEM)
      return CAMaterial(certificate: certificate, privateKey: privateKey, privateKeyPEM: keyPEM)
    } catch {
      return nil
    }
  }

  private func storeCAUnsafe(
    certificate: Certificate,
    privateKey: Certificate.PrivateKey,
    privateKeyPEM: String
  ) throws {
    var serializer = DER.Serializer()
    try certificate.serialize(into: &serializer)
    let certData = Data(serializer.serializedBytes)

    try writeKeychain(account: keychainCertAccount, data: certData)
    try writeKeychain(account: keychainKeyAccount, data: Data(privateKeyPEM.utf8))
    try? deleteKeychain(account: keychainInstalledAccount)
  }

  private func issueLeafCertificate(for hostname: String) throws -> LeafCertificateMaterial {
    guard let ca = loadCAUnsafe() else {
      throw CertificateManagerError.caNotFound
    }

    let signingKey = P256.Signing.PrivateKey()
    let privateKey = Certificate.PrivateKey(signingKey)
    let now = Date()
    let notAfter =
      Calendar.current.date(byAdding: .day, value: 825, to: now)
      ?? now.addingTimeInterval(71_280_000)

    let subject = try DistinguishedName {
      CommonName(hostname)
    }

    let extensions = try Certificate.Extensions {
      Critical(BasicConstraints.notCertificateAuthority)
      KeyUsage(digitalSignature: true, keyEncipherment: true)
      try ExtendedKeyUsage([.serverAuth])
      try SubjectAlternativeNames([.dnsName(hostname)])
    }

    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(),
      publicKey: privateKey.publicKey,
      notValidBefore: now,
      notValidAfter: notAfter,
      issuer: ca.certificate.subject,
      subject: subject,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: ca.privateKey
    )

    return LeafCertificateMaterial(
      certificate: certificate, privateKeyPEM: signingKey.pemRepresentation)
  }

  private func certificateStatusUnsafe() throws -> MITMCertificateStatus? {
    guard let material = loadCAUnsafe() else { return nil }

    var serializer = DER.Serializer()
    try material.certificate.serialize(into: &serializer)
    let digest = SHA256.hash(data: Data(serializer.serializedBytes))
    let fingerprint = digest.map { String(format: "%02x", $0) }.joined()

    let commonName = material.certificate.subject.description
    let installed = readKeychain(account: keychainInstalledAccount) != nil

    return MITMCertificateStatus(
      commonName: commonName,
      fingerprintSHA256: fingerprint,
      notValidBefore: material.certificate.notValidBefore,
      notValidAfter: material.certificate.notValidAfter,
      isInstalledInKeychain: installed
    )
  }

  private func touchLeafCacheUnsafe(hostname: String) {
    leafCacheOrder.removeAll { $0 == hostname }
    leafCacheOrder.append(hostname)
  }

  private func clearLeafCacheUnsafe() {
    leafCache.removeAll()
    leafCacheOrder.removeAll()
  }

  private func readKeychain(account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else { return nil }
    return item as? Data
  }

  private func writeKeychain(account: String, data: Data) throws {
    try? deleteKeychain(account: account)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw CertificateManagerError.keychainError(status)
    }
  }

  @discardableResult
  private func setKeychainFlag(account: String, value: String) throws -> Bool {
    try writeKeychain(account: account, data: Data(value.utf8))
    return true
  }

  private func deleteKeychain(account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
