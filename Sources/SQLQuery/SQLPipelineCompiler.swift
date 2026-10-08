import Foundation
import MongoDB

/// The SQL dialect a pipeline compiles for. Only a few spellings differ:
/// OFFSET without LIMIT, numeric casts, and array aggregation.
public enum SQLFlavor: Sendable {
  case postgresql, sqlite
}

/// Compiles a MongoDB aggregation pipeline — the stage documents the
/// aggregation builder produces — into one SQL SELECT for PostgreSQL/SQLite,
/// so SQL tables get the same builder (and the same JavaScript import/export)
/// as MongoDB collections.
///
/// Each stage folds into the SELECT being built while SQL's clause order
/// allows it (`$match` → WHERE, `$group` → GROUP BY, `$sort` → ORDER BY,
/// `$skip`/`$limit` → OFFSET/LIMIT); a stage that must see the previous
/// stages' OUTPUT (a `$match` after `$group`, a `$group` after `$limit`)
/// wraps what came before as a derived table:
///
///     [{ $group: { _id: "$city", n: { $sum: 1 } } }, { $match: { n: { $gt: 1 } } }]
///     SELECT * FROM (SELECT "city" AS "_id", COUNT(*) AS "n" FROM "people"
///       GROUP BY "city") AS "s1" WHERE "n" > 1
///
/// Field paths (`"$city"`) are column references; output columns keep Mongo's
/// names, so a composite group key `_id: { a: "$a" }` yields a column named
/// `_id.a` that later stages reach as `"$_id.a"`.
public enum SQLPipelineCompiler {
  /// The stages that compile to SQL. Anything else (`$lookup`, `$unwind`,
  /// `$facet`, …) has no faithful SQL equivalent on flat rows and throws.
  public static let supportedStages: [String] = [
    "$match", "$group", "$sort", "$project", "$addFields", "$set", "$unset", "$limit", "$skip",
    "$count", "$sortByCount", "$sample",
  ]

  /// The SELECT `stages` describe over `table` (an already-quoted FROM
  /// target, e.g. `"public"."orders"`). An empty pipeline selects every row.
  public static func compile(_ stages: [BSONDocument], from table: String, flavor: SQLFlavor) throws
    -> String
  {
    var compiler = Compiler(flavor: flavor, select: Select(from: table))
    for (index, stage) in stages.enumerated() {
      guard stage.count == 1, let name = stage.keys.first, let argument = stage[name] else {
        throw SQLQueryError.invalidQuery(
          "Stage \(index + 1) must have exactly one $stage key, e.g. { $match: {...} }")
      }
      do {
        try compiler.apply(name, argument)
      } catch SQLQueryError.invalidQuery(let message) {
        throw SQLQueryError.invalidQuery("Stage \(index + 1) (\(name)): \(message)")
      }
    }
    return compiler.select.sql(flavor: flavor)
  }
}

// MARK: - SELECT under construction

/// One SELECT statement. `columns == nil` means `*`; `outputs` lists the
/// output column names when they are known (after `$group`/`$project`/…;
/// never for the base table, whose columns the compiler doesn't see).
private struct Select {
  var from: String
  var columns: [String]?
  var outputs: [String]?
  var wheres: [String] = []
  /// Non-nil once the SELECT aggregates; empty for an aggregate without
  /// GROUP BY (`$count`, `$group` with a constant `_id`).
  var groupBy: [String]?
  var orderBy: String?
  /// Columns `orderBy` refers to (to know if it survives a wrap).
  var orderColumns: [String] = []
  var limit: Int?
  var offset = 0

  /// Nothing but WHERE/ORDER BY yet: row filters can still be added here.
  var isPlain: Bool { columns == nil && groupBy == nil && limit == nil && offset == 0 }

  func sql(flavor: SQLFlavor) -> String {
    var sql = "SELECT \(columns?.joined(separator: ", ") ?? "*")\nFROM \(from)"
    if !wheres.isEmpty { sql += "\nWHERE \(wheres.joined(separator: " AND "))" }
    if let groupBy, !groupBy.isEmpty { sql += "\nGROUP BY \(groupBy.joined(separator: ", "))" }
    if let orderBy { sql += "\nORDER BY \(orderBy)" }
    if let limit { sql += "\nLIMIT \(limit)" }
    if offset > 0 {
      // SQLite has no OFFSET without LIMIT; -1 means "no limit" there.
      if limit == nil, flavor == .sqlite { sql += "\nLIMIT -1" }
      sql += "\nOFFSET \(offset)"
    }
    return sql
  }
}

private struct Compiler {
  let flavor: SQLFlavor
  var select: Select
  private var wrapCount = 0

  init(flavor: SQLFlavor, select: Select) {
    self.flavor = flavor
    self.select = select
  }

  /// Starts a new SELECT over the current one as a derived table. With
  /// `keepingOrder`, a sort the outer query can still see moves outward, so
  /// row-preserving stages ($match/$project/…) don't lose it (SQL guarantees
  /// no order for a derived table's rows).
  mutating func wrap(keepingOrder: Bool) {
    var inner = select
    var outer = Select(from: "")
    outer.outputs = inner.outputs
    // With unknown outputs the inner SELECT is `*` (plus added fields), so
    // every column it sorted by is still visible outside.
    if keepingOrder, let order = inner.orderBy,
      inner.outputs.map({ outputs in inner.orderColumns.allSatisfy(outputs.contains) }) ?? true
    {
      outer.orderBy = order
      outer.orderColumns = inner.orderColumns
    }
    // Without LIMIT/OFFSET the inner order is meaningless; drop the noise.
    if inner.limit == nil && inner.offset == 0 { inner.orderBy = nil }
    wrapCount += 1
    let body = inner.sql(flavor: flavor).split(separator: "\n").map { "  " + $0 }
      .joined(separator: "\n")
    outer.from = "(\n\(body)\n) AS \(quoted("s\(wrapCount)"))"
    select = outer
  }

  mutating func apply(_ name: String, _ argument: BSON) throws {
    switch name {
    case "$match": try match(argument)
    case "$group": try group(argument)
    case "$sort": try sort(argument)
    case "$project": try project(argument)
    case "$addFields", "$set": try addFields(argument)
    case "$unset": try unset(argument)
    case "$limit":
      let n = try count(argument, positive: true)
      select.limit = min(select.limit ?? n, n)
    case "$skip":
      let n = try count(argument, positive: false)
      if let limit = select.limit { select.limit = max(limit - n, 0) }
      select.offset += n
    case "$count": try countStage(argument)
    case "$sortByCount": try sortByCount(argument)
    case "$sample":
      guard case .document(let spec) = argument, let size = spec["size"] else {
        throw invalid("needs { size: <number> }")
      }
      let n = try count(size, positive: true)
      if select.limit != nil || select.offset != 0 { wrap(keepingOrder: false) }
      select.orderBy = "RANDOM()"
      select.orderColumns = []
      select.limit = n
    default:
      throw invalid(
        "\(name) has no SQL equivalent — SQL tables support "
          + SQLPipelineCompiler.supportedStages.joined(separator: " "))
    }
  }

  // MARK: Stages

  mutating func match(_ argument: BSON) throws {
    guard case .document(var filter) = argument else { throw invalid("needs a filter object") }
    if !select.isPlain { wrap(keepingOrder: true) }
    // `$expr` holds an aggregation expression rather than a query; compile it
    // here, the rest is the query bar's filter dialect.
    if let expression = filter["$expr"] {
      filter["$expr"] = nil
      select.wheres.append(try self.expression(expression))
    }
    if let condition = try SQLQueryCompiler.compileFilter(filter) {
      select.wheres.append(condition)
    }
  }

  mutating func sort(_ argument: BSON) throws {
    guard case .document(let spec) = argument, !spec.isEmpty else {
      throw invalid("needs { field: 1 or -1 }")
    }
    if select.limit != nil || select.offset != 0 { wrap(keepingOrder: false) }
    select.orderBy = try SQLQueryCompiler.compileSort(spec)
    select.orderColumns = spec.keys
  }

  mutating func group(_ argument: BSON) throws {
    guard case .document(let spec) = argument, let key = spec["_id"] else {
      throw invalid("needs an _id (the group key, or null for one group)")
    }
    if !select.isPlain { wrap(keepingOrder: false) }
    var columns: [String] = []
    var outputs: [String] = []
    var groupBy: [String] = []
    if case .document(let parts) = key, !parts.isEmpty, !(parts.keys.first ?? "").hasPrefix("$") {
      // Composite key: one column per part, named like Mongo's `_id.part`.
      for (part, value) in parts.all {
        let sql = try expression(value)
        if references(value) { groupBy.append(sql) }
        columns.append("\(sql) AS \(quoted("_id.\(part)"))")
        outputs.append("_id.\(part)")
      }
    } else {
      let sql = try expression(key)
      if references(key) { groupBy.append(sql) }
      columns.append("\(sql) AS \(quoted("_id"))")
      outputs.append("_id")
    }
    for (field, value) in spec.all where field != "_id" {
      guard case .document(let accumulator) = value, accumulator.count == 1,
        let op = accumulator.keys.first, let operand = accumulator[op]
      else { throw invalid("\"\(field)\" must be an accumulator like { $sum: \"$amount\" }") }
      columns.append("\(try self.accumulator(op, operand, field: field)) AS \(quoted(field))")
      outputs.append(field)
    }
    select.columns = columns
    select.outputs = outputs
    select.groupBy = groupBy
    select.orderBy = nil
    select.orderColumns = []
  }

  mutating func project(_ argument: BSON) throws {
    guard case .document(let spec) = argument, !spec.isEmpty else {
      throw invalid("needs { field: 1, … } or { field: 0, … }")
    }
    if select.columns != nil || select.groupBy != nil { wrap(keepingOrder: true) }
    var included: [(name: String, sql: String)] = []
    var excluded: Set<String> = []
    var mentionsID = false
    for (field, value) in spec.all {
      if field == "_id" { mentionsID = true }
      switch value {
      case .bool(false), .int32(0), .int64(0), .double(0): excluded.insert(field)
      case .bool(true), .int32, .int64, .double: included.append((field, quoted(field)))
      default: included.append((field, "\(try expression(value)) AS \(quoted(field))"))
      }
    }
    let excludesOnlyID = excluded == ["_id"]
    if !excluded.isEmpty && !excludesOnlyID {
      guard included.isEmpty else {
        throw invalid("can't mix including and excluding fields (other than _id: 0)")
      }
      guard let outputs = select.outputs else {
        throw invalid(
          "excluding fields needs the column list, which a table doesn't provide here — "
            + "list the columns to keep instead (e.g. { name: 1 })")
      }
      let kept = outputs.filter { !excluded.contains($0) }
      select.columns = kept.map(quoted)
      select.outputs = kept
      return
    }
    // Only `_id: 0` excluded (or nothing): an inclusion projection. `_id` is
    // kept by default, as in Mongo — when the input is known to have one.
    if included.isEmpty {
      if let outputs = select.outputs {
        let kept = outputs.filter { $0 != "_id" }
        select.columns = kept.map(quoted)
        select.outputs = kept
      }
      return
    }
    if !mentionsID, let outputs = select.outputs, outputs.contains("_id") {
      included.insert(("_id", quoted("_id")), at: 0)
    }
    select.columns = included.map(\.sql)
    select.outputs = included.map(\.name)
  }

  mutating func addFields(_ argument: BSON) throws {
    guard case .document(let spec) = argument, !spec.isEmpty else {
      throw invalid("needs { newField: <expression>, … }")
    }
    // New fields may refer to columns this SELECT computes; those only exist
    // one level up.
    if select.columns != nil || select.groupBy != nil { wrap(keepingOrder: true) }
    var added: [(name: String, sql: String)] = []
    for (field, value) in spec.all {
      added.append((field, "\(try expression(value)) AS \(quoted(field))"))
    }
    if let outputs = select.outputs {
      let replaced = Dictionary(added.map { ($0.name, $0.sql) }, uniquingKeysWith: { $1 })
      let fresh = added.filter { !outputs.contains($0.name) }
      select.columns = outputs.map { replaced[$0] ?? quoted($0) } + fresh.map(\.sql)
      select.outputs = outputs + fresh.map(\.name)
    } else {
      select.columns = ["*"] + added.map(\.sql)
    }
  }

  mutating func unset(_ argument: BSON) throws {
    let fields: [String]
    switch argument {
    case .string(let field): fields = [field]
    case .array(let items):
      fields = try items.map {
        guard case .string(let field) = $0 else { throw invalid("needs field names") }
        return field
      }
    default: throw invalid("needs a field name or an array of field names")
    }
    var spec = BSONDocument()
    for field in fields { spec[field] = .int32(0) }
    try project(.document(spec))
  }

  mutating func countStage(_ argument: BSON) throws {
    guard case .string(let name) = argument, !name.isEmpty, !name.hasPrefix("$"),
      !name.contains(".")
    else { throw invalid("needs an output field name, e.g. \"count\"") }
    if !select.isPlain { wrap(keepingOrder: false) }
    select.columns = ["COUNT(*) AS \(quoted(name))"]
    select.outputs = [name]
    select.groupBy = []
    select.orderBy = nil
    select.orderColumns = []
  }

  mutating func sortByCount(_ argument: BSON) throws {
    let sql = try expression(argument)
    if !select.isPlain { wrap(keepingOrder: false) }
    select.columns = ["\(sql) AS \(quoted("_id"))", "COUNT(*) AS \(quoted("count"))"]
    select.outputs = ["_id", "count"]
    select.groupBy = references(argument) ? [sql] : []
    select.orderBy = "\(quoted("count")) DESC"
    select.orderColumns = ["count"]
  }

  // MARK: Accumulators

  func accumulator(_ op: String, _ operand: BSON, field: String) throws -> String {
    switch op {
    case "$sum":
      // `$sum: 1` is Mongo's count idiom (any number n sums n per row); a
      // sum over no numbers is 0, not NULL.
      switch operand {
      case .int32(1), .int64(1): return "COUNT(*)"
      case .int32, .int64, .double:
        return "(COUNT(*) * \(try expression(operand)))"
      default:
        return "COALESCE(SUM(\(try expression(operand))), 0)"
      }
    case "$avg": return "AVG(\(try expression(operand)))"
    case "$min": return "MIN(\(try expression(operand)))"
    case "$max": return "MAX(\(try expression(operand)))"
    case "$count": return "COUNT(*)"
    case "$push", "$addToSet":
      let distinct = op == "$addToSet" ? "DISTINCT " : ""
      let sql = try expression(operand)
      return flavor == .postgresql ? "array_agg(\(distinct)\(sql))" : "json_group_array(\(distinct)\(sql))"
    default:
      throw invalid(
        "accumulator \(op) on \"\(field)\" isn't supported for SQL — "
          + "use $sum $avg $min $max $count $push $addToSet")
    }
  }

  // MARK: Expressions

  /// An aggregation expression as SQL: `"$field"` is a column, other scalars
  /// are literals, `{ $op: … }` is an operator.
  func expression(_ value: BSON) throws -> String {
    switch value {
    case .string(let text) where text.hasPrefix("$$"):
      throw invalid("variables like \(text) aren't supported for SQL")
    case .string(let text) where text.hasPrefix("$"):
      return quoted(String(text.dropFirst()))
    case .null:
      return "NULL"
    case .document(let operation):
      guard operation.count == 1, let op = operation.keys.first, op.hasPrefix("$"),
        let operand = operation[op]
      else { throw invalid("object values can't be SQL expressions — use { $operator: … }") }
      return try self.operation(op, operand)
    case .array:
      throw invalid("arrays can't be SQL values")
    default:
      return try SQLQueryCompiler.literal(value, for: "expression")
    }
  }

  private func operation(_ op: String, _ operand: BSON) throws -> String {
    /// Operands as SQL, checking the count Mongo requires.
    func args(_ count: ClosedRange<Int>) throws -> [String] {
      let values: [BSON]
      if case .array(let items) = operand { values = items } else { values = [operand] }
      guard count.contains(values.count) else {
        throw invalid("\(op) has the wrong number of arguments (\(values.count))")
      }
      return try values.map(expression)
    }
    let many = 1...Int.max
    switch op {
    case "$add": return "(\(try args(many).joined(separator: " + ")))"
    case "$subtract": return "(\(try args(2...2).joined(separator: " - ")))"
    case "$multiply": return "(\(try args(many).joined(separator: " * ")))"
    case "$divide":
      // Mongo always divides as floating point; SQL divides integers as integers.
      let a = try args(2...2)
      return "(\(a[0]) * 1.0 / \(a[1]))"
    case "$mod": return "(\(try args(2...2).joined(separator: " % ")))"
    case "$abs": return "ABS(\(try args(1...1)[0]))"
    case "$round":
      let a = try args(1...2)
      let places = a.count == 2 ? a[1] : "0"
      return flavor == .postgresql
        ? "ROUND(CAST(\(a[0]) AS NUMERIC), \(places))" : "ROUND(\(a[0]), \(places))"
    case "$concat": return "(\(try args(many).joined(separator: " || ")))"
    case "$toUpper": return "UPPER(\(try args(1...1)[0]))"
    case "$toLower": return "LOWER(\(try args(1...1)[0]))"
    case "$strLenCP", "$strLenBytes": return "LENGTH(\(try args(1...1)[0]))"
    case "$substr", "$substrCP", "$substrBytes":
      let a = try args(3...3)
      return "SUBSTR(\(a[0]), (\(a[1])) + 1, \(a[2]))"
    case "$ifNull": return "COALESCE(\(try args(2...Int.max).joined(separator: ", ")))"
    case "$eq": return "(\(try args(2...2).joined(separator: " = ")))"
    case "$ne": return "(\(try args(2...2).joined(separator: " <> ")))"
    case "$gt": return "(\(try args(2...2).joined(separator: " > ")))"
    case "$gte": return "(\(try args(2...2).joined(separator: " >= ")))"
    case "$lt": return "(\(try args(2...2).joined(separator: " < ")))"
    case "$lte": return "(\(try args(2...2).joined(separator: " <= ")))"
    case "$and": return "(\(try args(many).joined(separator: " AND ")))"
    case "$or": return "(\(try args(many).joined(separator: " OR ")))"
    case "$not": return "(NOT \(try args(1...1)[0]))"
    case "$cond":
      let parts: [String]
      if case .document(let spec) = operand {
        guard let condition = spec["if"], let then = spec["then"], let otherwise = spec["else"] else {
          throw invalid("$cond needs if, then and else")
        }
        parts = try [condition, then, otherwise].map(expression)
      } else {
        parts = try args(3...3)
      }
      return "CASE WHEN \(parts[0]) THEN \(parts[1]) ELSE \(parts[2]) END"
    case "$literal": return try SQLQueryCompiler.literal(operand, for: "$literal")
    case "$toString": return "CAST(\(try args(1...1)[0]) AS TEXT)"
    case "$toInt", "$toLong": return "CAST(\(try args(1...1)[0]) AS INTEGER)"
    case "$toDouble":
      return "CAST(\(try args(1...1)[0]) AS \(flavor == .postgresql ? "DOUBLE PRECISION" : "REAL"))"
    default:
      throw invalid("expression operator \(op) isn't supported for SQL")
    }
  }

  // MARK: Helpers

  /// True when the expression reads a column (so it varies per row).
  func references(_ value: BSON) -> Bool {
    switch value {
    case .string(let text): return text.hasPrefix("$")
    case .document(let document): return document.values.contains(where: references)
    case .array(let items): return items.contains(where: references)
    default: return false
    }
  }

  /// `$limit`/`$skip`/`$sample` sizes.
  func count(_ value: BSON, positive: Bool) throws -> Int {
    let number: Int?
    switch value {
    case .int32(let n): number = Int(n)
    case .int64(let n): number = Int(exactly: n)
    case .double(let d): number = Int(exactly: d)
    default: number = nil
    }
    guard let number, positive ? number > 0 : number >= 0 else {
      throw invalid(positive ? "needs a positive whole number" : "needs a whole number ≥ 0")
    }
    return number
  }

  func quoted(_ name: String) -> String { SQLQueryCompiler.quotedIdentifier(name) }

  func invalid(_ message: String) -> SQLQueryError { .invalidQuery(message) }
}
