import Foundation

/// The color label a connection carries in the sidebar.
public enum ColorTag: String, Codable, CaseIterable, Sendable, Identifiable {
  case none, red, orange, yellow, green, blue, purple, gray
  public var id: String { rawValue }
  public var label: String { rawValue.capitalized }
}

/// How the SSH tunnel logs in.
public enum SSHAuthMethod: String, Codable, Sendable, CaseIterable {
  case key, password
}

/// An SSH hop in front of the database.
public struct SSHSettings: Codable, Hashable, Sendable {
  public var enabled: Bool
  public var host: String
  public var port: Int
  public var user: String
  public var auth: SSHAuthMethod
  /// Which stored key to use (see `SSHKeyStore`); nil means this device's Secure Enclave key.
  public var keyID: UUID?
  /// Remembered after the first successful login; a different key is refused.
  public var hostKeyFingerprint: String?

  public init(
    enabled: Bool = false, host: String = "", port: Int = 22, user: String = "", auth: SSHAuthMethod = .key,
    keyID: UUID? = nil, hostKeyFingerprint: String? = nil
  ) {
    self.enabled = enabled
    self.host = host
    self.port = port
    self.user = user
    self.auth = auth
    self.keyID = keyID
    self.hostKeyFingerprint = hostKeyFingerprint
  }
}

/// A saved connection. Passwords live in the Keychain, never here.
public struct ConnectionProfile: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var engine: EngineKind
  public var host: String
  public var port: Int
  public var user: String
  /// Default database / keyspace / Redis index, or empty.
  public var database: String
  /// SQLite and DuckDB file; DuckDB may also point at a Parquet/CSV/JSON file.
  public var filePath: String
  /// Engine-specific options (authSource, consistency, …).
  public var options: [String: String]
  public var color: ColorTag
  /// Shows a red tag; every change goes through review.
  public var isProduction: Bool
  /// Look, never change.
  public var isReadOnly: Bool
  public var useTLS: Bool
  public var allowUntrustedCertificate: Bool
  public var ssh: SSHSettings
  public var savePassword: Bool
  public var lastUsed: Date?

  public init(
    id: UUID = UUID(), name: String = "", engine: EngineKind, host: String = "127.0.0.1", port: Int? = nil,
    user: String? = nil, database: String = "", filePath: String = "", options: [String: String] = [:],
    color: ColorTag = .none, isProduction: Bool = false, isReadOnly: Bool = false, useTLS: Bool = false,
    allowUntrustedCertificate: Bool = false, ssh: SSHSettings = SSHSettings(), savePassword: Bool = true,
    lastUsed: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.engine = engine
    self.host = host
    self.port = port ?? engine.defaultPort
    self.user = user ?? engine.defaultUser
    self.database = database
    self.filePath = filePath
    self.options = options
    self.color = color
    self.isProduction = isProduction
    self.isReadOnly = isReadOnly
    self.useTLS = useTLS
    self.allowUntrustedCertificate = allowUntrustedCertificate
    self.ssh = ssh
    self.savePassword = savePassword
    self.lastUsed = lastUsed
  }

  /// Name shown in the sidebar.
  public var displayName: String {
    if !name.isEmpty { return name }
    if engine.isFileBased { return URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent }
    return host.isEmpty ? engine.displayName : host
  }

  /// "PostgreSQL · db.shop.internal" style subtitle.
  public var subtitle: String {
    if engine.isFileBased { return "\(engine.displayName) · \(URL(fileURLWithPath: filePath).lastPathComponent)" }
    var place = host
    if port != engine.defaultPort { place += ":\(port)" }
    if ssh.enabled { place += " via SSH" }
    return "\(engine.displayName) · \(place)"
  }

  /// What's missing before a connection can be tried, in plain words.
  public var problems: [String] {
    var out: [String] = []
    if engine.isFileBased {
      if filePath.isEmpty { out.append("Choose a database file.") }
    } else {
      if host.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Enter the server's host name or address.") }
      if !(1...65535).contains(port) { out.append("The port must be between 1 and 65535.") }
    }
    if ssh.enabled {
      if ssh.host.isEmpty { out.append("Enter the SSH server.") }
      if ssh.user.isEmpty { out.append("Enter the SSH user name.") }
    }
    return out
  }
}
