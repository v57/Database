import Foundation
import SSHTunnel
import WireKit

/// A session for the six SQL engines; the dialect supplies what differs.
final class SQLSession: DatabaseSession, @unchecked Sendable {
  let profile: ConnectionProfile
  let dialect: SQLDialect
  let executor: SQLExecutor
  let tunnel: SSHTunnel?
  private let fieldCache = Locked<[ObjectRef: [FieldInfo]]>([:])
  private let estimates = Locked<[ObjectRef: Int]>([:])

  init(profile: ConnectionProfile, dialect: SQLDialect, executor: SQLExecutor, tunnel: SSHTunnel?) {
    self.profile = profile
    self.dialect = dialect
    self.executor = executor
    self.tunnel = tunnel
  }

  var serverDescription: String { get async { await executor.serverDescription } }

  func close() async {
    await executor.close()
    tunnel?.close()
  }

  var engine: EngineKind { profile.engine }

  // MARK: - Tree

  func children(of node: TreeNode?) async throws -> [TreeNode] {
    guard let node else { return try await topLevel() }
    switch node.kind {
    case .database:
      if let query = dialect.schemasQuery(database: node.title) {
        let rows = try await executor.run(query, database: node.title).last?.rows ?? []
        let schemas = rows.compactMap { $0.first?.stringValue }
        // A database with only one interesting schema shows its tables directly.
        if schemas.count == 1 { return try await tables(database: node.title, schema: schemas[0]) }
        return schemas.map {
          TreeNode(
            id: "\(node.id)/\($0)", title: $0, kind: .schema, database: node.title, schema: $0, hasChildren: true)
        }
      }
      return try await tables(database: node.title, schema: nil)
    case .schema:
      return try await tables(database: node.database, schema: node.schema)
    case .folder where node.id.hasSuffix("/files"):
      return dataFiles().map { url in
        TreeNode(
          id: "file:\(url.path)", title: url.lastPathComponent, detail: Self.fileSize(url), kind: .file,
          ref: ObjectRef(name: url.path, kind: .file))
      }
    default:
      return []
    }
  }

  private func topLevel() async throws -> [TreeNode] {
    switch engine {
    case .sqlite:
      return try await tables(database: nil, schema: nil)
    case .duckdb:
      var nodes: [TreeNode] = []
      if isDataFileConnection {
        // A Parquet/CSV/JSON file opened directly: show it (and its neighbours) as tables.
        return dataFiles().map { url in
          TreeNode(
            id: "file:\(url.path)", title: url.lastPathComponent, detail: Self.fileSize(url), kind: .file,
            ref: ObjectRef(name: url.path, kind: .file))
        }
      }
      let catalog = URL(fileURLWithPath: profile.filePath).deletingPathExtension().lastPathComponent
      let schemaRows = try await executor.run(dialect.schemasQuery(database: catalog) ?? "", database: nil).last?.rows ?? []
      let schemas = schemaRows.compactMap { $0.first?.stringValue }
      if schemas.count <= 1 {
        nodes += try await tables(database: catalog, schema: schemas.first ?? "main")
      } else {
        nodes += schemas.map {
          TreeNode(id: "\(catalog)/\($0)", title: $0, kind: .schema, database: catalog, schema: $0, hasChildren: true)
        }
      }
      if !dataFiles().isEmpty {
        nodes.append(TreeNode(id: "duckdb/files", title: "Files", kind: .folder, hasChildren: true))
      }
      return nodes
    default:
      guard let query = dialect.databasesQuery else { return [] }
      let rows = try await executor.run(query, database: nil).last?.rows ?? []
      return rows.compactMap { $0.first?.stringValue }.map {
        TreeNode(id: "db:\($0)", title: $0, kind: .database, database: $0, hasChildren: true)
      }
    }
  }

  private func tables(database: String?, schema: String?) async throws -> [TreeNode] {
    let result = try await executor.run(dialect.tablesQuery(database: database, schema: schema), database: database)
      .last ?? DBResult()
    var nodes: [TreeNode] = []
    for row in result.rows {
      guard let name = row.first?.stringValue else { continue }
      let kindText = row.count > 1 ? row[1].stringValue ?? "table" : "table"
      let kind: ObjectRef.Kind =
        kindText.contains("view") ? (kindText.contains("materialized") ? .materializedView : .view) : .table
      let refDatabase = engine == .sqlite ? nil : database
      let ref = ObjectRef(database: refDatabase, schema: schema, name: name, kind: kind)
      var detail: String?
      if row.count > 2, let n = row[2].intValue, n >= 0 {
        estimates.set { $0[ref] = Int(n) }
        detail = Self.compactCount(Int(n))
      }
      nodes.append(
        TreeNode(
          id: ref.id, title: name, detail: detail ?? (kind == .table ? nil : "view"),
          kind: kind == .table ? .table : .view, database: database, schema: schema, ref: ref))
    }
    return nodes
  }

  static func compactCount(_ n: Int) -> String {
    switch n {
    case ..<10_000: n.formatted()
    case ..<1_000_000: String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K")
    default: String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
    }
  }

  // MARK: - DuckDB data files

  var isDataFileConnection: Bool {
    engine == .duckdb && !["duckdb", "ddb", "db", ""].contains((profile.filePath as NSString).pathExtension.lowercased())
  }

  /// Parquet, CSV and JSON files next to the database file.
  func dataFiles() -> [URL] {
    guard engine == .duckdb, !profile.filePath.isEmpty else { return [] }
    let folder = URL(fileURLWithPath: profile.filePath).deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let dataExtensions: Set<String> = ["parquet", "csv", "tsv", "json", "jsonl", "ndjson"]
    return names.filter { dataExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
      .map { folder.appendingPathComponent($0) }
  }

  static func fileSize(_ url: URL) -> String? {
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
  }

  // MARK: - Columns and keys

  func fields(of ref: ObjectRef) async throws -> [FieldInfo] {
    if let cached = fieldCache.get({ $0[ref] }) { return cached }
    let rows = try await executor.run(dialect.columnsQuery(ref), database: ref.database).last?.rows ?? []
    var fields: [FieldInfo] = rows.compactMap { row in
      guard row.count >= 6, let name = row[0].stringValue else { return nil }
      return FieldInfo(
        name: name, typeName: row[1].stringValue ?? "", isPrimaryKey: Self.truthy(row[4]),
        isNullable: Self.truthy(row[2]), isGenerated: Self.truthy(row[5]), defaultValue: row[3].stringValue)
    }
    if engine == .sqlite {
      // INTEGER PRIMARY KEY is an alias for rowid: SQLite fills it in.
      let keys = fields.filter(\.isPrimaryKey)
      if keys.count == 1, let index = fields.firstIndex(where: { $0.isPrimaryKey }),
        fields[index].typeName.uppercased() == "INTEGER"
      {
        fields[index].isGenerated = true
      }
    }
    if let outgoing = dialect.outgoingKeysQuery(ref),
      let keyRows = try? await executor.run(outgoing, database: ref.database).last?.rows
    {
      for row in keyRows where row.count >= 5 {
        guard let column = row[0].stringValue, let table = row[3].stringValue, let target = row[4].stringValue,
          let index = fields.firstIndex(where: { $0.name == column })
        else { continue }
        let targetRef = ObjectRef(
          database: engine == .sqlite ? nil : (row[1].stringValue ?? ref.database), schema: row[2].stringValue ?? ref.schema,
          name: table)
        fields[index].references = ForeignKey(target: targetRef, column: target)
      }
    }
    fieldCache.set { $0[ref] = fields }
    return fields
  }

  static func truthy(_ value: DBValue) -> Bool {
    switch value {
    case .bool(let b): b
    case .int(let i): i != 0
    case .text(let s): ["t", "true", "yes", "1"].contains(s.lowercased())
    default: false
    }
  }

  func relations(of ref: ObjectRef) async throws -> [Relation] {
    var out: [Relation] = []
    let fields = try await fields(of: ref)
    for field in fields {
      if let target = field.references {
        out.append(Relation(direction: .outgoing, table: target.target, column: field.name, otherColumn: target.column))
      }
    }
    if let incoming = dialect.incomingKeysQuery(ref),
      let rows = try? await executor.run(incoming, database: ref.database).last?.rows
    {
      for row in rows where row.count >= 5 {
        guard let column = row[0].stringValue, let table = row[3].stringValue, let other = row[4].stringValue else {
          continue
        }
        let source = ObjectRef(
          database: engine == .sqlite ? nil : (row[1].stringValue ?? ref.database), schema: row[2].stringValue ?? ref.schema,
          name: table)
        out.append(Relation(direction: .incoming, table: source, column: column, otherColumn: other))
      }
    }
    return out
  }

  /// Key columns, or SQLite's rowid when a table has none.
  func keyColumns(_ ref: ObjectRef, fields: [FieldInfo]) -> [String] {
    guard ref.kind == .table else { return [] }
    let keys = fields.filter(\.isPrimaryKey).map(\.name)
    if keys.isEmpty && engine == .sqlite { return [Self.rowidAlias] }
    return keys
  }

  static let rowidAlias = "__rowid"

  // MARK: - Browse

  func whereClause(_ request: BrowseRequest, fields: [FieldInfo]) -> String {
    var conditions: [String] = []
    let byName = Dictionary(fields.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    let search = request.search.trimmingCharacters(in: .whitespaces)
    if !search.isEmpty {
      var searchable = fields.filter { [.text, .other, .uuid, .json].contains($0.category) }
      if searchable.isEmpty { searchable = fields }
      let pattern = dialect.likePattern(search, prefix: true, suffix: true)
      let parts = searchable.map { "\(dialect.textCast(dialect.quote($0.name))) \(dialect.likeOperator) \(pattern)" }
      if !parts.isEmpty { conditions.append("(" + parts.joined(separator: " OR ") + ")") }
    }
    for filter in request.activeFilters {
      let category = byName[filter.field]?.category ?? .text
      conditions.append(condition(filter, category: category))
    }
    return conditions.joined(separator: " AND ")
  }

  func condition(_ filter: Filter, category: ValueCategory) -> String {
    let column = dialect.quote(filter.field)
    let value = filter.value
    let literal = dialect.literal(.db(.text(value)), category: category)
    let text = dialect.textCast(column)
    switch filter.op {
    case .equals:
      return category == .text || category == .other ? "\(column) = \(literal)" : "\(column) = \(literal)"
    case .notEquals: return "(\(column) <> \(literal) OR \(column) IS NULL)"
    case .contains: return "\(text) \(dialect.likeOperator) \(dialect.likePattern(value, prefix: true, suffix: true))"
    case .notContains:
      return "(\(text) NOT \(dialect.likeOperator) \(dialect.likePattern(value, prefix: true, suffix: true)) OR \(column) IS NULL)"
    case .startsWith: return "\(text) \(dialect.likeOperator) \(dialect.likePattern(value, prefix: false, suffix: true))"
    case .endsWith: return "\(text) \(dialect.likeOperator) \(dialect.likePattern(value, prefix: true, suffix: false))"
    case .greater: return "\(column) > \(literal)"
    case .greaterOrEqual: return "\(column) >= \(literal)"
    case .less: return "\(column) < \(literal)"
    case .lessOrEqual: return "\(column) <= \(literal)"
    case .isEmpty:
      return category == .text ? "(\(column) IS NULL OR \(text) = '')" : "\(column) IS NULL"
    case .isNotEmpty:
      return category == .text ? "(\(column) IS NOT NULL AND \(text) <> '')" : "\(column) IS NOT NULL"
    case .inLastDays: return dialect.lastDays(column, Int(value) ?? 7)
    }
  }

  func orderClause(_ request: BrowseRequest, fields: [FieldInfo], keys: [String]) -> String {
    var parts = request.sort.filter { sort in fields.contains { $0.name == sort.field } }
      .map { "\(dialect.quote($0.field)) \($0.ascending ? "ASC" : "DESC")" }
    // A stable order makes paging deterministic.
    if parts.isEmpty, !keys.isEmpty, keys != [Self.rowidAlias] { parts = keys.map { "\(dialect.quote($0)) ASC" } }
    return parts.joined(separator: ", ")
  }

  func selectSQL(_ request: BrowseRequest, fields: [FieldInfo], limit: Int) -> String {
    let keys = keyColumns(request.ref, fields: fields)
    var columns: String
    if request.hiddenFields.isEmpty {
      columns = "*"
    } else {
      let visible = fields.map(\.name).filter { !request.hiddenFields.contains($0) || keys.contains($0) }
      columns = visible.map(dialect.quote).joined(separator: ", ")
    }
    if keys == [Self.rowidAlias] { columns = "rowid AS \(dialect.quote(Self.rowidAlias)), " + columns }
    return dialect.select(
      columns: columns, from: dialect.qualified(request.ref), where: whereClause(request, fields: fields),
      orderBy: orderClause(request, fields: fields, keys: keys), limit: limit, offset: request.offset)
  }

  func browse(_ request: BrowseRequest) async throws -> BrowsePage {
    let fields = try await fields(of: request.ref)
    let keys = keyColumns(request.ref, fields: fields)
    let sql = selectSQL(request, fields: fields, limit: request.limit + 1)
    let (results, elapsed) = try await timed { try await executor.run(sql, database: request.ref.database) }
    let result = results.last ?? DBResult()
    var records: [Record] = []
    for (i, row) in result.rows.prefix(request.limit).enumerated() {
      var values: [String: CellValue] = [:]
      for (c, column) in result.columns.enumerated() where c < row.count { values[column.name] = .db(row[c]) }
      var key: RecordKey?
      if !keys.isEmpty, keys.allSatisfy({ values[$0] != nil }) {
        key = RecordKey(keys.map { RecordKey.Part(field: $0, value: values[$0]!) })
      }
      values.removeValue(forKey: Self.rowidAlias)
      records.append(
        Record(id: key.map { "k:" + $0.summary } ?? "r:\(request.offset + i)", key: key, values: values))
    }
    // Query results can reveal columns the catalog doesn't know (views over files, DuckDB files).
    var shownFields = fields
    if shownFields.isEmpty {
      shownFields = result.columns.filter { $0.name != Self.rowidAlias }.map {
        FieldInfo(name: $0.name, typeName: $0.typeName)
      }
    }
    let estimate = estimates.get { $0[request.ref] }
    var notes: [String] = []
    if request.ref.kind == .table && keys.isEmpty {
      notes.append("This table has no primary key, so its rows can't be edited here.")
    }
    let filtered = !request.activeFilters.isEmpty || !request.search.isEmpty
    return BrowsePage(
      fields: shownFields, records: records,
      total: filtered ? nil : estimate, totalIsEstimate: !filtered && estimate != nil,
      hasMore: result.rows.count > request.limit,
      query: selectSQL(request, fields: fields, limit: request.limit), elapsed: elapsed, notes: notes)
  }

  func count(_ request: BrowseRequest) async throws -> Int {
    let fields = try await fields(of: request.ref)
    let condition = whereClause(request, fields: fields)
    var sql = "SELECT COUNT(*) FROM \(dialect.qualified(request.ref))"
    if !condition.isEmpty { sql += " WHERE \(condition)" }
    let result = try await executor.run(sql, database: request.ref.database).last
    return Int(result?.rows.first?.first?.intValue ?? 0)
  }

  // MARK: - Editing

  func parseInput(_ text: String, isNull: Bool, for field: FieldInfo) throws -> CellValue {
    if isNull {
      guard field.isNullable else { throw InputError("\(field.name) can't be empty.") }
      return .null
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch field.category {
    case .integer:
      if let i = Int64(trimmed) { return .db(.int(i)) }
      if trimmed.allSatisfy({ $0.isNumber || $0 == "-" }), !trimmed.isEmpty { return .db(.decimal(trimmed)) }
      throw InputError("\(field.name) needs a whole number.")
    case .decimal:
      guard Decimal(string: trimmed) != nil, !trimmed.isEmpty else { throw InputError("\(field.name) needs a number.") }
      return .db(.decimal(trimmed))
    case .float:
      guard let d = Double(trimmed) else { throw InputError("\(field.name) needs a number.") }
      return .db(.double(d))
    case .boolean:
      switch trimmed.lowercased() {
      case "true", "t", "yes", "1", "on": return .db(.bool(true))
      case "false", "f", "no", "0", "off": return .db(.bool(false))
      default: throw InputError("\(field.name) is either true or false.")
      }
    case .uuid:
      guard let u = UUID(uuidString: trimmed) else { throw InputError("\(field.name) needs a UUID like 6F9619FF-8B86-D011-B42D-00C04FC964FF.") }
      return .db(.uuid(u))
    case .json:
      guard let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
      else { throw InputError("\(field.name) needs valid JSON.") }
      return .db(.json(trimmed))
    case .binary:
      let hex = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") ? String(trimmed.dropFirst(2)) : trimmed
      guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else {
        throw InputError("\(field.name) needs hexadecimal bytes like 0xDEAD.")
      }
      var bytes: [UInt8] = []
      var index = hex.startIndex
      while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        bytes.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
      }
      return .db(.bytes(bytes))
    case .date:
      guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
        throw InputError("\(field.name) needs a date like 2026-10-12.")
      }
      return .db(.text(trimmed))
    default:
      return .db(.text(text))
    }
  }

  private func keyCondition(_ key: RecordKey) -> String {
    key.parts.map { part in
      let column = part.field == Self.rowidAlias ? "rowid" : dialect.quote(part.field)
      return part.value.isNull ? "\(column) IS NULL" : "\(column) = \(dialect.literal(part.value, category: .other))"
    }.joined(separator: " AND ")
  }

  private func category(_ field: String, in fields: [FieldInfo]) -> ValueCategory {
    fields.first { $0.name == field }?.category ?? .other
  }

  func statement(for edit: RecordEdit, fields: [FieldInfo]) throws -> String {
    let table = dialect.qualified(edit.ref)
    switch edit.kind {
    case .update(let changes):
      guard let key = edit.key else { throw InputError("This row has no key, so it can't be changed.") }
      let sets = changes.map { "\(dialect.quote($0.field)) = \(dialect.literal($0.new, category: category($0.field, in: fields)))" }
      return "UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE \(keyCondition(key))"
    case .delete:
      guard let key = edit.key else { throw InputError("This row has no key, so it can't be deleted.") }
      return "DELETE FROM \(table) WHERE \(keyCondition(key))"
    case .insert(let values):
      let names = fields.map(\.name).filter { values[$0] != nil }
      let keys = keyColumns(edit.ref, fields: fields).filter { $0 != Self.rowidAlias }
      return dialect.insert(
        into: table, columns: names.map(dialect.quote),
        values: names.map { dialect.literal(values[$0]!, category: category($0, in: fields)) }, returning: keys)
    }
  }

  func statements(for edits: [RecordEdit]) throws -> [String] {
    // Fields must be cached by now (the editor loaded them); fall back to bare quoting.
    try edits.map { edit in
      let fields = fieldCache.get { $0[edit.ref] } ?? []
      return try statement(for: edit, fields: fields)
    }
  }

  func apply(_ edits: [RecordEdit]) async throws -> ApplyOutcome {
    if profile.isReadOnly { throw ReadOnlyError() }
    if edits.isEmpty { return ApplyOutcome(changedItems: 0, undo: [], statements: []) }
    let database = edits[0].ref.database
    var fieldsByRef: [ObjectRef: [FieldInfo]] = [:]
    for edit in edits where fieldsByRef[edit.ref] == nil { fieldsByRef[edit.ref] = try await fields(of: edit.ref) }
    let statements = try edits.map { try statement(for: $0, fields: fieldsByRef[$0.ref] ?? []) }
    let kinds = edits.map(\.kind)
    let results = try await executor.transaction(statements, dialect: dialect, database: database) { index, result in
      switch kinds[index] {
      case .update, .delete:
        if let n = result.affectedRows, n == 0 {
          throw InputError("Item \(index + 1) no longer exists or was changed by someone else. Nothing was saved.")
        }
      case .insert: break
      }
    }
    // Undo: reverse each edit, newest first when replayed.
    var undo: [RecordEdit] = []
    for (index, edit) in edits.enumerated() {
      let fields = fieldsByRef[edit.ref] ?? []
      switch edit.kind {
      case .update(let changes):
        undo.append(
          RecordEdit(
            ref: edit.ref, key: edit.key, kind: .update(changes.map { FieldChange(field: $0.field, old: $0.new, new: $0.old) }),
            title: edit.title))
      case .delete(let record):
        var values = record.values
        values.removeValue(forKey: Self.rowidAlias)
        // Generated columns other than the key can't be written back.
        for field in fields where field.isGenerated && !field.isPrimaryKey { values.removeValue(forKey: field.name) }
        undo.append(RecordEdit(ref: edit.ref, key: edit.key, kind: .insert(values), title: edit.title))
      case .insert(let values):
        let keys = keyColumns(edit.ref, fields: fields).filter { $0 != Self.rowidAlias }
        var parts: [RecordKey.Part] = []
        let returned = results[index]
        for key in keys {
          if let column = returned.column(key), let value = returned.rows.first?[column] {
            parts.append(RecordKey.Part(field: key, value: .db(value)))
          } else if let value = values[key] {
            parts.append(RecordKey.Part(field: key, value: value))
          }
        }
        if parts.count == keys.count && !parts.isEmpty {
          undo.append(
            RecordEdit(
              ref: edit.ref, key: RecordKey(parts), kind: .delete(Record(id: "", key: RecordKey(parts), values: values)),
              title: edit.title))
        }
      }
    }
    return ApplyOutcome(changedItems: edits.count, undo: undo.reversed(), statements: statements)
  }

  // MARK: - Query Editor

  func run(_ text: String, context: QueryContext) async throws -> [QueryRun] {
    let database = context.database ?? (engine == .postgres ? nil : profile.database.isEmpty ? nil : profile.database)
    let (results, elapsed) = try await timed { try await executor.run(text, database: database) }
    let statements = SQLText.splitStatements(text)
    return results.enumerated().map { index, result in
      QueryRun(
        outputs: Self.outputs(result), elapsed: elapsed / Double(max(results.count, 1)),
        statement: index < statements.count ? statements[index] : text)
    }
  }

  static func outputs(_ result: DBResult) -> [QueryOutput] {
    var outputs: [QueryOutput] = []
    if result.hasRows {
      let fields = result.columns.map { FieldInfo(name: $0.name, typeName: $0.typeName) }
      outputs.append(.table(fields: fields, rows: result.rows.map { $0.map(CellValue.db) }, note: nil))
    } else if let n = result.affectedRows {
      outputs.append(.message("\(n.formatted()) row\(n == 1 ? "" : "s") affected"))
    } else {
      outputs.append(.message(result.commandTag ?? "Done"))
    }
    for message in result.messages { outputs.append(.message(message)) }
    return outputs
  }

  func explain(_ text: String, context: QueryContext) async throws -> String {
    let database = context.database ?? (engine == .postgres ? nil : profile.database.isEmpty ? nil : profile.database)
    let statement = SQLText.splitStatements(text).last ?? text
    var lines: [String] = []
    for sql in dialect.explain(statement) {
      let results = try await executor.run(sql, database: database)
      for result in results where result.hasRows {
        if engine == .mysql || engine == .mariadb, result.columns.count > 1 {
          lines.append(result.columns.map(\.name).joined(separator: "\t"))
        }
        for row in result.rows {
          lines.append(row.map { $0.stringValue ?? "" }.filter { !$0.isEmpty }.joined(separator: "\t"))
        }
      }
    }
    return lines.joined(separator: "\n")
  }

  func completions(context: QueryContext) async -> [Completion] {
    var out = SQLKeywords.all.map { Completion(text: $0, kind: .keyword) }
    if let tables = try? await children(
      of: context.schema.map {
        TreeNode(id: "s", title: $0, kind: .schema, database: context.database, schema: $0)
      } ?? context.database.map { TreeNode(id: "d", title: $0, kind: .database, database: $0) })
    {
      for node in tables where node.ref != nil {
        out.append(Completion(text: node.title, detail: node.kind == .view ? "view" : "table", kind: .table))
        if let ref = node.ref, let fields = try? await fields(of: ref) {
          out += fields.map { Completion(text: $0.name, detail: "\($0.typeName) · \(node.title)", kind: .column) }
        }
      }
    }
    return out
  }
}

enum SQLKeywords {
  static let all = [
    "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "ILIKE", "BETWEEN", "ORDER BY",
    "GROUP BY", "HAVING", "LIMIT", "OFFSET", "JOIN", "LEFT JOIN", "INNER JOIN", "ON", "AS", "DISTINCT", "COUNT",
    "SUM", "AVG", "MIN", "MAX", "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "CREATE TABLE",
    "ALTER TABLE", "DROP TABLE", "WITH", "CASE", "WHEN", "THEN", "ELSE", "END", "UNION", "EXISTS", "DESC", "ASC",
  ]
}
