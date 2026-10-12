import BSON
import Foundation
import MongoWire
import SSHTunnel
import WireKit

/// A MongoDB session: databases → collections → documents.
final class MongoSession: DatabaseSession, @unchecked Sendable {
  let profile: ConnectionProfile
  let client: MongoClient
  let tunnel: SSHTunnel?
  private let fieldCache = Locked<[ObjectRef: [FieldInfo]]>([:])

  init(profile: ConnectionProfile, client: MongoClient, tunnel: SSHTunnel?) {
    self.profile = profile
    self.client = client
    self.tunnel = tunnel
  }

  var serverDescription: String {
    get async { "MongoDB \(await client.serverVersion ?? "")" }
  }

  func close() async {
    await client.close()
    tunnel?.close()
  }

  // MARK: - Tree

  func children(of node: TreeNode?) async throws -> [TreeNode] {
    guard let node else {
      let databases = try await client.listDatabases()
      return databases.map {
        TreeNode(
          id: "db:\($0.name)", title: $0.name,
          detail: ByteCountFormatter.string(fromByteCount: $0.sizeOnDisk, countStyle: .file), kind: .database,
          database: $0.name, hasChildren: true)
      }
    }
    guard node.kind == .database, let database = node.database else { return [] }
    let collections = try await client.listCollections(database: database).filter { !$0.name.hasPrefix("system.") }
      .sorted { $0.name < $1.name }
    var nodes: [TreeNode] = []
    for collection in collections {
      let isView = collection.type == "view"
      let ref = ObjectRef(database: database, name: collection.name, kind: isView ? .view : .collection)
      var detail: String?
      if !isView, collections.count <= 200,
        let n = try? await client.estimatedCount(database: database, collection: collection.name)
      {
        detail = SQLSession.compactCount(n)
      }
      nodes.append(
        TreeNode(
          id: ref.id, title: collection.name, detail: detail ?? (isView ? "view" : nil),
          kind: isView ? .view : .collection, database: database, ref: ref))
    }
    return nodes
  }

  // MARK: - Fields

  /// Samples documents to learn field names, their most common type and how often they're present.
  func fields(of ref: ObjectRef) async throws -> [FieldInfo] {
    if let cached = fieldCache.get({ $0[ref] }) { return cached }
    let sample = try await client.aggregate(
      database: ref.database ?? "", collection: ref.name, pipeline: [["$sample": .document(["size": .int32(200)])]],
      limit: 200)
    let fields = Self.catalog(sample)
    fieldCache.set { $0[ref] = fields }
    return fields
  }

  static func catalog(_ documents: [BSONDocument]) -> [FieldInfo] {
    var order: [String] = []
    var types: [String: [String: Int]] = [:]
    var present: [String: Int] = [:]
    for doc in documents {
      for (key, value) in doc {
        if types[key] == nil {
          order.append(key)
          types[key] = [:]
        }
        types[key]![value.typeName, default: 0] += 1
        present[key, default: 0] += 1
      }
    }
    if let id = order.firstIndex(of: "_id") { order.insert(order.remove(at: id), at: 0) }
    return order.map { key in
      let typeName = types[key]!.max { $0.value < $1.value }?.key ?? "String"
      return FieldInfo(
        name: key, typeName: typeName, category: category(forBSONType: typeName), isPrimaryKey: key == "_id",
        isNullable: key != "_id", presence: documents.isEmpty ? nil : Double(present[key] ?? 0) / Double(documents.count))
    }
  }

  static func category(forBSONType type: String) -> ValueCategory {
    switch type {
    case "String", "Symbol": .text
    case "Int32", "Int64": .integer
    case "Double": .float
    case "Decimal128": .decimal
    case "Boolean": .boolean
    case "Date", "Timestamp": .dateTime
    case "Array": .list
    case "Object": .document
    case "Binary": .binary
    case "UUID": .uuid
    default: .other
    }
  }

  // MARK: - Filters

  /// Interprets filter text the way the field's type suggests.
  static func value(_ text: String, category: ValueCategory, field: String) -> BSON {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if field == "_id" || category == .other, let id = ObjectID(trimmed) { return .objectId(id) }
    switch category {
    case .integer:
      if let i = Int64(trimmed) { return Int32(exactly: i).map(BSON.int32) ?? .int64(i) }
    case .float:
      if let d = Double(trimmed) { return .double(d) }
    case .decimal:
      if let d = Decimal128(trimmed) { return .decimal128(d) }
    case .boolean:
      if ["true", "yes", "1"].contains(trimmed.lowercased()) { return .bool(true) }
      if ["false", "no", "0"].contains(trimmed.lowercased()) { return .bool(false) }
    case .dateTime, .date:
      if let ms = BSONParser.parseISODate(trimmed) { return .datetime(ms) }
    default:
      break
    }
    if let parsed = try? BSON(parsing: trimmed), !(parsed.stringValue != nil), category != .text {
      return parsed
    }
    return .string(text)
  }

  static func escapeRegex(_ text: String) -> String {
    NSRegularExpression.escapedPattern(for: text)
  }

  func filterDocument(_ request: BrowseRequest, fields: [FieldInfo]) -> BSONDocument {
    var clauses: [BSON] = []
    let byName = Dictionary(fields.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    let search = request.search.trimmingCharacters(in: .whitespaces)
    if !search.isEmpty {
      let textFields = fields.filter { $0.category == .text }.map(\.name)
      let regex = BSON.regex(pattern: Self.escapeRegex(search), options: "i")
      var alternatives: [BSON] = textFields.map { .document([$0: regex]) }
      if let id = ObjectID(search) { alternatives.append(.document(["_id": .objectId(id)])) }
      if !alternatives.isEmpty { clauses.append(.document(["$or": .array(alternatives)])) }
    }
    for filter in request.activeFilters {
      let category = byName[filter.field]?.category ?? .text
      let value = Self.value(filter.value, category: category, field: filter.field)
      let condition: BSON
      switch filter.op {
      case .equals: condition = value
      case .notEquals: condition = .document(["$ne": value])
      case .contains: condition = .regex(pattern: Self.escapeRegex(filter.value), options: "i")
      case .notContains: condition = .document(["$not": .regex(pattern: Self.escapeRegex(filter.value), options: "i")])
      case .startsWith: condition = .regex(pattern: "^" + Self.escapeRegex(filter.value), options: "i")
      case .endsWith: condition = .regex(pattern: Self.escapeRegex(filter.value) + "$", options: "i")
      case .greater: condition = .document(["$gt": value])
      case .greaterOrEqual: condition = .document(["$gte": value])
      case .less: condition = .document(["$lt": value])
      case .lessOrEqual: condition = .document(["$lte": value])
      case .isEmpty: condition = .document(["$in": .array([.null, .string(""), .array([])])])
      case .isNotEmpty: condition = .document(["$nin": .array([.null, .string(""), .array([])])])
      case .inLastDays:
        let days = Double(Int(filter.value) ?? 7)
        condition = .document(["$gte": .date(Date().addingTimeInterval(-days * 86400))])
      }
      clauses.append(.document([filter.field: condition]))
    }
    switch clauses.count {
    case 0: return [:]
    case 1: return clauses[0].documentValue ?? [:]
    default:
      // Merge simple clauses on different fields; otherwise use $and.
      var merged = BSONDocument()
      for clause in clauses {
        guard let doc = clause.documentValue, doc.count == 1, let key = doc.keys.first, merged[key] == nil else {
          return ["$and": .array(clauses)]
        }
        merged[key] = doc[key]
      }
      return merged
    }
  }

  func sortDocument(_ request: BrowseRequest) -> BSONDocument {
    var sort = BSONDocument()
    for key in request.sort { sort[key.field] = .int32(key.ascending ? 1 : -1) }
    return sort
  }

  func projection(_ request: BrowseRequest) -> BSONDocument {
    var projection = BSONDocument()
    for field in request.hiddenFields.sorted() where field != "_id" { projection[field] = .int32(0) }
    return projection
  }

  static func shellName(_ collection: String) -> String {
    collection.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
      ? "db.\(collection)" : "db.getCollection(\"\(collection)\")"
  }

  func findText(_ request: BrowseRequest, filter: BSONDocument) -> String {
    var text = "\(Self.shellName(request.ref.name)).find(\(filter.text())"
    let projection = projection(request)
    if !projection.isEmpty { text += ", \(projection.text())" }
    text += ")"
    let sort = sortDocument(request)
    if !sort.isEmpty { text += ".sort(\(sort.text()))" }
    if request.offset > 0 { text += ".skip(\(request.offset))" }
    text += ".limit(\(request.limit))"
    return text
  }

  // MARK: - Browse

  func browse(_ request: BrowseRequest) async throws -> BrowsePage {
    let fields = try await fields(of: request.ref)
    let filter = filterDocument(request, fields: fields)
    let (documents, elapsed) = try await timed {
      try await client.find(
        database: request.ref.database ?? "", collection: request.ref.name, filter: filter,
        sort: sortDocument(request), projection: projection(request), skip: request.offset, limit: request.limit + 1)
    }
    let records = documents.prefix(request.limit).enumerated().map { index, doc in
      Self.record(doc, fallbackIndex: request.offset + index)
    }
    // Fields seen in this page but missing from the sample.
    var allFields = fields
    for doc in documents.prefix(request.limit) {
      for (key, value) in doc where !allFields.contains(where: { $0.name == key }) {
        allFields.append(
          FieldInfo(name: key, typeName: value.typeName, category: Self.category(forBSONType: value.typeName)))
      }
    }
    var total: Int?
    var estimate = false
    if filter.isEmpty {
      total = try? await client.estimatedCount(database: request.ref.database ?? "", collection: request.ref.name)
      estimate = true
    }
    return BrowsePage(
      fields: allFields, records: records, total: total, totalIsEstimate: estimate,
      hasMore: documents.count > request.limit, query: findText(request, filter: filter), elapsed: elapsed)
  }

  static func record(_ doc: BSONDocument, fallbackIndex: Int) -> Record {
    var values: [String: CellValue] = [:]
    for (key, value) in doc { values[key] = .bson(value) }
    let key = doc["_id"].map { RecordKey([RecordKey.Part(field: "_id", value: .bson($0))]) }
    let id = doc["_id"].map { "id:" + $0.text() } ?? "i:\(fallbackIndex)"
    return Record(id: id, key: key, values: values, document: doc)
  }

  func count(_ request: BrowseRequest) async throws -> Int {
    let fields = try await fields(of: request.ref)
    return try await client.count(
      database: request.ref.database ?? "", collection: request.ref.name, filter: filterDocument(request, fields: fields))
  }

  /// Documents in other collections that point at this one: not knowable without a schema.
  func relations(of ref: ObjectRef) async throws -> [Relation] { [] }

  // MARK: - Editing

  /// The type names the document editor offers.
  static let editableTypes = [
    "String", "Int32", "Int64", "Double", "Decimal128", "Boolean", "Date", "ObjectId", "Null", "Object", "Array",
  ]

  func parseInput(_ text: String, isNull: Bool, for field: FieldInfo) throws -> CellValue {
    if isNull { return .bson(.null) }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch field.typeName {
    case "String": return .bson(.string(text))
    case "Int32":
      guard let v = Int32(trimmed) else { throw InputError("\(field.name) needs a whole number (Int32).") }
      return .bson(.int32(v))
    case "Int64":
      guard let v = Int64(trimmed) else { throw InputError("\(field.name) needs a whole number (Int64).") }
      return .bson(.int64(v))
    case "Double":
      guard let v = Double(trimmed) else { throw InputError("\(field.name) needs a number.") }
      return .bson(.double(v))
    case "Decimal128":
      guard let v = Decimal128(trimmed) else { throw InputError("\(field.name) needs a decimal number.") }
      return .bson(.decimal128(v))
    case "Boolean":
      switch trimmed.lowercased() {
      case "true", "yes", "1": return .bson(.bool(true))
      case "false", "no", "0": return .bson(.bool(false))
      default: throw InputError("\(field.name) is either true or false.")
      }
    case "Date":
      if let ms = BSONParser.parseISODate(trimmed) { return .bson(.datetime(ms)) }
      if let value = try? BSON(parsing: trimmed), case .datetime = value { return .bson(value) }
      throw InputError("\(field.name) needs a date like 2026-10-12T10:02:00Z.")
    case "ObjectId":
      let hex = trimmed.replacingOccurrences(of: "ObjectId(", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"')"))
      guard let id = ObjectID(hex) else { throw InputError("\(field.name) needs 24 hexadecimal characters.") }
      return .bson(.objectId(id))
    case "Null": return .bson(.null)
    default:
      do {
        return .bson(try BSON(parsing: trimmed))
      } catch {
        throw InputError(error.localizedDescription)
      }
    }
  }

  func updateDocument(_ changes: [FieldChange]) -> BSONDocument {
    var set = BSONDocument()
    var unset = BSONDocument()
    for change in changes {
      switch change.new {
      case .unset: unset[change.field] = .string("")
      case .bson(let value): set[change.field] = value
      case .db(let value): set[change.field] = .string(value.displayText)
      }
    }
    var update = BSONDocument()
    if !set.isEmpty { update["$set"] = .document(set) }
    if !unset.isEmpty { update["$unset"] = .document(unset) }
    return update
  }

  static func idFilter(_ key: RecordKey?) -> BSONDocument? {
    guard let part = key?.parts.first, case .bson(let id) = part.value else { return nil }
    return ["_id": id]
  }

  static func document(from values: [String: CellValue], order: [String]? = nil) -> BSONDocument {
    var doc = BSONDocument()
    let keys = order ?? values.keys.sorted { a, b in a == "_id" ? true : b == "_id" ? false : a < b }
    for key in keys {
      guard let value = values[key] else { continue }
      switch value {
      case .bson(let b): doc[key] = b
      case .db(let v): doc[key] = .string(v.displayText)
      case .unset: break
      }
    }
    return doc
  }

  func statements(for edits: [RecordEdit]) throws -> [String] {
    try edits.map { edit in
      let collection = Self.shellName(edit.ref.name)
      switch edit.kind {
      case .update(let changes):
        guard let filter = Self.idFilter(edit.key) else { throw InputError("This document has no _id.") }
        return "\(collection).updateOne(\(filter.text()), \(updateDocument(changes).text()))"
      case .insert(let values):
        return "\(collection).insertOne(\(Self.document(from: values).text()))"
      case .delete(let record):
        guard let filter = Self.idFilter(edit.key ?? record.key) else { throw InputError("This document has no _id.") }
        return "\(collection).deleteOne(\(filter.text()))"
      }
    }
  }

  func apply(_ edits: [RecordEdit]) async throws -> ApplyOutcome {
    if profile.isReadOnly { throw ReadOnlyError() }
    let statements = try statements(for: edits)
    var undo: [RecordEdit] = []
    var done = 0
    for edit in edits {
      let database = edit.ref.database ?? ""
      do {
        switch edit.kind {
        case .update(let changes):
          guard let filter = Self.idFilter(edit.key) else { throw InputError("This document has no _id.") }
          let (matched, _) = try await client.update(
            database: database, collection: edit.ref.name, filter: filter, update: updateDocument(changes))
          if matched == 0 { throw InputError("\(edit.title) no longer exists.") }
          undo.append(
            RecordEdit(
              ref: edit.ref, key: edit.key,
              kind: .update(changes.map { FieldChange(field: $0.field, old: $0.new, new: $0.old) }),
              title: edit.title))
        case .insert(let values):
          var doc = Self.document(from: values)
          if doc["_id"] == nil {
            var withID = BSONDocument()
            withID["_id"] = .objectId(.generate())
            for (k, v) in doc { withID[k] = v }
            doc = withID
          }
          try await client.insert(database: database, collection: edit.ref.name, documents: [doc])
          let key = RecordKey([RecordKey.Part(field: "_id", value: .bson(doc["_id"]!))])
          undo.append(
            RecordEdit(
              ref: edit.ref, key: key, kind: .delete(Self.record(doc, fallbackIndex: 0)), title: edit.title))
        case .delete(let record):
          guard let filter = Self.idFilter(edit.key ?? record.key) else { throw InputError("This document has no _id.") }
          let deleted = try await client.delete(database: database, collection: edit.ref.name, filter: filter)
          if deleted == 0 { throw InputError("\(edit.title) no longer exists.") }
          let original = record.document ?? Self.document(from: record.values)
          var values: [String: CellValue] = [:]
          for (k, v) in original { values[k] = .bson(v) }
          undo.append(RecordEdit(ref: edit.ref, key: record.key, kind: .insert(values), title: edit.title))
        }
        done += 1
      } catch {
        // MongoDB without a replica set has no multi-document transactions: say what did happen.
        if done > 0 {
          throw InputError(
            "\(error.localizedDescription) The first \(done) change\(done == 1 ? " was" : "s were") saved; you can undo \(done == 1 ? "it" : "them").")
        }
        throw error
      }
    }
    return ApplyOutcome(changedItems: done, undo: undo.reversed(), statements: statements)
  }

  // MARK: - Aggregation

  /// Runs the first `upTo` stages (all when nil) and returns the output and its size.
  func aggregate(_ ref: ObjectRef, stages: [BSONDocument], limit: Int = 20) async throws -> (
    documents: [BSONDocument], count: Int?, elapsed: TimeInterval
  ) {
    let database = ref.database ?? ""
    let (documents, elapsed) = try await timed {
      try await client.aggregate(
        database: database, collection: ref.name, pipeline: stages + [["$limit": .int32(Int32(limit))]], limit: limit)
    }
    let counted = try? await client.aggregate(
      database: database, collection: ref.name, pipeline: stages + [["$count": .string("n")]], limit: 1)
    return (documents, counted?.first?["n"]?.intValue ?? 0, elapsed)
  }

  func aggregateFull(_ ref: ObjectRef, stages: [BSONDocument], options: BSONDocument, limit: Int) async throws
    -> [BSONDocument]
  {
    try await client.aggregate(
      database: ref.database ?? "", collection: ref.name, pipeline: stages, limit: limit,
      allowDiskUse: options["allowDiskUse"]?.boolValue ?? false, options: BSONDocument(options.filter { $0.key != "allowDiskUse" }.map { ($0.key, $0.value) }))
  }

  func explainAggregate(_ ref: ObjectRef, stages: [BSONDocument]) async throws -> BSONDocument {
    try await client.explain(
      database: ref.database ?? "",
      command: [
        "aggregate": .string(ref.name), "pipeline": .array(stages.map(BSON.document)), "cursor": .document([:]),
      ])
  }

  // MARK: - Query Editor

  func run(_ text: String, context: QueryContext) async throws -> [QueryRun] {
    var database = context.database ?? (profile.database.isEmpty ? "test" : profile.database)
    var runs: [QueryRun] = []
    for statement in try MongoShell.parse(text) {
      let (outputs, elapsed) = try await timed { try await execute(statement, database: &database) }
      runs.append(QueryRun(outputs: outputs, elapsed: elapsed, statement: "\(statement)"))
    }
    return runs
  }

  private func execute(_ statement: MongoShellStatement, database: inout String) async throws -> [QueryOutput] {
    switch statement {
    case .showDatabases:
      let dbs = try await client.listDatabases()
      return [.text(dbs.map { "\($0.name)\t\(ByteCountFormatter.string(fromByteCount: $0.sizeOnDisk, countStyle: .file))" }.joined(separator: "\n"))]
    case .showCollections:
      return [.text(try await client.listCollections(database: database).map(\.name).sorted().joined(separator: "\n"))]
    case .use(let name):
      database = name
      return [.message("Switched to \(name)")]
    case .call(let call):
      return try await execute(call, database: database)
    }
  }

  private func execute(_ call: MongoShellCall, database: String) async throws -> [QueryOutput] {
    let args = call.arguments
    func doc(_ index: Int) -> BSONDocument { index < args.count ? args[index].documentValue ?? [:] : [:] }
    guard case .collection(let collection) = call.target else {
      switch call.method {
      case "runCommand", "adminCommand":
        let reply = try await client.command(doc(0), database: call.method == "adminCommand" ? "admin" : database)
        return [.documents([reply], note: nil)]
      case "getCollectionNames":
        return [.text(try await client.listCollections(database: database).map(\.name).sorted().joined(separator: "\n"))]
      case "stats":
        return [.documents([try await client.command(["dbStats": .int32(1)], database: database)], note: nil)]
      default:
        throw InputError("db.\(call.method)() isn't supported here. Try db.runCommand({ … }).")
      }
    }
    switch call.method {
    case "find", "findOne":
      var sort = BSONDocument()
      var limit = call.method == "findOne" ? 1 : 50
      var skip = 0
      var projection = doc(1)
      var explain = false
      var countOnly = false
      for link in call.chain {
        switch link.name {
        case "sort": sort = link.arguments.first?.documentValue ?? [:]
        case "limit": limit = link.arguments.first?.intValue ?? limit
        case "skip": skip = link.arguments.first?.intValue ?? 0
        case "projection": projection = link.arguments.first?.documentValue ?? [:]
        case "explain": explain = true
        case "count", "countDocuments", "size": countOnly = true
        case "toArray", "pretty", "batchSize": break
        default: throw InputError(".\(link.name)() isn't supported after find().")
        }
      }
      if countOnly {
        let n = try await client.count(database: database, collection: collection, filter: doc(0))
        return [.message("\(n)")]
      }
      if explain {
        var command: BSONDocument = ["find": .string(collection), "filter": .document(doc(0))]
        if !sort.isEmpty { command["sort"] = .document(sort) }
        return [.documents([try await client.explain(database: database, command: command, verbosity: "executionStats")], note: nil)]
      }
      let documents = try await client.find(
        database: database, collection: collection, filter: doc(0), sort: sort, projection: projection, skip: skip,
        limit: max(limit, 1))
      return [.documents(documents, note: "\(documents.count) document\(documents.count == 1 ? "" : "s")")]
    case "aggregate":
      let stages = (args.first?.arrayValue ?? []).compactMap(\.documentValue)
      let options = doc(1)
      if call.chain.contains(where: { $0.name == "explain" }) {
        return [.documents([try await client.explain(database: database, command: ["aggregate": .string(collection), "pipeline": .array(stages.map(BSON.document)), "cursor": .document([:])])], note: nil)]
      }
      let documents = try await client.aggregate(
        database: database, collection: collection, pipeline: stages, limit: 1000,
        allowDiskUse: options["allowDiskUse"]?.boolValue ?? false)
      return [.documents(documents, note: "\(documents.count) document\(documents.count == 1 ? "" : "s")")]
    case "countDocuments", "count":
      return [.message(String(try await client.count(database: database, collection: collection, filter: doc(0))))]
    case "estimatedDocumentCount":
      return [.message(String(try await client.estimatedCount(database: database, collection: collection)))]
    case "distinct":
      guard let field = args.first?.stringValue else { throw InputError("distinct needs a field name.") }
      let reply = try await client.command(
        ["distinct": .string(collection), "key": .string(field), "query": .document(doc(1))], database: database)
      return [.documents((reply["values"]?.arrayValue ?? []).map { ["value": $0] }, note: nil)]
    case "insertOne":
      try writable()
      return [.message("Inserted \(try await client.insert(database: database, collection: collection, documents: [doc(0)])) document")]
    case "insertMany":
      try writable()
      let documents = (args.first?.arrayValue ?? []).compactMap(\.documentValue)
      return [.message("Inserted \(try await client.insert(database: database, collection: collection, documents: documents)) documents")]
    case "updateOne", "updateMany", "replaceOne":
      try writable()
      let (matched, modified) = try await client.update(
        database: database, collection: collection, filter: doc(0), update: doc(1),
        many: call.method == "updateMany", upsert: doc(2)["upsert"]?.boolValue ?? false)
      return [.message("Matched \(matched), modified \(modified)")]
    case "deleteOne", "deleteMany":
      try writable()
      let n = try await client.delete(
        database: database, collection: collection, filter: doc(0), many: call.method == "deleteMany")
      return [.message("Deleted \(n) document\(n == 1 ? "" : "s")")]
    case "getIndexes":
      return [.documents(try await client.listIndexes(database: database, collection: collection), note: nil)]
    case "createIndex":
      try writable()
      var index: BSONDocument = ["key": .document(doc(0))]
      for (k, v) in doc(1) { index[k] = v }
      if index["name"] == nil {
        index["name"] = .string(doc(0).map { "\($0.key)_\($0.value.text())" }.joined(separator: "_"))
      }
      let reply = try await client.command(
        ["createIndexes": .string(collection), "indexes": .array([.document(index)])], database: database)
      return [.documents([reply], note: nil)]
    case "drop":
      try writable()
      try await client.dropCollection(database: database, collection: collection)
      return [.message("Dropped \(collection)")]
    default:
      throw InputError("\(call.method)() isn't supported here.")
    }
  }

  private func writable() throws {
    if profile.isReadOnly { throw ReadOnlyError() }
  }

  func explain(_ text: String, context: QueryContext) async throws -> String {
    let database = context.database ?? (profile.database.isEmpty ? "test" : profile.database)
    guard case .call(let call)? = try MongoShell.parse(text).last, case .collection(let collection) = call.target else {
      throw InputError("Explain works on find() and aggregate().")
    }
    let command: BSONDocument
    switch call.method {
    case "find", "findOne":
      var cmd: BSONDocument = ["find": .string(collection), "filter": call.arguments.first ?? .document([:])]
      if let sort = call.chain.first(where: { $0.name == "sort" })?.arguments.first { cmd["sort"] = sort }
      command = cmd
    case "aggregate":
      command = ["aggregate": .string(collection), "pipeline": call.arguments.first ?? .array([]), "cursor": .document([:])]
    default:
      throw InputError("Explain works on find() and aggregate().")
    }
    let plan = try await client.explain(database: database, command: command, verbosity: "executionStats")
    return Self.summarize(plan)
  }

  /// A short, readable summary of an explain plan, followed by the full plan.
  static func summarize(_ plan: BSONDocument) -> String {
    var lines: [String] = []
    if let stats = plan["executionStats"]?.documentValue {
      lines.append("Returned \(stats["nReturned"]?.intValue ?? 0) documents in \(stats["executionTimeMillis"]?.intValue ?? 0) ms")
      lines.append("Examined \(stats["totalDocsExamined"]?.intValue ?? 0) documents and \(stats["totalKeysExamined"]?.intValue ?? 0) index keys")
    }
    if let winning = plan["queryPlanner"]?[path: "winningPlan"] {
      var stages: [String] = []
      var current: BSON? = winning
      while let stage = current?.documentValue {
        if let name = stage["stage"]?.stringValue {
          var line = name
          if let index = stage["indexName"]?.stringValue { line += " (\(index))" }
          stages.append(line)
        }
        current = stage["inputStage"] ?? stage["queryPlan"]
      }
      if !stages.isEmpty { lines.append("Plan: " + stages.joined(separator: " ← ")) }
    }
    lines.append("")
    lines.append(BSON.document(plan).text(.shell, indent: 2))
    return lines.joined(separator: "\n")
  }

  func completions(context: QueryContext) async -> [Completion] {
    var out = [
      "find", "findOne", "aggregate", "countDocuments", "distinct", "insertOne", "insertMany", "updateOne",
      "updateMany", "deleteOne", "deleteMany", "getIndexes", "createIndex", "sort", "limit", "skip",
    ].map { Completion(text: $0, detail: "method", kind: .function) }
    out += [
      "$match", "$group", "$sort", "$limit", "$skip", "$project", "$set", "$addFields", "$unset", "$unwind", "$lookup",
      "$facet", "$count", "$bucket", "$sortByCount", "$replaceWith", "$merge", "$out", "$eq", "$ne", "$gt", "$gte",
      "$lt", "$lte", "$in", "$nin", "$exists", "$regex", "$and", "$or", "$sum", "$avg", "$min", "$max", "$push",
    ].map { Completion(text: $0, detail: "operator", kind: .keyword) }
    if let database = context.database, let collections = try? await client.listCollections(database: database) {
      out += collections.map { Completion(text: $0.name, detail: "collection", kind: .table) }
    }
    if let collection = context.collection, let database = context.database,
      let fields = try? await fields(of: ObjectRef(database: database, name: collection, kind: .collection))
    {
      out += fields.map { Completion(text: $0.name, detail: $0.typeName, kind: .field) }
    }
    return out
  }
}
