import Foundation

/// One field of an index.
public struct IndexKey: Hashable, Sendable {
  public var field: String
  public var isDescending: Bool
  /// What an index other than an ordered one does with the field: "text", "hashed", "2dsphere"…
  public var method: String?

  public init(field: String, isDescending: Bool = false, method: String? = nil) {
    self.field = field
    self.isDescending = isDescending
    self.method = method
  }
}

/// An index a table or collection already has, with the statements that remove it and put it back as it was.
public struct TableIndex: Identifiable, Hashable, Sendable {
  public var name: String
  public var keys: [IndexKey]
  public var isUnique: Bool
  /// The primary key, or an index a constraint depends on: the server won't drop it on its own.
  public var isProtected: Bool
  public var dropStatement: String
  public var restoreStatement: String

  public var id: String { name }

  public init(
    name: String, keys: [IndexKey], isUnique: Bool, isProtected: Bool, dropStatement: String, restoreStatement: String
  ) {
    self.name = name
    self.keys = keys
    self.isUnique = isUnique
    self.isProtected = isProtected
    self.dropStatement = dropStatement
    self.restoreStatement = restoreStatement
  }
}

/// An index to create.
public struct NewIndex: Hashable, Sendable {
  public var name: String
  public var keys: [IndexKey]
  public var isUnique: Bool

  public init(name: String = "", keys: [IndexKey], isUnique: Bool = false) {
    self.name = name
    self.keys = keys
    self.isUnique = isUnique
  }
}

extension EngineKind {
  /// Whether the Indexes sheet can list and edit this engine's indexes.
  public var supportsIndexes: Bool {
    switch self {
    case .mongodb, .postgres, .mysql, .mariadb, .sqlite: true
    case .sqlserver, .duckdb, .redis, .cassandra, .scylla: false
    }
  }
}

/// A session that can list a table's indexes and write the statements that change them. The changes run as those
/// statements, so what the review shows is exactly what runs.
public protocol IndexSession: DatabaseSession {
  func indexes(of ref: ObjectRef) async throws -> [TableIndex]
  /// The index's name when it's left empty, as the engine's tools would name it.
  func defaultIndexName(for index: NewIndex, on ref: ObjectRef) -> String
  func createStatement(for index: NewIndex, on ref: ObjectRef) -> String
  func dropStatement(forIndexNamed name: String, on ref: ObjectRef) -> String
}

extension IndexSession {
  /// Runs a statement from `TableIndex` or `createStatement(for:on:)`.
  public func runIndexStatement(_ statement: String, on ref: ObjectRef) async throws {
    if profile.isReadOnly { throw ReadOnlyError() }
    _ = try await run(statement, context: QueryContext(database: ref.database, schema: ref.schema))
  }
}

// MARK: - MongoDB

extension MongoSession: IndexSession {
  public func indexes(of ref: ObjectRef) async throws -> [TableIndex] {
    let documents = try await client.listIndexes(database: ref.database ?? "", collection: ref.name)
    return documents.compactMap { document in
      guard let name = document["name"]?.stringValue, let key = document["key"]?.documentValue else { return nil }
      let keys = key.map { field, value -> IndexKey in
        if let method = value.stringValue { return IndexKey(field: field, method: method) }
        return IndexKey(field: field, isDescending: (value.doubleValue ?? 1) < 0)
      }
      var options = document
      for internalField in ["v", "ns", "key"] { options[internalField] = nil }
      return TableIndex(
        name: name, keys: keys, isUnique: document["unique"]?.boolValue ?? false, isProtected: name == "_id_",
        dropStatement: dropStatement(forIndexNamed: name, on: ref),
        restoreStatement: "\(Self.shellName(ref.name)).createIndex(\(key.text()), \(options.text()))")
    }
  }

  public func defaultIndexName(for index: NewIndex, on ref: ObjectRef) -> String {
    index.keys.map { "\($0.field)_\($0.isDescending ? "-1" : "1")" }.joined(separator: "_")
  }

  public func createStatement(for index: NewIndex, on ref: ObjectRef) -> String {
    var keys = BSONDocument()
    for key in index.keys { keys[key.field] = .int32(key.isDescending ? -1 : 1) }
    var options: BSONDocument = ["name": .string(index.name.isEmpty ? defaultIndexName(for: index, on: ref) : index.name)]
    if index.isUnique { options["unique"] = .bool(true) }
    return "\(Self.shellName(ref.name)).createIndex(\(keys.text()), \(options.text()))"
  }

  public func dropStatement(forIndexNamed name: String, on ref: ObjectRef) -> String {
    "\(Self.shellName(ref.name)).dropIndex(\(BSON.string(name).text()))"
  }
}

// MARK: - SQL

extension SQLSession: IndexSession {
  public func indexes(of ref: ObjectRef) async throws -> [TableIndex] {
    guard let query = dialect.indexesQuery(ref) else { return [] }
    let rows = try await executor.run(query, database: ref.database).last?.rows ?? []
    var indexes: [TableIndex] = []
    for row in rows where row.count >= 6 {
      guard let name = row[0].stringValue else { continue }
      let key = IndexKey(field: row[3].stringValue ?? "", isDescending: Self.truthy(row[4]))
      if let last = indexes.indices.last, indexes[last].name == name {
        indexes[last].keys.append(key)
      } else {
        indexes.append(
          TableIndex(
            name: name, keys: [key], isUnique: Self.truthy(row[1]), isProtected: Self.truthy(row[2]),
            dropStatement: dialect.dropIndex(name, on: ref),
            // Filled below when the catalog doesn't keep the definition.
            restoreStatement: row[5].stringValue ?? ""))
      }
    }
    for index in indexes.indices where indexes[index].restoreStatement.isEmpty {
      let new = NewIndex(name: indexes[index].name, keys: indexes[index].keys, isUnique: indexes[index].isUnique)
      indexes[index].restoreStatement = createStatement(for: new, on: ref)
    }
    return indexes
  }

  public func defaultIndexName(for index: NewIndex, on ref: ObjectRef) -> String {
    ([ref.name] + index.keys.map(\.field) + ["idx"]).joined(separator: "_")
  }

  public func createStatement(for index: NewIndex, on ref: ObjectRef) -> String {
    let name = index.name.isEmpty ? defaultIndexName(for: index, on: ref) : index.name
    let keys = index.keys.map { dialect.quote($0.field) + ($0.isDescending ? " DESC" : "") }.joined(separator: ", ")
    return "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX \(dialect.quote(name)) ON \(dialect.qualified(ref)) (\(keys))"
  }

  public func dropStatement(forIndexNamed name: String, on ref: ObjectRef) -> String {
    dialect.dropIndex(name, on: ref)
  }
}
