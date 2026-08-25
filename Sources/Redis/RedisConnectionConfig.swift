import Foundation

/// A saved Redis connection definition. Same shape as the MongoDB
/// `ConnectionConfig`: pure value type, Codable, no driver types involved.
/// Redis has no username by default (ACL users are the exception) and no
/// server-side database names — `defaultDatabase` is an integer index (0-15).
public struct RedisConnectionConfig: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var host: String
  public var port: UInt16
  /// Optional ACL username; nil for the default single-user setup.
  public var username: String?
  /// Optional password (AUTH / ACL).
  public var password: String?
  /// Logical database index (0-15) to select after connect. Nil = server default (0).
  public var databaseIndex: Int?

  public init(
    id: UUID = UUID(), name: String, host: String, port: UInt16 = 6379, username: String? = nil,
    password: String? = nil, databaseIndex: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.username = username
    self.password = password
    self.databaseIndex = databaseIndex
  }

  /// redis:// URI (display/logging only — the driver takes structured config).
  public var connectionString: String {
    var s = "redis://"
    if let u = username, !u.isEmpty {
      s += u.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? u
      if let p = password, !p.isEmpty {
        s += ":" + (p.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? p)
      }
      s += "@"
    } else if let p = password, !p.isEmpty {
      // Redis URL convention: password-only goes in the username slot.
      s += ":" + (p.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? p) + "@"
    }
    s += "\(host):\(port)"
    if let db = databaseIndex { s += "/\(db)" }
    return s
  }

  public var isValid: Bool { !host.isEmpty && port > 0 }
}

/// One logical Redis database's keys as documents for the UI: each key maps
/// to a "document" with type/value/TTL rows so the existing document list can
/// render it without special-casing.
public struct RedisKeyEntry: Equatable, Identifiable, Sendable {
  public var id: String { key }
  public let key: String
  /// TYPE output: string, list, set, zset, hash, stream, none.
  public let typeName: String
  /// Human-readable rendering of the value (JSON for hashes/lists when possible).
  public let displayValue: String
  /// TTL in seconds; -1 = no expiry, -2 = key missing.
  public let ttl: Int

  public init(key: String, typeName: String, displayValue: String, ttl: Int) {
    self.key = key
    self.typeName = typeName
    self.displayValue = displayValue
    self.ttl = ttl
  }
}
