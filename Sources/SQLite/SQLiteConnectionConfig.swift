import Foundation

/// A saved SQLite connection definition: a path to a local database file.
/// Same shape as the other engines' configs — pure value type, Codable, no
/// driver types involved. There is no host/port: the file IS the database.
public struct SQLiteConnectionConfig: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  /// Absolute (or tilde-prefixed) path to the .sqlite/.db file.
  public var filePath: String

  public init(id: UUID = UUID(), name: String, filePath: String) {
    self.id = id
    self.name = name
    self.filePath = filePath
  }

  /// Display/logging string only — the driver opens `filePath` directly.
  public var connectionString: String { "sqlite://\(filePath)" }

  public var isValid: Bool { !name.isEmpty && !filePath.isEmpty }
}

/// Driver-agnostic cell value for UI display and tests. SQLite is dynamically
/// typed, so this is the full value space (INTEGER/REAL/TEXT/BLOB/NULL).
public enum SQLiteValue: Equatable, Sendable {
  case null
  case int(Int64)
  case double(Double)
  case string(String)
  case bytes([UInt8])
}

/// One result row as key/value pairs (column name -> value). `columns` keeps the
/// SELECT's column order — the UI derives its List keys and Table columns from
/// it, so the order must match the statement rather than a dictionary's hash
/// order. Duplicate column names collapse to the last occurrence in `values`
/// while keeping both slots in `columns`.
public struct SQLiteRowData: Equatable, Identifiable, Sendable {
  /// Stable per-row identity within one result set.
  public var id: Int
  /// Column names as the statement returned them, in order, duplicates included.
  public var columns: [String]
  public var values: [String: SQLiteValue]

  init(id: Int, columns: [String], cells: [SQLiteValue]) {
    precondition(columns.count == cells.count)
    self.id = id
    self.columns = columns
    self.values = Dictionary(
      zip(columns, cells), uniquingKeysWith: { _, last in last })
  }

  public subscript(key: String) -> SQLiteValue? { values[key] }
}
