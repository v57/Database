import Foundation

/// Inferred value type of a field, driving which operators the filter builder
/// offers and how typed text becomes a BSON value.
public enum FieldKind: Equatable, Sendable {
  case string
  case number
  case boolean
  case date
  case objectID
  case container
  /// A scalar kind we don't special-case (binary, regex, decimal, …).
  case scalar
  /// Only null/undefined seen so far.
  case empty
  /// Several incompatible kinds across the loaded documents.
  case mixed

  public var label: String {
    switch self {
    case .string: return "Text"
    case .number: return "Number"
    case .boolean: return "Boolean"
    case .date: return "Date"
    case .objectID: return "ObjectId"
    case .container: return "Document/Array"
    case .scalar: return "Value"
    case .empty: return "Null"
    case .mixed: return "Mixed"
    }
  }

  /// SF Symbol for field pickers (names verified against the installed set).
  public var symbol: String {
    switch self {
    case .string: return "textformat"
    case .number: return "function"
    case .boolean: return "checkmark.square"
    case .date: return "calendar"
    case .objectID: return "key.horizontal"
    case .container: return "curlybraces"
    case .scalar: return "asterisk"
    case .empty: return "questionmark.square"
    case .mixed: return "asterisk"
    }
  }
}

/// Operator set of the UI filter builder. Every operator renders into query
/// text the existing pipeline already understands:
///   * Mongo: filter documents, `$gt`-style comparisons and `$regex` text matches.
///   * SQL: the same document dialect; the text operators `$contains`,
///     `$notContains`, `$startsWith`, `$endsWith` are compiled to LIKE by
///     SQLQueryCompiler (Sources/SQLQuery/SQLQueryCompiler.swift).
public enum FilterOp: String, CaseIterable, Identifiable, Sendable {
  case equal, notEqual, lessThan, lessOrEqual, greaterThan, greaterOrEqual
  case contains, notContains, startsWith, endsWith
  case inList, notInList, isEmpty, isNotEmpty
  /// Verbatim fragment typed in a column's "Search…" box (`15`, `{ "$gt": 15 }`).
  /// The renderer writes it into the query text untouched, so every operator the
  /// query bar understands is reachable from the UI without a new enum case.
  case custom

  public var id: String { rawValue }

  /// Picker/menu label; also used to build the chip summary.
  public var label: String {
    switch self {
    case .equal: return "is"
    case .notEqual: return "is not"
    case .lessThan: return "is less than"
    case .lessOrEqual: return "is at most"
    case .greaterThan: return "is more than"
    case .greaterOrEqual: return "is at least"
    case .contains: return "contains"
    case .notContains: return "does not contain"
    case .startsWith: return "starts with"
    case .endsWith: return "ends with"
    case .inList: return "is any of"
    case .notInList: return "is none of"
    case .isEmpty: return "is empty"
    case .isNotEmpty: return "is not empty"
    case .custom: return "matches"
    }
  }

  /// SF Symbol for the operator picker (house rule: pickers carry symbols).
  /// Names verified against the installed SF Symbols list.
  public var symbol: String {
    switch self {
    case .equal: return "equal"
    case .notEqual: return "notequal"
    case .lessThan: return "lessthan"
    case .lessOrEqual: return "lessthanorequalto"
    case .greaterThan: return "greaterthan"
    case .greaterOrEqual: return "greaterthanorequalto"
    case .contains, .notContains: return "text.magnifyingglass"
    case .startsWith, .endsWith: return "textformat"
    case .inList, .notInList: return "list.bullet"
    case .isEmpty: return "questionmark.square"
    case .isNotEmpty: return "checkmark.square"
    case .custom: return "text.magnifyingglass"
    }
  }

  /// `isEmpty`/`isNotEmpty` carry no value; everything else does.
  public var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }

  /// `inList`/`notInList` take a list of values (`$in` / `$nin`).
  public var takesList: Bool { self == .inList || self == .notInList }
}

/// One row of the UI filter builder. Rules are ANDed in order. `value` is
/// ignored by the value-less operators and is `.array([...])` for list ops.
public struct FilterRule: Equatable, Identifiable, Sendable {
  public var id: UUID
  public var field: String
  public var op: FilterOp
  public var value: BSON

  public init(id: UUID = UUID(), field: String, op: FilterOp = .equal, value: BSON = .null) {
    self.id = id
    self.field = field
    self.op = op
    self.value = value
  }

  /// Chip text, e.g. `age is more than 30` / `tags is any of [a, b]`. A rule on
  /// a `$`-prefixed marker field (the "search all text fields" chip) reads as
  /// `any text field ...` instead of leaking the marker into the UI.
  public var summary: String {
    let name = field.hasPrefix("$") ? "any text field" : field
    return op.needsValue ? "\(name) \(op.label) \(FilterText.display(value))"
      : "\(name) \(op.label)"
  }
}

/// Which flavour of query text a rule set renders to. `mongo` and `sql` consume
/// the same document dialect; only the text-matching operators differ.
public enum FilterDialect: Sendable { case mongo, sql }

/// Renders UI rules into the query-bar dialect that `QuerySpec` carries, plus
/// the small helpers the UI needs (chip text, sort text, typed value coercion).
public enum FilterText {

  /// Query text for `rules`, or nil when nothing restricts the result set.
  /// A rule is dropped when its field is blank, when a list op has no values,
  /// or when a text-match operator has empty text ("contains ''" = match all).
  public static func render(_ rules: [FilterRule], dialect: FilterDialect) -> String? {
    let parts = rules.compactMap { condition($0, dialect: dialect) }
    guard !parts.isEmpty else { return nil }
    return "{ " + parts.joined(separator: ", ") + " }"
  }

  /// Sort text for one field, same dialect as the filter (Mongo sort documents
  /// compile to ORDER BY in SQLQueryCompiler). NOTE: the multi-key, dialect-aware
  /// version used by the column UI lives in `SortText.render` — this single-key
  /// helper is only for callers that have nothing else to sort by.
  public static func sort(_ field: String, ascending: Bool) -> String {
    "{ \(quotedKey(field)): \(ascending ? 1 : -1) }"
  }

  /// One-line rendering of a value for chips and suggestion rows.
  public static func display(_ value: BSON) -> String {
    switch value {
    case .array(let items): return "[" + items.map(display).joined(separator: ", ") + "]"
    default: return BSONSupport.displayString(value)
    }
  }

  /// Turns what the user typed into a BSON value using the field's inferred
  /// kind, so `30` is a number on a numeric field but the text "30" on a text
  /// field. Dates are typed for Mongo (real BSON dates) and left as text for
  /// SQL (SQLQueryCompiler renders scalars only; SQLite stores dates as TEXT
  /// and PostgreSQL needs an explicit cast anyway).
  public static func value(fromText text: String, kind: FieldKind, dialect: FilterDialect) -> BSON {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch kind {
    case .number:
      if let int = Int64(trimmed) { return .int64(int) }
      if let double = Double(trimmed) { return .double(double) }
      return .string(trimmed)
    case .boolean:
      switch trimmed.lowercased() {
      case "true", "1", "yes": return .bool(true)
      case "false", "0", "no": return .bool(false)
      default: return .string(trimmed)
      }
    case .date:
      guard dialect == .mongo else { return .string(trimmed) }
      if let date = ISO8601DateFormatter().date(from: trimmed) { return .datetime(date) }
      return .string(trimmed)
    default:
      return .string(trimmed)
    }
  }

  /// Validates a column "Search…" fragment (`15`, `"ann"`, `{ "$gt": 15 }`,
  /// `[1, 2]`) by asking the SAME parser the query bar uses, so a typo like
  /// `gt 15` is reported inline instead of breaking the query text. Throws the
  /// parser's own error (it carries a column number).
  public static func validate(fragment: String, for field: String) throws {
    _ = try BSONSupport.document(fromQuery: "{ \(quotedKey(field)): \(fragment) }")
  }

  // MARK: - One rule -> one condition

  /// One `key: { ... }` fragment, or nil when the rule restricts nothing.
  static func condition(_ rule: FilterRule, dialect: FilterDialect) -> String? {
    let field = rule.field.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !field.isEmpty else { return nil }
    let key = quotedKey(field)
    let literal = rule.value.jsonString

    switch rule.op {
    case .equal:
      return "\(key): \(literal)"
    case .notEqual:
      return "\(key): { \"$ne\": \(literal) }"
    case .lessThan:
      return "\(key): { \"$lt\": \(literal) }"
    case .lessOrEqual:
      return "\(key): { \"$lte\": \(literal) }"
    case .greaterThan:
      return "\(key): { \"$gt\": \(literal) }"
    case .greaterOrEqual:
      return "\(key): { \"$gte\": \(literal) }"
    case .inList, .notInList:
      guard case .array(let values) = rule.value, !values.isEmpty else { return nil }
      let op = rule.op == .inList ? "$in" : "$nin"
      let list = values.map(\.jsonString).joined(separator: ", ")
      return "\(key): { \"\(op)\": [\(list)] }"
    case .isEmpty:
      // Mongo: null matches null-or-missing. SQL: IS NULL. Same text for both.
      return "\(key): null"
    case .isNotEmpty:
      // Mongo: field exists and is not null. SQL: IS NOT NULL (=$exists true).
      return dialect == .mongo
        ? "\(key): { \"$ne\": null }"
        : "\(key): { \"$exists\": true }"
    case .contains, .notContains, .startsWith, .endsWith:
      guard case .string(let text) = rule.value, !text.isEmpty else { return nil }
      return dialect == .mongo
        ? "\(key): { \(mongoRegexCondition(rule.op, text)) }"
        : "\(key): { \"\(sqlLikeOperator(rule.op))\": \(BSON.string(text).jsonString) }"
    case .custom:
      // Verbatim fragment from a column's "Search…" box: a bare value (`15`) or
      // an operator object (`{ "$gt": 15 }`). The UI validates it with
      // `FilterText.validate(fragment:for:)` before it becomes a rule, so the
      // query bar only ever sees text the QueryParser accepts.
      guard case .string(let fragment) = rule.value else { return nil }
      let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return "\(key): \(trimmed)"
    }
  }

  /// Mongo text match. `$not` wraps `$regex` for the negative form; the pattern
  /// is anchored for starts/ends with and regex-escaped so user text is literal.
  static func mongoRegexCondition(_ op: FilterOp, _ text: String) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: text)
    let pattern: String
    switch op {
    case .startsWith: pattern = "^" + escaped
    case .endsWith: pattern = escaped + "$"
    default: pattern = escaped
    }
    let regex = "\"$regex\": \(BSON.string(pattern).jsonString)"
    return op == .notContains ? "\"$not\": { \(regex) }" : regex
  }

  /// The LIKE operators SQLQueryCompiler understands by name.
  static func sqlLikeOperator(_ op: FilterOp) -> String {
    switch op {
    case .notContains: return "$notContains"
    case .startsWith: return "$startsWith"
    case .endsWith: return "$endsWith"
    default: return "$contains"
    }
  }

  /// Bare keys (letters/digits/`_`/`$`/`.`) stay unquoted, exactly like
  /// QueryParser's bare-key rule; anything else is double-quoted with JSON
  /// escaping so a field named `first name` still round-trips.
  static func quotedKey(_ field: String) -> String {
    let isBare =
      !field.isEmpty
      && field.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "." }
    return isBare ? field : "\"" + field.escapedJSON + "\""
  }
}
