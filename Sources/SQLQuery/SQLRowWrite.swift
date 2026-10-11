import Foundation
import MongoDB

/// Single-row writes for the client's record editor: an UPDATE or DELETE
/// addressed by the row's primary-key values, and an INSERT. Values come in
/// as BSON (the app's display model for every engine) and are rendered as
/// inline literals; `target` is an already-quoted table reference, as for
/// `SQLPipelineCompiler.compile(_:from:flavor:)`.
public enum SQLRowWrite {
  /// `UPDATE target SET "a" = 1, … WHERE "id" = 7`.
  public static func update(
    _ target: String, set changes: BSONDocument, key: BSONDocument, flavor: SQLFlavor
  ) throws -> String {
    guard !changes.isEmpty else { throw SQLQueryError.invalidQuery("Nothing to update") }
    let assignments = try changes.all.map { column, value in
      "\(SQLQueryCompiler.quotedIdentifier(column)) = \(try literal(value, flavor: flavor))"
    }
    return "UPDATE \(target) SET \(assignments.joined(separator: ", ")) WHERE \(try condition(key, flavor: flavor))"
  }

  /// `DELETE FROM target WHERE "id" = 7`.
  public static func delete(from target: String, key: BSONDocument, flavor: SQLFlavor) throws
    -> String
  {
    "DELETE FROM \(target) WHERE \(try condition(key, flavor: flavor))"
  }

  /// `INSERT INTO target ("a", "b") VALUES (1, 'x')`; no values inserts a row
  /// of column defaults.
  public static func insert(into target: String, values: BSONDocument, flavor: SQLFlavor) throws
    -> String
  {
    guard !values.isEmpty else { return "INSERT INTO \(target) DEFAULT VALUES" }
    let columns = values.keys.map(SQLQueryCompiler.quotedIdentifier)
    let literals = try values.all.map { try literal($0.value, flavor: flavor) }
    return "INSERT INTO \(target) (\(columns.joined(separator: ", "))) VALUES (\(literals.joined(separator: ", ")))"
  }

  /// The WHERE body matching exactly the row with these key values. An empty
  /// key is refused: it would address every row.
  private static func condition(_ key: BSONDocument, flavor: SQLFlavor) throws -> String {
    guard !key.isEmpty else {
      throw SQLQueryError.invalidQuery("The row has no primary key to address it by")
    }
    return try key.all.map { column, value in
      let quoted = SQLQueryCompiler.quotedIdentifier(column)
      if case .null = value { return "\(quoted) IS NULL" }
      return "\(quoted) = \(try literal(value, flavor: flavor))"
    }.joined(separator: " AND ")
  }

  /// An inline SQL literal for a stored value. Unlike filter literals, NULL
  /// is a value here (clearing a field), and dates/ids/bytes have spellings.
  public static func literal(_ value: BSON, flavor: SQLFlavor) throws -> String {
    switch value {
    case .null, .undefined: return "NULL"
    case .bool(let flag):
      // SQLite stores booleans as integers.
      return flavor == .sqlite ? (flag ? "1" : "0") : (flag ? "TRUE" : "FALSE")
    case .datetime(let date): return quoted(isoFormatter.string(from: date))
    case .objectID(let id): return quoted(id.hex)
    case .decimal128(let number):
      let text = number.description
      guard Double(text) != nil else {
        throw SQLQueryError.invalidQuery("“\(text)” isn’t a number SQL can store")
      }
      return text
    case .binary(let binary):
      let hex = binary.data.map { String(format: "%02x", $0) }.joined()
      return flavor == .sqlite ? "X'\(hex)'" : "'\\x\(hex)'"
    default: return try SQLQueryCompiler.literal(value, for: "value")
    }
  }

  private static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
  }

  private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
