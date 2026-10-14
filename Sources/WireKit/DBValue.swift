import Foundation

/// A single cell as the table-shaped engines return it. Dates and times stay in
/// the server's own text form so they round-trip into SQL unchanged.
public indirect enum DBValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  /// Exact numbers (DECIMAL, NUMERIC, MONEY, unsigned 64-bit) as text.
  case decimal(String)
  case text(String)
  case bytes([UInt8])
  case uuid(UUID)
  case json(String)
  case list([DBValue])
  case map([DBPair])

  public var isNull: Bool { if case .null = self { true } else { false } }

  /// How the value reads in a grid cell.
  public var displayText: String {
    switch self {
    case .null: "NULL"
    case .bool(let b): b ? "true" : "false"
    case .int(let i): String(i)
    case .double(let d): Self.format(d)
    case .decimal(let s), .text(let s), .json(let s): s
    case .bytes(let b): b.count <= 32 ? "0x" + b.hexString.uppercased() : "\(b.count) bytes"
    case .uuid(let u): u.uuidString.lowercased()
    case .list(let items): "[" + items.map(\.literalText).joined(separator: ", ") + "]"
    case .map(let pairs): "{" + pairs.map { "\($0.key.literalText): \($0.value.literalText)" }.joined(separator: ", ") + "}"
    }
  }

  /// Like `displayText`, but strings inside collections are quoted.
  public var literalText: String {
    switch self {
    case .text(let s): "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    default: displayText
    }
  }

  public var stringValue: String? {
    switch self {
    case .null: nil
    case .text(let s), .decimal(let s), .json(let s): s
    default: displayText
    }
  }

  public var intValue: Int64? {
    switch self {
    case .int(let i): i
    case .bool(let b): b ? 1 : 0
    case .double(let d): Int64(exactly: d.rounded()) ?? nil
    case .decimal(let s), .text(let s): Int64(s)
    default: nil
    }
  }

  public var doubleValue: Double? {
    switch self {
    case .int(let i): Double(i)
    case .double(let d): d
    case .decimal(let s), .text(let s): Double(s)
    default: nil
    }
  }

  static func format(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
    if d == d.rounded(), abs(d) < 1e15 { return String(format: "%.1f", d) }
    return String(d)
  }
}

public struct DBPair: Sendable, Hashable {
  public var key: DBValue
  public var value: DBValue
  public init(key: DBValue, value: DBValue) {
    self.key = key
    self.value = value
  }
}

/// A result column: its name and the server's type name.
public struct DBColumn: Sendable, Hashable {
  public var name: String
  public var typeName: String
  /// The source table, when the server reports it.
  public var table: String?

  public init(name: String, typeName: String, table: String? = nil) {
    self.name = name
    self.typeName = typeName
    self.table = table
  }
}

/// What one statement produced: rows (possibly none), a changed-row count, and notices.
public struct DBResult: Sendable {
  public var columns: [DBColumn]
  public var rows: [[DBValue]]
  public var affectedRows: Int?
  public var messages: [String]
  /// The server's tag, e.g. "SELECT 3" or "UPDATE 1".
  public var commandTag: String?

  public init(
    columns: [DBColumn] = [], rows: [[DBValue]] = [], affectedRows: Int? = nil, messages: [String] = [],
    commandTag: String? = nil
  ) {
    self.columns = columns
    self.rows = rows
    self.affectedRows = affectedRows
    self.messages = messages
    self.commandTag = commandTag
  }

  public var hasRows: Bool { !columns.isEmpty }

  public func column(_ name: String) -> Int? { columns.firstIndex { $0.name == name } }

  /// The rows as dictionaries keyed by column name (later duplicates win).
  public var records: [[String: DBValue]] {
    rows.map { row in
      var out: [String: DBValue] = [:]
      for (i, column) in columns.enumerated() where i < row.count { out[column.name] = row[i] }
      return out
    }
  }
}

/// A server-side error with the engine's own code, shown to people as is.
public struct DBServerError: Error, LocalizedError, Sendable {
  public var engine: String
  public var code: String?
  public var message: String
  public var detail: String?

  public init(engine: String, code: String? = nil, message: String, detail: String? = nil) {
    self.engine = engine
    self.code = code
    self.message = message
    self.detail = detail
  }

  public var errorDescription: String? {
    var text = message
    if let detail, !detail.isEmpty { text += " (\(detail))" }
    return text
  }
}
