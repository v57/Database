import CryptoKit
import DatabaseKit
import Foundation
import SSHTunnel
import VaultKit

/// Database's connections as the v57 apps share them, through the vault (`../Vault`): every saved
/// connection is a `VaultDatabase` (Database and Shell list it too), and its SSH server is a `VaultHost`
/// (Shell's saved hosts), so a host set up in Shell is one pick away here and the reverse.
///
/// `ConnectionProfile` stays the app's model; this converts both ways. Fields Database doesn't know
/// stay in the record untouched.
enum SharedConnections {
  /// The profile for a shared record, or nil for an engine this build doesn't have.
  static func profile(
    from record: VaultDatabase, hosts: [VaultHost], knownFingerprint: (String, Int) -> String?
  ) -> ConnectionProfile? {
    guard let engine = EngineKind(rawValue: record.engine) else { return nil }
    var profile = ConnectionProfile(
      id: uuid(for: record.id), name: record.name, engine: engine, host: record.host,
      port: record.port == 0 ? nil : record.port, user: record.user, database: record.database,
      filePath: record.filePath, options: record.options, color: ColorTag(rawValue: record.color) ?? .none,
      isProduction: record.isProduction, isReadOnly: record.isReadOnly, useTLS: record.useTLS,
      allowUntrustedCertificate: record.allowUntrustedCertificate, savePassword: record.savePassword,
      lastUsed: record.lastUsed)
    if let id = record.sshHostID, let host = hosts.first(where: { $0.id == id }) {
      profile.ssh = SSHSettings(
        enabled: true, host: host.hostname, port: host.port, user: host.user,
        auth: host.auth == .password ? .password : .key,
        keyID: host.auth == .importedKey ? host.keyID.flatMap(UUID.init(uuidString:)) : nil,
        hostKeyFingerprint: knownFingerprint(host.hostname, host.port))
    }
    return profile
  }

  /// The shared record for a profile: `existing` with the profile's fields written over it.
  static func record(from profile: ConnectionProfile, id: String, hostID: String?, existing: VaultDatabase?)
    -> VaultDatabase
  {
    var record = existing ?? VaultDatabase(id: id, engine: profile.engine.rawValue, port: profile.port)
    record.name = profile.name
    record.engine = profile.engine.rawValue
    record.host = profile.host
    record.port = profile.port
    record.user = profile.user
    record.database = profile.database
    record.filePath = profile.filePath
    record.options = profile.options
    record.color = profile.color.rawValue
    record.isProduction = profile.isProduction
    record.isReadOnly = profile.isReadOnly
    record.useTLS = profile.useTLS
    record.allowUntrustedCertificate = profile.allowUntrustedCertificate
    record.sshHostID = hostID
    record.savePassword = profile.savePassword
    record.lastUsed = profile.lastUsed
    return record
  }

  /// The shared host for a profile's SSH settings: the saved one with that address, port and user (its
  /// sign-in method updated), or a new one.
  static func host(for ssh: SSHSettings, among hosts: [VaultHost]) -> VaultHost {
    let auth: VaultHost.Auth = ssh.auth == .password ? .password : (ssh.keyID == nil ? .deviceKey : .importedKey)
    var host =
      hosts.first {
        $0.hostname.caseInsensitiveCompare(ssh.host) == .orderedSame && $0.port == ssh.port && $0.user == ssh.user
      } ?? VaultHost(hostname: ssh.host, port: ssh.port, user: ssh.user, source: "databasepro")
    host.auth = auth
    host.keyID = ssh.keyID?.uuidString
    return host
  }

  /// Records made by other apps may have ids that aren't UUIDs: those get a stable UUID from the id.
  static func uuid(for id: String) -> UUID {
    if let uuid = UUID(uuidString: id) { return uuid }
    var bytes = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }

  /// This device's SSH key (Secure Enclave, shared by the v57 apps): Shell and Database log
  /// in with the same key, so it goes into `authorized_keys` once per device.
  static func deviceKey() throws -> SSHKey {
    let key = try VaultIdentity.key()
    let blob = VaultIdentity.publicKeyBlob(key)
    return SSHKey(kind: .ecdsaP256, publicKeyBlob: Array(blob), comment: deviceName) { data in
      Array(try VaultIdentity.sshSignature(Data(data), key: key))
    }
  }

  static var deviceName: String {
    #if os(macOS)
      Host.current().localizedName ?? "Mac"
    #else
      "iPhone"
    #endif
  }
}

/// Passwords and imported keys in the shared keychain group (`VaultSecrets`): a database's password is
/// named after the connection and an SSH password after the host, so the other v57 apps find them.
struct VaultSecretStore: SecretStore {
  func read(_ account: String) -> Data? {
    if let id = Self.passwordID(account) { return VaultSecrets.password(for: id).map { Data($0.utf8) } }
    return VaultSecrets.secret("database." + account)
  }

  func write(_ account: String, _ data: Data?) throws {
    if let id = Self.passwordID(account) {
      try VaultSecrets.setPassword(data.map { String(decoding: $0, as: UTF8.self) }, for: id)
    } else {
      try VaultSecrets.setSecret(data, named: "database." + account)
    }
  }

  /// `db.<id>` and `host.<id>` are passwords of shared records.
  private static func passwordID(_ account: String) -> String? {
    for prefix in ["db.", "host."] where account.hasPrefix(prefix) { return String(account.dropFirst(prefix.count)) }
    return nil
  }
}

extension SecretStore {
  func hostPassword(for hostID: String) -> String? { string("host.\(hostID)") }
  func setHostPassword(_ password: String?, for hostID: String) throws { try setString("host.\(hostID)", password) }
}
