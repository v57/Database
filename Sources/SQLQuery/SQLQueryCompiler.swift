import Foundation
import MongoDB

/// Errors surfaced by the JSON -> SQL query compiler. `invalidQuery` carries a
/// message ready for the query bar's inline error text.
public enum SQLQueryError: Error, LocalizedError, Equatable {
  case invalidQuery(String)

  public var errorDescription: String? {
    switch self {
    case .invalidQuery(let message): return message
    }
  }
}

/// The SQL pieces one query-bar state implies for PostgreSQL/SQLite: the
/// SELECT column list plus optional WHERE / ORDER BY bodies. The table name is
/// deliberately absent — each engine quotes its own. `columns` stays `"*"`
/// unless a JSON projection was compiled (raw SQL projection text remains
/// unapplied, matching the pre-existing behavior).
public struct SQLQueryParts: Equatable, Sendable {
  public var columns: String
  public var whereBody: String?
  public var orderBy: String?

  public init(columns: String = "*", whereBody: String? = nil, orderBy: String? = nil) {
    self.columns = columns
    self.whereBody = whereBody
    self.orderBy = orderBy
  }
}

/// Compiles Mongo-style JSON query text — the same dialect MongoDB accepts in
/// the query bar (strict JSON, JS-style unquoted keys, or bare
/// `key: value` pairs) — into PostgreSQL/SQLite SQL fragments with inline,
/// properly escaped literals.
///
/// Text that is NOT JSON-like passes through untouched as a raw SQL fragment,
/// so `age > 30`, `LIKE` patterns and `::` casts keep working. The dialects
/// cannot collide: raw SQL fragments never use `key:` syntax, and text that
/// explicitly starts with `{` or `[` is treated as JSON intent, so malformed
/// JSON surfaces as an error instead of being spliced into the statement.
///
/// Supported filter operators: equality, `$gt` `$gte` `$lt` `$lte` `$ne`
/// (null-aware: null becomes IS [NOT] NULL), `$in` `$nin`, `$exists`, and the
/// `$or` / `$and` condition groups. Sort documents use Mongo directions
/// (`{age: -1}` -> DESC). Projection documents are include-only (`{name: 1}`);
/// exclusion (0) has no SQL equivalent and throws.
public enum SQLQueryCompiler {
  /// Compiles the three query-bar fields in one pass. Any field whose text is
  /// JSON-like is compiled; any other text is a raw SQL fragment.
  public static func compile(filter: String?, sort: String?, projection: String?) throws -> SQLQueryParts {
    var parts = SQLQueryParts()
    if let text = trimmed(filter) {
      parts.whereBody = try compileJSONOrRaw(text) { try compileFilter($0) }
    }
    if let text = trimmed(sort) {
      parts.orderBy = try compileJSONOrRaw(text) { try compileSort($0) }
    }
    if let text = trimmed(projection), let doc = try queryDocument(text) {
      if let columns = try compileProjection(doc) { parts.columns = columns }
    }
    return parts
  }

  // MARK: - Dialect detection

  /// Compiles JSON-like text; any other text is returned verbatim (the raw
  /// SQL fragment path). A nil compile result means the field is unrestricted.
  private static func compileJSONOrRaw(
    _ text: String, _ compile: (BSONDocument) throws -> String?
  ) throws -> String? {
    if let doc = try queryDocument(text) { return try compile(doc) }
    return text
  }

  /// Parses the tolerant Mongo dialect into a document. Returns nil when the
  /// text is not JSON-like (caller treats it as a raw SQL fragment). Text that
  /// explicitly starts like JSON but fails to parse throws, so broken JSON is
  /// reported instead of being spliced into the statement as garbage.
  private static func queryDocument(_ text: String) throws -> BSONDocument? {
    if text.hasPrefix("{") || text.hasPrefix("[") {
      do { return try BSONSupport.document(fromQuery: text) }
      catch {
        throw SQLQueryError.invalidQuery("Invalid query: \(error.localizedDescription)")
      }
    }
    return try? BSONSupport.document(fromQuery: text)
  }

  // MARK: - Filter (WHERE)

  /// ANDs every top-level condition. Returns nil when nothing restricts.
  private static func compileFilter(_ doc: BSONDocument) throws -> String? {
    let parts = try conditionParts(of: doc)
    guard !parts.isEmpty else { return nil }
    return parts.count == 1 ? parts[0] : parts.joined(separator: " AND ")
  }

  /// Compiles one condition object into AND-joined parts. `$or` / `$and`
  /// entries become parenthesized groups; every other key is a column filter.
  private static func conditionParts(of doc: BSONDocument) throws -> [String] {
    var parts: [String] = []
    for (key, value) in doc.all {
      switch key {
      case "$or": parts.append(try group(value, of: key, separator: " OR "))
      case "$and": parts.append(try group(value, of: key, separator: " AND "))
      default: parts.append(contentsOf: try columnCondition(key, value: value))
      }
    }
    return parts
  }

  /// `$or` / `$and`: an array of condition objects joined by `separator`.
  /// The whole group is parenthesized so a top-level AND of siblings keeps
  /// precedence (`(a OR b) AND c`, never `a OR b AND c`). An empty branch
  /// (e.g. `{"a": {"$nin": []}}`) matches everything -> `1 = 1`.
  private static func group(_ value: BSON, of key: String, separator: String) throws -> String {
    guard case .array(let conditions) = value, !conditions.isEmpty else {
      throw SQLQueryError.invalidQuery(
        "\(key) must be a non-empty array of condition objects")
    }
    let branches = try conditions.map { condition -> String in
      guard case .document(let doc) = condition else {
        throw SQLQueryError.invalidQuery("\(key) elements must be condition objects")
      }
      let parts = try conditionParts(of: doc)
      guard !parts.isEmpty else { return "1 = 1" }
      return parts.count == 1 ? parts[0] : "( \(parts.joined(separator: " AND ")) )"
    }
    return "( \(branches.joined(separator: separator)) )"
  }

  /// One `column: value` pair. A plain value is equality (null -> IS NULL); a
  /// `{$op: ...}` object yields one condition per operator, ANDed together.
  private static func columnCondition(_ column: String, value: BSON) throws -> [String] {
    let quoted = quotedIdentifier(column)
    switch value {
    case .null:
      return ["\(quoted) IS NULL"]
    case .document(let operators):
      guard !operators.isEmpty else {
        throw SQLQueryError.invalidQuery("operator object for \"\(column)\" is empty")
      }
      var parts: [String] = []
      for (op, argument) in operators.all {
        switch op {
        case "$eq": parts.append(try compare(quoted, op: "=", to: argument, nullAllowed: true))
        case "$ne": parts.append(try compare(quoted, op: "<>", to: argument, nullAllowed: true))
        case "$gt": parts.append(try compare(quoted, op: ">", to: argument, nullAllowed: false))
        case "$gte": parts.append(try compare(quoted, op: ">=", to: argument, nullAllowed: false))
        case "$lt": parts.append(try compare(quoted, op: "<", to: argument, nullAllowed: false))
        case "$lte": parts.append(try compare(quoted, op: "<=", to: argument, nullAllowed: false))
        case "$in": parts.append(contentsOf: try inList(quoted, argument, negated: false))
        case "$nin": parts.append(contentsOf: try inList(quoted, argument, negated: true))
        case "$exists": parts.append(try existsClause(quoted, argument))
        default:
          if op.hasPrefix("$") {
            throw SQLQueryError.invalidQuery(
              "Unsupported operator \"\(op)\" on \"\(column)\" — supported: "
                + "$eq $ne $gt $gte $lt $lte $in $nin $exists. "
                + "Use a raw SQL fragment for anything else (e.g. LIKE).")
          }
          throw SQLQueryError.invalidQuery(
            "Object value for \"\(column)\" can't map to SQL equality — SQL columns are "
              + "flat; use a raw SQL fragment to query JSON columns")
        }
      }
      return parts
    case .array:
      throw SQLQueryError.invalidQuery(
        "Array value on \"\(column)\" can't map to SQL equality — wrap it in $in")
    default:
      return ["\(quoted) = \(try literal(value, for: column))"]
    }
  }

  /// A comparison against a scalar. `null` only makes sense with $eq/$ne and
  /// becomes SQL's `IS [NOT] NULL` (plain `= NULL` never matches).
  private static func compare(
    _ column: String, op: String, to argument: BSON, nullAllowed: Bool
  ) throws -> String {
    if case .null = argument {
      guard nullAllowed else {
        throw SQLQueryError.invalidQuery(
          "\(op) on \(column) can't compare against null — use $eq/$ne or $exists")
      }
      return op == "=" ? "\(column) IS NULL" : "\(column) IS NOT NULL"
    }
    return "\(column) \(op) \(try literal(argument, for: column))"
  }

  /// `$in` / `$nin` over a scalar list. Empty lists keep Mongo semantics:
  /// `$in: []` matches nothing (`1 = 0`), `$nin: []` matches everything (no
  /// condition emitted).
  private static func inList(_ column: String, _ argument: BSON, negated: Bool) throws -> [String] {
    guard case .array(let values) = argument else {
      throw SQLQueryError.invalidQuery(
        "\((negated ? "$nin" : "$in")) on \(column) needs an array of values")
    }
    if values.isEmpty { return negated ? [] : ["1 = 0"] }
    let rendered = try values.map { element -> String in
      if case .null = element {
        throw SQLQueryError.invalidQuery(
          "null inside \((negated ? "$nin" : "$in")) on \(column) has no SQL equivalent "
            + "— SQL NULL never satisfies IN; use $exists or a raw SQL fragment")
      }
      return try literal(element, for: column)
    }
    return ["\(column) \(negated ? "NOT IN" : "IN") (\(rendered.joined(separator: ", ")))"]
  }

  /// `$exists: true/false` maps to column nullness.
  private static func existsClause(_ column: String, _ argument: BSON) throws -> String {
    guard case .bool(let exists) = argument else {
      throw SQLQueryError.invalidQuery("$exists on \(column) needs true or false")
    }
    return exists ? "\(column) IS NOT NULL" : "\(column) IS NULL"
  }

  // MARK: - Sort (ORDER BY)

  /// Mongo-style sort document: keys in order, directions 1/-1 or
  /// "asc"/"desc". `{}` (or a sort that never restricts) means no ORDER BY.
  private static func compileSort(_ doc: BSONDocument) throws -> String? {
    var terms: [String] = []
    for (key, value) in doc.all {
      let direction: String
      switch value {
      case .int32(1), .int64(1): direction = "ASC"
      case .int32(-1), .int64(-1): direction = "DESC"
      case .string(let word):
        switch word.lowercased() {
        case "asc": direction = "ASC"
        case "desc": direction = "DESC"
        default:
          throw SQLQueryError.invalidQuery(
            "Sort direction \"\(word)\" for \"\(key)\" must be 1/-1 or \"asc\"/\"desc\"")
        }
      default:
        throw SQLQueryError.invalidQuery(
          "Sort value for \"\(key)\" must be 1 or -1 (or \"asc\"/\"desc\")")
      }
      terms.append("\(quotedIdentifier(key)) \(direction)")
    }
    return terms.isEmpty ? nil : terms.joined(separator: ", ")
  }

  // MARK: - Projection (SELECT list)

  /// Include-only projection: `{name: 1, age: 1}` -> `"name", "age"`. An
  /// empty document means the full row (`*`). Exclusion (0) is rejected —
  /// SQL can't express "everything except" without schema metadata.
  private static func compileProjection(_ doc: BSONDocument) throws -> String? {
    guard !doc.isEmpty else { return nil }
    var include: [String] = []
    for (key, value) in doc.all {
      switch value {
      case .int32(1), .int64(1), .bool(true): include.append(quotedIdentifier(key))
      case .int32(0), .int64(0), .bool(false):
        throw SQLQueryError.invalidQuery(
          "Projection \"\(key): 0\" (exclusion) can't map to SQL — list only the columns to include")
      default:
        throw SQLQueryError.invalidQuery("Projection value for \"\(key)\" must be 1 or 0")
      }
    }
    return include.joined(separator: ", ")
  }

  // MARK: - Literals and identifiers

  /// Renders a scalar as an inline SQL literal: strings single-quoted with
  /// embedded quotes doubled, numbers/booleans native. NULL is rejected here —
  /// only $eq/$ne/$exists know what NULL means in SQL.
  private static func literal(_ value: BSON, for column: String) throws -> String {
    switch value {
    case .string(let text):
      guard !text.contains("\0") else {
        throw SQLQueryError.invalidQuery("Value for \"\(column)\" contains a NUL byte")
      }
      return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    case .int32(let number): return String(number)
    case .int64(let number): return String(number)
    case .double(let number):
      guard number.isFinite else {
        throw SQLQueryError.invalidQuery("Non-finite number for \"\(column)\"")
      }
      return String(number)
    case .bool(let flag): return flag ? "TRUE" : "FALSE"
    case .null:
      throw SQLQueryError.invalidQuery(
        "Null for \"\(column)\" must use $eq/$ne (SQL IS [NOT] NULL) or $exists")
    default:
      throw SQLQueryError.invalidQuery(
        "Value type on \"\(column)\" can't be rendered as SQL")
    }
  }

  /// Double-quotes an identifier, doubling embedded quotes (the same rule the
  /// engine facades apply to table names).
  static func quotedIdentifier(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func trimmed(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
