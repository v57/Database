import Foundation

/// A saved PostgreSQL connection definition. Same shape as the MongoDB
/// `ConnectionConfig`: pure value type, Codable, no driver types involved.
public struct PostgresConnectionConfig: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var host: String
  public var port: UInt16
  /// Optional credentials. The local compose server uses postgres/postgres.
  public var username: String?
  public var password: String?
  /// Database preselected after connect (UI convenience).
  public var defaultDatabase: String?

  public init(
    id: UUID = UUID(), name: String, host: String, port: UInt16 = 5432, username: String? = nil,
    password: String? = nil, defaultDatabase: String? = nil
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.username = username
    self.password = password
    self.defaultDatabase = defaultDatabase
  }

  /// postgres:// URI (display/logging only — the driver takes structured config).
  public var connectionString: String {
    var s = "postgres://"
    if let u = username, !u.isEmpty {
      s += u.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? u
      if let p = password, !p.isEmpty {
        s += ":" + (p.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? p)
      }
      s += "@"
    }
    s += "\(host):\(port)/\(defaultDatabase ?? "postgres")"
    return s
  }

  public var isValid: Bool { !host.isEmpty && port > 0 }
}

/// Driver-agnostic cell value for UI display and tests.
public enum PostgresValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case date(Date)
  /// JSON/JSONB payload kept as text (UI renders it like any other string).
  case json(String)
  case bytes([UInt8])
}

/// One result row as key/value pairs (column name -> value). `columns` keeps the
/// SELECT's column order — the UI derives its List keys and Table columns from
/// it, so the order must match the statement rather than a dictionary's hash
/// order. Duplicate column names collapse to the last occurrence in `values`
/// while keeping both slots in `columns`.
public struct PostgresRowData: Equatable, Identifiable, Sendable {
  /// Stable per-row identity within one result set.
  public var id: Int
  /// Column names as the statement returned them, in order, duplicates included.
  public var columns: [String]
  public var values: [String: PostgresValue]

  init(id: Int, columns: [String], cells: [PostgresValue]) {
    precondition(columns.count == cells.count)
    self.id = id
    self.columns = columns
    self.values = Dictionary(
      zip(columns, cells), uniquingKeysWith: { _, last in last })
  }

  public subscript(key: String) -> PostgresValue? { values[key] }
}
