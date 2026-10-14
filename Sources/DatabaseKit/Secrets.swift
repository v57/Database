import Foundation
import SSHTunnel
import Security

/// Where passwords and private keys are kept.
public protocol SecretStore: Sendable {
  func read(_ account: String) -> Data?
  func write(_ account: String, _ data: Data?) throws
}

extension SecretStore {
  public func string(_ account: String) -> String? { read(account).map { String(decoding: $0, as: UTF8.self) } }
  public func setString(_ account: String, _ value: String?) throws { try write(account, value.map { Data($0.utf8) }) }

  public func databasePassword(for id: UUID) -> String? { string("db.\(id.uuidString)") }
  public func setDatabasePassword(_ password: String?, for id: UUID) throws {
    try setString("db.\(id.uuidString)", password)
  }

  public func sshPassword(for id: UUID) -> String? { string("ssh.\(id.uuidString)") }
  public func setSSHPassword(_ password: String?, for id: UUID) throws { try setString("ssh.\(id.uuidString)", password) }
}

public struct KeychainError: Error, LocalizedError {
  public var status: OSStatus
  public var errorDescription: String? {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
  }
}

/// The login Keychain (macOS) or the app's Keychain (iOS), as generic passwords.
public struct KeychainStore: SecretStore {
  public let service: String

  public init(service: String = "dev.v57.db") { self.service = service }

  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  public func read(_ account: String) -> Data? {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  public func write(_ account: String, _ data: Data?) throws {
    guard let data else {
      let status = SecItemDelete(query(account) as CFDictionary)
      if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status: status) }
      return
    }
    let update = [kSecValueData as String: data]
    var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = query(account)
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      status = SecItemAdd(add as CFDictionary, nil)
    }
    if status != errSecSuccess { throw KeychainError(status: status) }
  }
}

/// For tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
  private var values: [String: Data] = [:]
  private let lock = NSLock()
  public init() {}
  public func read(_ account: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[account]
  }
  public func write(_ account: String, _ data: Data?) throws {
    lock.lock()
    defer { lock.unlock() }
    values[account] = data
  }
}

/// SSH private keys kept in the secret store, with their names and public halves listed in a file.
public struct StoredSSHKey: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var kind: SSHKey.Kind
  public var publicKeyLine: String
  public var fingerprint: String
  public var created: Date
}

public final class SSHKeyStore: @unchecked Sendable {
  private let secrets: SecretStore
  private let listURL: URL?
  private let lock = NSLock()
  private var cached: [StoredSSHKey]

  public init(secrets: SecretStore, listURL: URL?) {
    self.secrets = secrets
    self.listURL = listURL
    if let listURL, let data = try? Data(contentsOf: listURL),
      let keys = try? JSONDecoder().decode([StoredSSHKey].self, from: data)
    {
      cached = keys
    } else {
      cached = []
    }
  }

  public var keys: [StoredSSHKey] {
    lock.lock()
    defer { lock.unlock() }
    return cached
  }

  public func key(_ id: UUID) -> SSHKey? {
    guard let stored = keys.first(where: { $0.id == id }), let data = secrets.read("sshkey.\(id.uuidString)") else {
      return nil
    }
    return try? SSHKey(kind: stored.kind, privateBytes: [UInt8](data), comment: stored.name)
  }

  /// Makes a new Ed25519 key named for this device.
  @discardableResult
  public func generate(name: String) throws -> StoredSSHKey {
    try add(SSHKey.generateEd25519(comment: name), name: name)
  }

  /// Adds an imported key.
  @discardableResult
  public func add(_ key: SSHKey, name: String) throws -> StoredSSHKey {
    let stored = StoredSSHKey(
      id: UUID(), name: name, kind: key.kind, publicKeyLine: key.authorizedKeyLine, fingerprint: key.fingerprint,
      created: Date())
    try secrets.write("sshkey.\(stored.id.uuidString)", Data(key.privateBytes))
    lock.lock()
    cached.append(stored)
    lock.unlock()
    try save()
    return stored
  }

  public func remove(_ id: UUID) throws {
    try secrets.write("sshkey.\(id.uuidString)", nil)
    lock.lock()
    cached.removeAll { $0.id == id }
    lock.unlock()
    try save()
  }

  public func rename(_ id: UUID, to name: String) throws {
    lock.lock()
    if let index = cached.firstIndex(where: { $0.id == id }) { cached[index].name = name }
    lock.unlock()
    try save()
  }

  private func save() throws {
    guard let listURL else { return }
    try FileManager.default.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(keys).write(to: listURL, options: .atomic)
  }
}
