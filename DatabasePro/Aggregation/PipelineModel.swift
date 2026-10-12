import DatabaseCore
import Foundation
import Observation
import SwiftUI

/// The aggregation pipeline behind Aggregate mode.
@Observable @MainActor
final class PipelineModel {
  @ObservationIgnored unowned let browser: BrowserModel
  var steps: [PipelineStep] = []
  var selectedID: UUID?
  var showsCode = false
  /// Full MongoDB builder (step library, settings) instead of the simple list.
  var showsFullBuilder = false

  // Output of the selected step.
  private(set) var preview: [BSONDocument] = []
  private(set) var previewRows: (fields: [FieldInfo], rows: [[CellValue]])?
  private(set) var previewCount: Int?
  private(set) var previewElapsed: TimeInterval?
  private(set) var previewError: String?
  private(set) var isPreviewing = false
  /// Documents reaching each step, by step id.
  private(set) var counts: [UUID: Int] = [:]

  // Full-run results.
  private(set) var results: [BSONDocument]?
  private(set) var resultRows: (fields: [FieldInfo], rows: [[CellValue]])?
  private(set) var resultError: String?

  // Settings (MongoDB aggregate options).
  var allowDiskUse = false
  var maxTimeSeconds = 30
  var collationLocale = ""
  var caseInsensitive = false
  var batchSize = 100
  var comment = ""

  init(browser: BrowserModel) {
    self.browser = browser
  }

  var isSQL: Bool { browser.engine.family == .sql }
  var selectedIndex: Int? { steps.firstIndex { $0.id == selectedID } }
  var selectedStep: PipelineStep? { selectedIndex.map { steps[$0] } }

  // MARK: Editing steps

  func add(_ kind: StepKind, at index: Int? = nil) {
    let field = browser.fields.first { !$0.isPrimaryKey }?.name ?? browser.fields.first?.name
    var step = PipelineStep(kind: kind, form: defaultForm(kind, field: field), text: kind.template(field: field))
    if kind.writes { step.isEnabled = false }
    if let form = step.form { step.text = Self.text(of: compile(form, kind: kind)) }
    if let index, index <= steps.count {
      steps.insert(step, at: index)
    } else {
      steps.append(step)
    }
    selectedID = step.id
    Task { await refreshPreview() }
  }

  func defaultForm(_ kind: StepKind, field: String?) -> StepForm? {
    let f = field ?? "field"
    switch kind {
    case .match: return .filter([StepCondition(field: f, op: .equals, value: "")])
    case .group: return .group(by: [f], outputs: [GroupOutput(name: "count", function: .count, field: "")])
    case .sort: return .sort([SortKey(field: f, ascending: true)])
    case .limit: return .limit(10)
    case .skip: return .skip(10)
    case .project: return .pick(fields: [f], exclude: false)
    case .set: return .addFields([FieldFormula(name: "newField", kind: .copy, field: f)])
    case .unwind: return .unwind(path: f, keepEmpty: false)
    case .lookup: return .lookup(from: "", localField: f, foreignField: "_id", as: "joined")
    case .count: return .count("count")
    default: return nil
    }
  }

  func update(_ id: UUID, _ change: (inout PipelineStep) -> Void) {
    guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
    change(&steps[index])
    if let form = steps[index].form { steps[index].text = Self.text(of: compile(form, kind: steps[index].kind)) }
    scheduleRefresh()
  }

  /// Text edits switch a step to text mode.
  func setText(_ id: UUID, _ text: String) {
    guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
    steps[index].text = text
    steps[index].form = nil
    scheduleRefresh()
  }

  func remove(_ id: UUID) {
    steps.removeAll { $0.id == id }
    if selectedID == id { selectedID = steps.last?.id }
    scheduleRefresh()
  }

  func duplicate(_ id: UUID) {
    guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
    var copy = steps[index]
    copy.id = UUID()
    steps.insert(copy, at: index + 1)
    selectedID = copy.id
    scheduleRefresh()
  }

  func move(_ id: UUID, by offset: Int) {
    guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
    let target = index + offset
    guard steps.indices.contains(target) else { return }
    steps.swapAt(index, target)
    scheduleRefresh()
  }

  func move(fromOffsets source: IndexSet, toOffset destination: Int) {
    steps.move(fromOffsets: source, toOffset: destination)
    scheduleRefresh()
  }

  func select(_ id: UUID) {
    selectedID = id
    Task { await refreshPreview() }
  }

  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  /// Waits for typing to pause before re-running the preview.
  func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      await refreshPreview()
    }
  }

  // MARK: Compiling

  static func text(of stage: BSON?) -> String { stage?.text(.shell) ?? "" }

  /// A step's stage body (what goes after "$kind:").
  func body(of step: PipelineStep) throws -> BSON {
    if let form = step.form, let compiled = compile(form, kind: step.kind) { return compiled }
    do {
      return try BSON(parsing: step.text)
    } catch {
      throw InputError("\(step.kind.name): \(error.localizedDescription)")
    }
  }

  func stage(of step: PipelineStep) throws -> BSONDocument {
    [step.kind.op: try body(of: step)]
  }

  /// Enabled stages, up to and including `index` when given.
  func stages(upTo index: Int? = nil) throws -> [BSONDocument] {
    let slice = index.map { Array(steps.prefix($0 + 1)) } ?? steps
    return try slice.filter(\.isEnabled).map(stage)
  }

  func filterValue(_ text: String, field: String) -> BSON {
    let category = browser.category(of: field)
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    switch category {
    case .integer: if let i = Int64(trimmed) { return Int32(exactly: i).map(BSON.int32) ?? .int64(i) }
    case .float, .decimal: if let d = Double(trimmed) { return .double(d) }
    case .boolean: if ["true", "false"].contains(trimmed.lowercased()) { return .bool(trimmed.lowercased() == "true") }
    case .dateTime, .date: if let ms = BSONParser.parseISODate(trimmed) { return .datetime(ms) }
    default: break
    }
    if let id = ObjectID(trimmed), field == "_id" || field.hasSuffix("_id") { return .objectId(id) }
    if let i = Int32(trimmed), category == .other { return .int32(i) }
    return .string(text)
  }

  func compile(_ form: StepForm, kind: StepKind) -> BSON? {
    switch form {
    case .filter(let conditions):
      var doc = BSONDocument()
      for c in conditions where !c.field.isEmpty {
        let value = filterValue(c.value, field: c.field)
        let escaped = NSRegularExpression.escapedPattern(for: c.value)
        let condition: BSON =
          switch c.op {
          case .equals: value
          case .notEquals: .document(["$ne": value])
          case .contains: .regex(pattern: escaped, options: "i")
          case .notContains: .document(["$not": .regex(pattern: escaped, options: "i")])
          case .startsWith: .regex(pattern: "^" + escaped, options: "i")
          case .endsWith: .regex(pattern: escaped + "$", options: "i")
          case .greater: .document(["$gt": value])
          case .greaterOrEqual: .document(["$gte": value])
          case .less: .document(["$lt": value])
          case .lessOrEqual: .document(["$lte": value])
          case .isEmpty: .document(["$in": .array([.null, .string("")])])
          case .isNotEmpty: .document(["$nin": .array([.null, .string("")])])
          case .inLastDays:
            .document(["$gte": .date(Date().addingTimeInterval(-Double(Int(c.value) ?? 7) * 86400))])
          }
        if case .document(var existing)? = doc[c.field], case .document(let more) = condition {
          for (k, v) in more { existing[k] = v }
          doc[c.field] = .document(existing)
        } else {
          doc[c.field] = condition
        }
      }
      return .document(doc)
    case .group(let by, let outputs):
      var doc = BSONDocument()
      let keys = by.filter { !$0.isEmpty }
      switch keys.count {
      case 0: doc["_id"] = .null
      case 1: doc["_id"] = .string("$" + keys[0])
      default: doc["_id"] = .document(BSONDocument(keys.map { ($0.replacingOccurrences(of: ".", with: "_"), .string("$" + $0)) }))
      }
      for output in outputs where !output.name.isEmpty {
        let operand: BSON = output.function == .count ? .document([:]) : .string("$" + output.field)
        doc[output.name] = .document(["$" + output.function.rawValue: operand])
      }
      return .document(doc)
    case .sort(let keys):
      return .document(BSONDocument(keys.filter { !$0.field.isEmpty }.map { ($0.field, .int32($0.ascending ? 1 : -1)) }))
    case .limit(let n), .skip(let n): return .int64(Int64(n))
    case .pick(let fields, let exclude):
      return .document(BSONDocument(fields.filter { !$0.isEmpty }.map { ($0, .int32(exclude ? 0 : 1)) }))
    case .addFields(let formulas):
      var doc = BSONDocument()
      for f in formulas where !f.name.isEmpty { doc[f.name] = expression(f) }
      return .document(doc)
    case .unwind(let path, let keepEmpty):
      return keepEmpty
        ? .document(["path": .string("$" + path), "preserveNullAndEmptyArrays": .bool(true)]) : .string("$" + path)
    case .lookup(let from, let local, let foreign, let alias):
      return .document([
        "from": .string(from), "localField": .string(local), "foreignField": .string(foreign), "as": .string(alias),
      ])
    case .count(let name): return .string(name)
    }
  }

  func expression(_ f: FieldFormula) -> BSON {
    switch f.kind {
    case .copy: return .string("$" + f.field)
    case .roundDate:
      var args: BSONDocument = ["date": .string("$" + f.field), "unit": .string(f.unit)]
      if !f.timezone.isEmpty { args["timezone"] = .string(f.timezone) }
      return .document(["$dateTrunc": .document(args)])
    case .condition:
      let ops: [FilterOp: String] = [
        .equals: "$eq", .notEquals: "$ne", .greater: "$gt", .greaterOrEqual: "$gte", .less: "$lt", .lessOrEqual: "$lte",
      ]
      let test = BSON.document([(ops[f.compare] ?? "$eq"): .array([.string("$" + f.field), filterValue(f.compareValue, field: f.field)])])
      return .document([
        "$cond": .document([
          "if": test, "then": (try? BSON(parsing: f.thenValue)) ?? .string(f.thenValue),
          "else": (try? BSON(parsing: f.elseValue)) ?? .string(f.elseValue),
        ])
      ])
    case .concat: return .document(["$concat": .array([.string("$" + f.field), .string(" "), .string("$" + f.otherField)])])
    case .math:
      let other: BSON = Double(f.otherField).map { .double($0) } ?? .string("$" + f.otherField)
      return .document([f.mathOp: .array([.string("$" + f.field), other])])
    case .size: return .document(["$size": .string("$" + f.field)])
    case .raw: return (try? BSON(parsing: f.raw)) ?? .string(f.raw)
    }
  }

  /// "keep reviews where rating is at least 4".
  func summary(_ step: PipelineStep) -> String {
    guard let form = step.form else { return step.kind.does.lowercased() }
    switch form {
    case .filter(let conditions):
      let parts = conditions.filter { !$0.field.isEmpty }.map {
        Filter(field: $0.field, op: $0.op, value: $0.value).summary(category: browser.category(of: $0.field))
          .trimmingCharacters(in: .whitespaces)
      }
      return "keep \(browser.ref.name) where " + (parts.isEmpty ? "…" : parts.joined(separator: " and "))
    case .group(let by, let outputs):
      let what = outputs.map(\.name).joined(separator: ", ")
      return "combine by \(by.filter { !$0.isEmpty }.joined(separator: ", ").ifEmpty("everything"))" + (what.isEmpty ? "" : " → \(what)")
    case .sort(let keys):
      return keys.map { "\($0.field) \($0.ascending ? "lowest first" : "highest first")" }.joined(separator: ", then ")
    case .limit(let n): return "keep the first \(n)"
    case .skip(let n): return "skip the first \(n)"
    case .pick(let fields, let exclude): return (exclude ? "hide " : "only ") + fields.joined(separator: ", ")
    case .addFields(let formulas): return formulas.map(\.name).joined(separator: " and ")
    case .unwind(let path, _): return "one document per item of \(path)"
    case .lookup(let from, _, _, let alias): return "add the matching \(from.isEmpty ? "documents" : from) as \(alias)"
    case .count(let name): return "count as \(name)"
    }
  }

  // MARK: SQL

  /// Compiles the enabled steps into one SELECT (SQL tables only).
  func sql(upTo index: Int? = nil) throws -> String {
    let dialect = SQLBuilderDialect(engine: browser.engine)
    let table = dialect.qualified(browser.ref)
    let slice = (index.map { Array(steps.prefix($0 + 1)) } ?? steps).filter(\.isEnabled)
    var source = table
    var depth = 0
    var select = "*"
    var whereParts: [String] = []
    var groupBy: [String] = []
    var order: [String] = []
    var limit: Int?
    var offset: Int?
    func wrap() {
      // Steps after a GROUP or LIMIT apply to its result.
      var inner = "SELECT \(select) FROM \(source)"
      if !whereParts.isEmpty { inner += " WHERE " + whereParts.joined(separator: " AND ") }
      if !groupBy.isEmpty { inner += " GROUP BY " + groupBy.joined(separator: ", ") }
      if !order.isEmpty { inner += " ORDER BY " + order.joined(separator: ", ") }
      inner += dialect.page(limit: limit, offset: offset, ordered: !order.isEmpty)
      depth += 1
      source = "(\(inner)) AS step\(depth)"
      select = "*"
      whereParts = []
      groupBy = []
      order = []
      limit = nil
      offset = nil
    }
    for step in slice {
      guard StepKind.sqlCompatible.contains(step.kind), let form = step.form else {
        throw InputError("\(step.kind.name) can't run on a SQL table. Use Filter, Group, Sort, Limit, Skip, Pick Fields or Count.")
      }
      switch form {
      case .filter(let conditions):
        if !groupBy.isEmpty || limit != nil || offset != nil { wrap() }
        for c in conditions where !c.field.isEmpty { whereParts.append(dialect.condition(c, category: browser.category(of: c.field))) }
      case .group(let by, let outputs):
        if !groupBy.isEmpty || limit != nil || offset != nil || select != "*" { wrap() }
        let keys = by.filter { !$0.isEmpty }
        groupBy = keys.map(dialect.quote)
        var columns = groupBy
        for output in outputs {
          guard let function = output.function.sql else {
            throw InputError("“\(output.function.label)” isn't available on SQL tables.")
          }
          let argument = output.function == .count ? "*" : dialect.quote(output.field)
          columns.append("\(function)(\(argument)) AS \(dialect.quote(output.name))")
        }
        select = columns.joined(separator: ", ")
      case .sort(let keys):
        if limit != nil || offset != nil { wrap() }
        order = keys.filter { !$0.field.isEmpty }.map { "\(dialect.quote($0.field)) \($0.ascending ? "ASC" : "DESC")" }
      case .limit(let n):
        if limit != nil { wrap() }
        limit = n
      case .skip(let n):
        if limit != nil || offset != nil { wrap() }
        offset = n
      case .pick(let fields, let exclude):
        if exclude { throw InputError("Hiding fields isn't available on SQL tables; pick the ones to keep.") }
        if !groupBy.isEmpty || select != "*" { wrap() }
        select = fields.filter { !$0.isEmpty }.map(dialect.quote).joined(separator: ", ").ifEmpty("*")
      case .count(let name):
        wrap()
        select = "COUNT(*) AS \(dialect.quote(name))"
      default:
        throw InputError("\(step.kind.name) can't run on a SQL table.")
      }
    }
    var sql = "SELECT \(select) FROM \(source)"
    if !whereParts.isEmpty { sql += " WHERE " + whereParts.joined(separator: " AND ") }
    if !groupBy.isEmpty { sql += " GROUP BY " + groupBy.joined(separator: ", ") }
    if !order.isEmpty { sql += " ORDER BY " + order.joined(separator: ", ") }
    sql += dialect.page(limit: limit, offset: offset, ordered: !order.isEmpty)
    return sql
  }

  // MARK: Running

  var options: BSONDocument {
    var doc = BSONDocument()
    if allowDiskUse { doc["allowDiskUse"] = .bool(true) }
    if maxTimeSeconds > 0 { doc["maxTimeMS"] = .int64(Int64(maxTimeSeconds) * 1000) }
    if !collationLocale.isEmpty {
      doc["collation"] = .document(["locale": .string(collationLocale), "strength": .int32(caseInsensitive ? 2 : 3)])
    }
    if !comment.isEmpty { doc["comment"] = .string(comment) }
    return doc
  }

  /// Output of the selected step (or the whole pipeline when none is selected).
  func refreshPreview() async {
    guard let session = browser.session else { return }
    isPreviewing = true
    defer { isPreviewing = false }
    do {
      let index = selectedIndex ?? (steps.isEmpty ? nil : steps.count - 1)
      if isSQL {
        let sql = try sql(upTo: index)
        let (runs, elapsed) = try await timedRun { try await session.run(sql, context: self.browser.queryContext) }
        if case .table(let fields, let rows, _)? = runs.last?.outputs.first {
          previewRows = (fields, Array(rows.prefix(20)))
          previewCount = rows.count
        }
        previewElapsed = elapsed
      } else if let mongo = session as? DocumentAggregating {
        let stages = try stages(upTo: index).filter { $0.keys.first != "$out" && $0.keys.first != "$merge" }
        let result = try await mongo.aggregate(browser.ref, stages: stages, limit: 20)
        preview = result.documents
        previewCount = result.count
        previewElapsed = result.elapsed
        if let index { counts[steps[index].id] = result.count }
        await refreshCounts()
      }
      previewError = nil
    } catch {
      previewError = FriendlyError.message(error)
      preview = []
      previewRows = nil
      previewCount = nil
    }
  }

  /// How many documents leave each step (for the counts on the cards).
  func refreshCounts() async {
    guard let mongo = browser.session as? DocumentAggregating else { return }
    var fresh: [UUID: Int] = [:]
    for (index, step) in steps.enumerated() where step.isEnabled && !step.kind.writes {
      guard let stages = try? stages(upTo: index).filter({ $0.keys.first != "$out" && $0.keys.first != "$merge" }),
        let result = try? await mongo.aggregate(browser.ref, stages: stages, limit: 1)
      else { continue }
      fresh[step.id] = result.count
    }
    counts = fresh
  }

  private func timedRun<T>(_ body: () async throws -> T) async throws -> (T, TimeInterval) {
    let start = Date()
    let value = try await body()
    return (value, Date().timeIntervalSince(start))
  }

  /// Runs everything; results appear in the main list.
  func run() async {
    guard let session = browser.session else { return }
    do {
      if isSQL {
        let runs = try await session.run(try sql(), context: browser.queryContext)
        if case .table(let fields, let rows, _)? = runs.last?.outputs.first { resultRows = (fields, rows) }
      } else if let mongo = session as? DocumentAggregating {
        if steps.contains(where: { $0.isEnabled && $0.kind.writes }) && browser.connection.profile.isReadOnly {
          throw ReadOnlyError()
        }
        results = try await mongo.aggregateFull(browser.ref, stages: try stages(), options: options, limit: 1000)
      }
      resultError = nil
    } catch {
      resultError = FriendlyError.message(error)
    }
  }

  func clearResults() {
    results = nil
    resultRows = nil
    resultError = nil
  }

  // MARK: Import / export

  /// `db.reviews.aggregate([...])` for the whole pipeline (disabled steps commented out).
  var javaScript: String {
    var lines = ["db.\(browser.ref.name).aggregate(["]
    for step in steps {
      let body = (try? body(of: step))?.text(.shell) ?? step.text
      let line = "  { \(step.kind.op): \(body) },"
      lines.append(step.isEnabled ? line : "  // " + line)
    }
    lines.append("])")
    return lines.joined(separator: "\n")
  }

  /// Reads `db.x.aggregate([...])`, `[...]` or a list of stages.
  func importText(_ text: String) throws {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let open = body.range(of: "aggregate(") {
      body = String(body[open.upperBound...])
      if let close = body.lastIndex(of: ")") { body = String(body[..<close]) }
    }
    let values = try BSONParser.parseList(body)
    var imported: [PipelineStep] = []
    for value in values {
      guard let doc = value.documentValue, doc.count == 1, let (op, stageBody) = doc.elements.first.map({ ($0.key, $0.value) }),
        let kind = StepKind(rawValue: String(op.dropFirst()))
      else { throw InputError("Each stage must look like { $match: { … } }.") }
      imported.append(PipelineStep(kind: kind, form: nil, text: stageBody.text(.shell)))
    }
    steps = imported
    selectedID = steps.last?.id
    scheduleRefresh()
  }
}

/// SQL pieces for compiling pipelines.
struct SQLBuilderDialect {
  let engine: EngineKind

  func quote(_ name: String) -> String {
    switch engine {
    case .mysql, .mariadb: "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    case .sqlserver: "[" + name.replacingOccurrences(of: "]", with: "]]") + "]"
    default: "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
  }

  func qualified(_ ref: ObjectRef) -> String {
    switch engine {
    case .postgres: [ref.schema, ref.name].compactMap { $0 }.map(quote).joined(separator: ".")
    case .mysql, .mariadb: [ref.database, ref.name].compactMap { $0 }.map(quote).joined(separator: ".")
    case .sqlserver: [ref.database, ref.schema ?? "dbo", ref.name].compactMap { $0 }.map(quote).joined(separator: ".")
    case .duckdb:
      ref.kind == .file ? "'\(ref.name)'" : [ref.database, ref.schema, ref.name].compactMap { $0 }.map(quote).joined(separator: ".")
    default: quote(ref.name)
    }
  }

  func literal(_ text: String, category: ValueCategory) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if category.isNumeric, Double(trimmed) != nil { return trimmed }
    let escaped = text.replacingOccurrences(of: "'", with: "''")
    let backslashed = engine == .mysql || engine == .mariadb ? escaped.replacingOccurrences(of: "\\", with: "\\\\") : escaped
    return (engine == .sqlserver ? "N'" : "'") + backslashed + "'"
  }

  func condition(_ c: StepCondition, category: ValueCategory) -> String {
    let column = quote(c.field)
    let value = literal(c.value, category: category)
    let like = engine == .postgres || engine == .duckdb ? "ILIKE" : "LIKE"
    func pattern(_ p: String) -> String { literal(p, category: .text) }
    switch c.op {
    case .equals: return "\(column) = \(value)"
    case .notEquals: return "\(column) <> \(value)"
    case .contains: return "\(column) \(like) \(pattern("%\(c.value)%"))"
    case .notContains: return "\(column) NOT \(like) \(pattern("%\(c.value)%"))"
    case .startsWith: return "\(column) \(like) \(pattern("\(c.value)%"))"
    case .endsWith: return "\(column) \(like) \(pattern("%\(c.value)"))"
    case .greater: return "\(column) > \(value)"
    case .greaterOrEqual: return "\(column) >= \(value)"
    case .less: return "\(column) < \(value)"
    case .lessOrEqual: return "\(column) <= \(value)"
    case .isEmpty: return "\(column) IS NULL"
    case .isNotEmpty: return "\(column) IS NOT NULL"
    case .inLastDays:
      let days = Int(c.value) ?? 7
      switch engine {
      case .sqlserver: return "\(column) >= DATEADD(day, -\(days), SYSDATETIME())"
      case .mysql, .mariadb: return "\(column) >= NOW() - INTERVAL \(days) DAY"
      case .sqlite: return "\(column) >= datetime('now', '-\(days) days')"
      default: return "\(column) >= now() - INTERVAL '\(days) days'"
      }
    }
  }

  func page(limit: Int?, offset: Int?, ordered: Bool) -> String {
    guard limit != nil || offset != nil else { return "" }
    if engine == .sqlserver {
      var text = ordered ? "" : " ORDER BY (SELECT NULL)"
      text += " OFFSET \(offset ?? 0) ROWS"
      if let limit { text += " FETCH NEXT \(limit) ROWS ONLY" }
      return text
    }
    var text = ""
    if let limit { text += " LIMIT \(limit)" } else if engine == .sqlite { text += " LIMIT -1" } else if engine == .mysql || engine == .mariadb {
      text += " LIMIT 18446744073709551615"
    }
    if let offset { text += " OFFSET \(offset)" }
    return text
  }
}

extension String {
  func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
