import CQLWire
import Foundation
import SSHTunnel
import WireKit

/// A Cassandra or ScyllaDB session: keyspaces → tables → rows in partitions.
final class CQLSession: DatabaseSession, @unchecked Sendable {
  let profile: ConnectionProfile
  let client: CQLClient
  let tunnel: SSHTunnel?
  private let fieldCache = Locked<[ObjectRef: [FieldInfo]]>([:])

  init(profile: ConnectionProfile, client: CQLClient, tunnel: SSHTunnel?) {
    self.profile = profile
    self.client = client
    self.tunnel = tunnel
  }

  var serverDescription: String {
    get async {
      let version = (try? await client.query("SELECT release_version FROM system.local").result.rows.first?.first?.stringValue)
        ?? nil
      return "\(await client.isScylla ? "ScyllaDB" : "Cassandra") \(version ?? "")"
    }
  }

  func close() async {
    await client.close()
    tunnel?.close()
  }

  static func isSystemKeyspace(_ name: String) -> Bool { name.hasPrefix("system") || name == "dse_system" }

  // MARK: - Tree

  func children(of node: TreeNode?) async throws -> [TreeNode] {
    guard let node else {
      let rows = try await client.queryAll("SELECT keyspace_name FROM system_schema.keyspaces").rows
      return rows.compactMap { $0.first?.stringValue }.filter { !Self.isSystemKeyspace($0) }.sorted().map {
        TreeNode(id: "ks:\($0)", title: $0, kind: .keyspace, database: $0, hasChildren: true)
      }
    }
    guard node.kind == .keyspace, let keyspace = node.database else { return [] }
    let ks = Self.literal(keyspace)
    let tables = try await client.queryAll(
      "SELECT table_name FROM system_schema.tables WHERE keyspace_name = \(ks)"
    ).rows.compactMap { $0.first?.stringValue }
    let views =
      (try? await client.queryAll("SELECT view_name FROM system_schema.views WHERE keyspace_name = \(ks)").rows
        .compactMap { $0.first?.stringValue }) ?? []
    let tableNodes = tables.sorted().map { name -> TreeNode in
      let ref = ObjectRef(database: keyspace, name: name, kind: .table)
      return TreeNode(id: ref.id, title: name, kind: .table, database: keyspace, ref: ref)
    }
    let viewNodes = views.sorted().map { name -> TreeNode in
      let ref = ObjectRef(database: keyspace, name: name, kind: .materializedView)
      return TreeNode(id: ref.id, title: name, detail: "view", kind: .view, database: keyspace, ref: ref)
    }
    return tableNodes + viewNodes
  }

  static func literal(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

  func qualified(_ ref: ObjectRef) -> String {
    [ref.database, ref.name].compactMap { $0 }.map(CQLText.identifier).joined(separator: ".")
  }

  // MARK: - Fields

  func fields(of ref: ObjectRef) async throws -> [FieldInfo] {
    if let cached = fieldCache.get({ $0[ref] }) { return cached }
    let result = try await client.queryAll(
      """
      SELECT column_name, type, kind, position FROM system_schema.columns
      WHERE keyspace_name = \(Self.literal(ref.database ?? "")) AND table_name = \(Self.literal(ref.name))
      """)
    struct Column {
      var name: String
      var type: String
      var kind: String
      var position: Int
    }
    let columns = result.rows.compactMap { row -> Column? in
      guard row.count >= 4, let name = row[0].stringValue, let type = row[1].stringValue, let kind = row[2].stringValue
      else { return nil }
      return Column(name: name, type: type, kind: kind, position: Int(row[3].intValue ?? 0))
    }
    let partition = columns.filter { $0.kind == "partition_key" }.sorted { $0.position < $1.position }
    let clustering = columns.filter { $0.kind == "clustering" }.sorted { $0.position < $1.position }
    let rest = columns.filter { $0.kind != "partition_key" && $0.kind != "clustering" }.sorted { $0.name < $1.name }
    var fields: [FieldInfo] = []
    for column in partition {
      fields.append(
        FieldInfo(name: column.name, typeName: column.type, isPrimaryKey: true, isNullable: false, keyRole: .partition))
    }
    for column in clustering {
      fields.append(
        FieldInfo(name: column.name, typeName: column.type, isPrimaryKey: true, isNullable: false, keyRole: .clustering))
    }
    for column in rest { fields.append(FieldInfo(name: column.name, typeName: column.type)) }
    fieldCache.set { $0[ref] = fields }
    return fields
  }

  /// Conditions CQL can serve without scanning: = and IN on partition keys, comparisons on clustering keys.
  static func availableOps(for field: FieldInfo) -> [FilterOp] {
    switch field.category {
    case .list, .document, .binary: [.isNotEmpty]
    default: [.equals, .greater, .greaterOrEqual, .less, .lessOrEqual]
    }
  }

  /// Whether the filters need ALLOW FILTERING (a full table scan).
  func needsFullScan(_ request: BrowseRequest, fields: [FieldInfo]) -> Bool {
    let filters = request.activeFilters
    if filters.isEmpty { return false }
    let partition = fields.filter { $0.keyRole == .partition }.map(\.name)
    let equalities = Set(filters.filter { $0.op == .equals }.map(\.field))
    let partitionRestricted = !partition.isEmpty && partition.allSatisfy { equalities.contains($0) }
    for filter in filters {
      guard let field = fields.first(where: { $0.name == filter.field }) else { return true }
      switch field.keyRole {
      case .partition: if filter.op != .equals { return true }
      case .clustering: if !partitionRestricted { return true }
      case nil: return true
      }
    }
    return !partitionRestricted
  }

  public func requiresFullScan(_ request: BrowseRequest) async throws -> Bool {
    needsFullScan(request, fields: try await fields(of: request.ref))
  }

  func whereClause(_ request: BrowseRequest, fields: [FieldInfo]) throws -> String {
    try request.activeFilters.map { filter in
      let field = fields.first { $0.name == filter.field } ?? FieldInfo(name: filter.field, typeName: "text")
      let column = CQLText.identifier(filter.field)
      let value = try literal(text: filter.value, typeName: field.typeName)
      switch filter.op {
      case .equals: return "\(column) = \(value)"
      case .greater: return "\(column) > \(value)"
      case .greaterOrEqual: return "\(column) >= \(value)"
      case .less: return "\(column) < \(value)"
      case .lessOrEqual: return "\(column) <= \(value)"
      case .isNotEmpty: return "\(column) IS NOT NULL"
      default:
        throw InputError("\(profile.engine.displayName) can't filter with “\(filter.op.label(for: field.category))”. Use is, before or after.")
      }
    }.joined(separator: " AND ")
  }

  func selectCQL(_ request: BrowseRequest, fields: [FieldInfo], limit: Int) throws -> String {
    var cql = "SELECT * FROM \(qualified(request.ref))"
    let condition = try whereClause(request, fields: fields)
    if !condition.isEmpty { cql += " WHERE \(condition)" }
    cql += " LIMIT \(limit)"
    if needsFullScan(request, fields: fields) { cql += " ALLOW FILTERING" }
    return cql
  }

  // MARK: - Browse

  func browse(_ request: BrowseRequest) async throws -> BrowsePage {
    let fields = try await fields(of: request.ref)
    if !request.search.trimmingCharacters(in: .whitespaces).isEmpty {
      throw InputError("\(profile.engine.displayName) can't search text across a table. Add a filter on a key column instead.")
    }
    // CQL pages with a cursor, not an offset: read up to the page we need.
    let wanted = request.offset + request.limit + 1
    let cql = try selectCQL(request, fields: fields, limit: wanted)
    let (result, elapsed) = try await timed { try await client.queryAll(cql, limit: wanted) }
    let keys = fields.filter(\.isPrimaryKey).map(\.name)
    let rows = Array(result.rows.dropFirst(request.offset).prefix(request.limit))
    let records = rows.enumerated().map { index, row -> Record in
      var values: [String: CellValue] = [:]
      for (c, column) in result.columns.enumerated() where c < row.count { values[column.name] = .db(row[c]) }
      let key = RecordKey(keys.compactMap { name in values[name].map { RecordKey.Part(field: name, value: $0) } })
      return Record(id: "k:" + key.summary + "#\(request.offset + index)", key: request.ref.kind == .table ? key : nil, values: values)
    }
    var notes: [String] = []
    if needsFullScan(request, fields: fields) {
      notes.append("This filter reads the whole table (ALLOW FILTERING), which can be slow on big tables.")
    }
    if !request.sort.isEmpty {
      notes.append("Rows come in partition order; \(profile.engine.displayName) sorts only by clustering keys within one partition.")
    }
    return BrowsePage(
      fields: fields, records: records, total: nil, hasMore: result.rows.count > request.offset + request.limit,
      query: try selectCQL(request, fields: fields, limit: request.limit), elapsed: elapsed, notes: notes)
  }

  func count(_ request: BrowseRequest) async throws -> Int {
    let fields = try await fields(of: request.ref)
    var cql = "SELECT COUNT(*) FROM \(qualified(request.ref))"
    let condition = try whereClause(request, fields: fields)
    if !condition.isEmpty { cql += " WHERE \(condition)" }
    if needsFullScan(request, fields: fields) { cql += " ALLOW FILTERING" }
    let result = try await client.query(cql).result
    return Int(result.rows.first?.first?.intValue ?? 0)
  }

  // MARK: - Literals

  /// A CQL literal for text typed by a person, shaped by the column type.
  func literal(text: String, typeName: String) throws -> String {
    let t = typeName.lowercased()
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if ["int", "bigint", "smallint", "tinyint", "varint", "counter"].contains(t) {
      guard Int64(trimmed) != nil || (t == "varint" && trimmed.allSatisfy { $0.isNumber || $0 == "-" }) else {
        throw InputError("“\(text)” isn't a whole number.")
      }
      return trimmed
    }
    if ["float", "double", "decimal"].contains(t) {
      guard Double(trimmed) != nil else { throw InputError("“\(text)” isn't a number.") }
      return trimmed
    }
    if t == "boolean" {
      switch trimmed.lowercased() {
      case "true", "yes", "1": return "true"
      case "false", "no", "0": return "false"
      default: throw InputError("Use true or false.")
      }
    }
    if t == "uuid" || t == "timeuuid" {
      guard UUID(uuidString: trimmed) != nil else { throw InputError("“\(text)” isn't a UUID.") }
      return trimmed.lowercased()
    }
    if t == "blob" {
      let hex = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
      guard hex.allSatisfy(\.isHexDigit) else { throw InputError("Use hexadecimal bytes like 0xDEAD.") }
      return "0x" + hex
    }
    if t.hasPrefix("list<") || t.hasPrefix("set<") || t.hasPrefix("map<") || t.hasPrefix("frozen<") || t.hasPrefix("tuple<") {
      // Collections are typed as CQL literals: [1, 2], {'a', 'b'}, {'k': 1}.
      return trimmed.isEmpty ? (t.hasPrefix("list<") ? "[]" : "{}") : trimmed
    }
    if t == "timestamp" && trimmed.hasSuffix("Z") {
      return Self.literal(String(trimmed.dropLast()) + "+0000")
    }
    return Self.literal(text)
  }

  func literal(_ value: CellValue, typeName: String) throws -> String {
    switch value {
    case .unset: return "null"
    case .bson(let b): return Self.literal(b.text(.extendedJSON))
    case .db(let v):
      switch v {
      case .null: return "null"
      case .bool(let b): return b ? "true" : "false"
      case .int(let i): return String(i)
      case .double(let d): return String(d)
      case .decimal(let s): return s
      case .uuid(let u): return u.uuidString.lowercased()
      case .bytes(let b): return "0x" + b.hexString
      case .list(let items):
        let inner = try items.map { try literal(.db($0), typeName: Self.elementType(typeName)) }.joined(separator: ", ")
        return typeName.lowercased().hasPrefix("set<") ? "{\(inner)}" : "[\(inner)]"
      case .map(let pairs):
        let (k, val) = Self.mapTypes(typeName)
        let inner = try pairs.map { "\(try literal(.db($0.key), typeName: k)): \(try literal(.db($0.value), typeName: val))" }
        return "{\(inner.joined(separator: ", "))}"
      case .text(let s), .json(let s): return try literal(text: s, typeName: typeName)
      }
    }
  }

  static func elementType(_ typeName: String) -> String {
    guard let open = typeName.firstIndex(of: "<"), let close = typeName.lastIndex(of: ">") else { return "text" }
    return String(typeName[typeName.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
  }

  static func mapTypes(_ typeName: String) -> (String, String) {
    let inner = elementType(typeName)
    var depth = 0
    for (offset, ch) in inner.enumerated() {
      if ch == "<" { depth += 1 } else if ch == ">" { depth -= 1 } else if ch == ",", depth == 0 {
        let index = inner.index(inner.startIndex, offsetBy: offset)
        return (
          String(inner[..<index]).trimmingCharacters(in: .whitespaces),
          String(inner[inner.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        )
      }
    }
    return ("text", "text")
  }

  // MARK: - Editing

  func parseInput(_ text: String, isNull: Bool, for field: FieldInfo) throws -> CellValue {
    if isNull {
      if field.isPrimaryKey { throw InputError("\(field.name) is part of the key and can't be empty.") }
      return .null
    }
    // Validate now; keep the text, which becomes the literal on save.
    _ = try literal(text: text, typeName: field.typeName)
    switch field.category {
    case .integer: return Int64(text.trimmingCharacters(in: .whitespaces)).map { .db(.int($0)) } ?? .db(.text(text))
    case .float, .decimal: return .db(.decimal(text.trimmingCharacters(in: .whitespaces)))
    case .boolean: return .db(.bool(["true", "yes", "1"].contains(text.lowercased().trimmingCharacters(in: .whitespaces))))
    default: return .db(.text(text))
    }
  }

  private func keyCondition(_ key: RecordKey, fields: [FieldInfo]) throws -> String {
    try key.parts.map { part in
      let type = fields.first { $0.name == part.field }?.typeName ?? "text"
      return "\(CQLText.identifier(part.field)) = \(try literal(part.value, typeName: type))"
    }.joined(separator: " AND ")
  }

  func statement(for edit: RecordEdit, fields: [FieldInfo]) throws -> String {
    let table = qualified(edit.ref)
    func type(_ name: String) -> String { fields.first { $0.name == name }?.typeName ?? "text" }
    switch edit.kind {
    case .update(let changes):
      guard let key = edit.key else { throw InputError("This row can't be changed.") }
      let sets = try changes.map { "\(CQLText.identifier($0.field)) = \(try literal($0.new, typeName: type($0.field)))" }
      return "UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE \(try keyCondition(key, fields: fields))"
    case .delete:
      guard let key = edit.key else { throw InputError("This row can't be deleted.") }
      return "DELETE FROM \(table) WHERE \(try keyCondition(key, fields: fields))"
    case .insert(let values):
      let names = fields.map(\.name).filter { values[$0] != nil && values[$0]?.isNull == false }
      let literals = try names.map { try literal(values[$0]!, typeName: type($0)) }
      return "INSERT INTO \(table) (\(names.map(CQLText.identifier).joined(separator: ", "))) VALUES (\(literals.joined(separator: ", ")))"
    }
  }

  func statements(for edits: [RecordEdit]) throws -> [String] {
    try edits.map { edit in
      let fields = fieldCache.get { $0[edit.ref] } ?? []
      return try statement(for: edit, fields: fields)
    }
  }

  func apply(_ edits: [RecordEdit]) async throws -> ApplyOutcome {
    if profile.isReadOnly { throw ReadOnlyError() }
    var fieldsByRef: [ObjectRef: [FieldInfo]] = [:]
    for edit in edits where fieldsByRef[edit.ref] == nil { fieldsByRef[edit.ref] = try await fields(of: edit.ref) }
    let statements = try edits.map { try statement(for: $0, fields: fieldsByRef[$0.ref] ?? []) }
    if statements.count == 1 {
      _ = try await client.query(statements[0])
    } else if !statements.isEmpty {
      // A logged batch applies all of them or none.
      _ = try await client.query("BEGIN BATCH\n" + statements.map { $0 + ";" }.joined(separator: "\n") + "\nAPPLY BATCH")
    }
    var undo: [RecordEdit] = []
    for edit in edits {
      switch edit.kind {
      case .update(let changes):
        undo.append(
          RecordEdit(
            ref: edit.ref, key: edit.key, kind: .update(changes.map { FieldChange(field: $0.field, old: $0.new, new: $0.old) }),
            title: edit.title))
      case .delete(let record):
        undo.append(RecordEdit(ref: edit.ref, key: edit.key, kind: .insert(record.values), title: edit.title))
      case .insert(let values):
        let keys = (fieldsByRef[edit.ref] ?? []).filter(\.isPrimaryKey).map(\.name)
        let key = RecordKey(keys.compactMap { name in values[name].map { RecordKey.Part(field: name, value: $0) } })
        undo.append(
          RecordEdit(ref: edit.ref, key: key, kind: .delete(Record(id: "", key: key, values: values)), title: edit.title))
      }
    }
    return ApplyOutcome(changedItems: edits.count, undo: undo.reversed(), statements: statements)
  }

  // MARK: - Query Editor

  func run(_ text: String, context: QueryContext) async throws -> [QueryRun] {
    if let keyspace = context.database, !keyspace.isEmpty, await client.keyspace != keyspace {
      try await client.use(keyspace: keyspace)
    }
    var runs: [QueryRun] = []
    for statement in SQLText.splitStatements(text) {
      if profile.isReadOnly, !Self.isRead(statement) { throw ReadOnlyError() }
      let (result, elapsed) = try await timed { try await client.queryAll(statement, limit: 5000) }
      runs.append(QueryRun(outputs: SQLSession.outputs(result), elapsed: elapsed, statement: statement))
    }
    return runs
  }

  static func isRead(_ statement: String) -> Bool {
    let first = statement.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first?.uppercased() ?? ""
    return ["SELECT", "USE", "DESCRIBE", "DESC", "LIST"].contains(first)
  }

  func explain(_ text: String, context: QueryContext) async throws -> String {
    let statement = SQLText.splitStatements(text).last ?? text
    var lines = ["\(profile.engine.displayName) has no query plans. How this query reads data:"]
    if statement.uppercased().contains("ALLOW FILTERING") {
      lines.append("• It scans the whole table (ALLOW FILTERING) and filters the rows; slow on big tables.")
    } else if statement.uppercased().contains("WHERE") {
      lines.append("• It goes straight to the partitions named in WHERE, which is fast.")
    } else {
      lines.append("• It reads every partition in token order. Add a WHERE on the partition key to read just one.")
    }
    return lines.joined(separator: "\n")
  }

  func completions(context: QueryContext) async -> [Completion] {
    var out = [
      "SELECT", "FROM", "WHERE", "AND", "IN", "LIMIT", "ALLOW FILTERING", "INSERT INTO", "VALUES", "UPDATE", "SET",
      "DELETE FROM", "USING TTL", "CREATE TABLE", "PRIMARY KEY", "CLUSTERING ORDER BY", "BEGIN BATCH", "APPLY BATCH",
    ].map { Completion(text: $0, kind: .keyword) }
    if let keyspace = context.database,
      let tables = try? await children(of: TreeNode(id: "ks", title: keyspace, kind: .keyspace, database: keyspace))
    {
      for table in tables {
        out.append(Completion(text: table.title, detail: "table", kind: .table))
        if let ref = table.ref, let fields = try? await fields(of: ref) {
          out += fields.map { Completion(text: $0.name, detail: "\($0.typeName) · \(table.title)", kind: .column) }
        }
      }
    }
    return out
  }
}
