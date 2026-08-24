import Foundation
import MongoDB
import Observation
import PostgreSQL
import Redis
import SQLite
import SwiftData

/// Observable app state: the active session and the three-column navigation state.
@Observable @MainActor final class DatabaseModel {
  /// SwiftData context shared with the app container; persists last-opened
  /// history used for sidebar sorting.
  private let modelContext: ModelContext

  /// db name -> last opened date
  private var databaseLastOpened: [String: Date] = [:]
  /// db name -> (collection name -> last query-execution date)
  private var collectionLastUsed: [String: [String: Date]] = [:]

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
    loadOpenHistory()
  }

  var session: MongoConnection?
  /// Non-Mongo sessions (Redis/PostgreSQL), tagged by engine. Only one of
  /// `session`/`alternateSession` is live at a time.
  var alternateSession: AlternateSession?
  var isConnecting = false
  var statusMessage = ""

  var databases: [String] = []
  var selectedDatabase: String?

  var collections: [String] = []
  var collectionSearch = ""
  var selectedCollection: String?

  /// Per-database collection names, fetched lazily as databases are expanded
  /// in the sidebar; also drives sidebar search filtering.
  private(set) var collectionsByDatabase: [String: [String]] = [:]

  var documents: [Document] = []
  var selectedDocument: Document?
  /// The active query (filter/sort/projection) driving the document list.
  var currentQuery = QuerySpec(filter: nil, sort: nil, projection: nil)
  /// Redis: keys of the selected logical database (sidebar + list source).
  var redisEntries: [RedisKeyEntry] = []
  /// Redis: detail rows of the selected key, rendered as one document.
  var redisSelectedEntry: RedisKeyEntry?

  /// The engine of the live session, if any.
  var activeEngine: DatabaseEngine? {
    if session != nil { return .mongodb }
    return alternateSession?.engine
  }

  /// True when a session of ANY engine is open (sidebar gating, status dot).
  var isSessionActive: Bool { session != nil || alternateSession != nil }

  // MARK: - Connect / disconnect

  /// Connects with engine-tagged settings, loads the top-level tree, and
  /// selects the default database.
  func connect(_ settings: EngineSettings) async {
    await disconnect()
    isConnecting = true
    statusMessage = "Connecting to \(settings.host):\(settings.port)…"
    defer { isConnecting = false }
    do {
      switch settings {
      case .mongodb(let config):
        let conn = MongoConnection(config: config)
        try await conn.connect()
        session = conn
        statusMessage = "Connected to \(config.name)"
        databases = try await conn.listDatabases()
        let initial = config.defaultDatabase ?? databases.first ?? "admin"
        await select(database: initial)

      case .postgresql(let config):
        let conn = PostgresConnection(config: config)
        try await conn.connect()
        alternateSession = .postgresql(conn)
        statusMessage = "Connected to \(config.name)"
        let dbs = try await conn.listDatabases().map(\.description)
        databases = dbs
        let initial = config.defaultDatabase ?? dbs.first ?? "postgres"
        await select(database: initial)

      case .redis(let config):
        let conn = RedisConnection(config: config)
        try await conn.connect()
        alternateSession = .redis(conn)
        statusMessage = "Connected to \(config.name)"
        let indexes = try await conn.listDatabases().map(\.description)
        databases = indexes
        let initial =
          config.databaseIndex.map(String.init)
          ?? indexes.first
          ?? "0"
        await select(database: initial)

      case .sqlite(let config):
        let conn = SQLiteConnection(config: config)
        try await conn.connect()
        alternateSession = .sqlite(conn)
        statusMessage =
          "Connected to \(config.name)" + (conn.isReadOnly ? " (read-only)" : "")
        let dbs = try await conn.listDatabases()
        databases = dbs
        await select(database: dbs.first ?? "main")
      }
    } catch {
      statusMessage = "Connection failed: \(error.localizedDescription)"
    }
  }

  /// Legacy overload so existing MongoDB-only call sites keep compiling.
  func connect(_ config: ConnectionConfig) async {
    await connect(EngineSettings.mongodb(config))
  }

  /// Opens a SQLite file delivered by the system (Finder "Open With…", dock
  /// drop): reuses a saved record for the same path or saves a new one, then
  /// connects. Mirrors what the create form would do for that file.
  func openSQLiteFile(at path: String) async {
    let records = (try? modelContext.fetch(FetchDescriptor<ConnectionRecord>())) ?? []
    let standardized = (path as NSString).standardizingPath
    if let existing = records.first(where: {
      $0.engineKind == .sqlite && ($0.host as NSString).standardizingPath == standardized
    }) {
      await connect(existing.toSettings())
      return
    }
    let filename = (path as NSString).lastPathComponent
    let name = (filename as NSString).deletingPathExtension
    let record = ConnectionRecord(
      name: name.isEmpty ? filename : name, host: standardized, port: 0, engine: .sqlite)
    modelContext.insert(record)
    try? modelContext.save()
    await connect(record.toSettings())
  }

  func disconnect() async {
    if let session { await session.disconnect() }
    session = nil
    if let alternateSession { await alternateSession.close() }
    alternateSession = nil
    databases = []
    selectedDatabase = nil
    collections = []
    collectionsByDatabase = [:]
    selectedCollection = nil
    documents = []
    selectedDocument = nil
    redisEntries = []
    statusMessage = ""
  }

  // MARK: - Database selection

  /// Switches the active database and reloads its children.
  func select(database: String) async {
    guard isSessionActive else { return }
    do {
      if let mongo = session {
        try await mongo.use(database: database)
      } else if case .redis(let redis) = alternateSession {
        try await redis.use(database: database)
      } else if case .postgresql(let pg) = alternateSession {
        try await pg.use(database: database)
      } else if case .sqlite(let sqlite) = alternateSession {
        try await sqlite.use(database: database)
      }
      selectedDatabase = database
      collectionSearch = ""
      await reloadChildren(of: database)
      markDatabaseOpened(database)
    } catch { statusMessage = error.localizedDescription }
  }

  /// Loads children for `database` into the caches + current selection.
  private func reloadChildren(of database: String) async {
    guard isSessionActive else { return }
    if let mongo = session {
      collections = (try? await mongo.listCollections()) ?? []
      collectionsByDatabase[database] = collections
    } else if case .redis(let redis) = alternateSession {
      let keys = (try? await redis.listKeys()) ?? []
      collectionsByDatabase[database] = keys
      collections = keys
      redisEntries = (try? await redis.entries(matching: "")) ?? []
    } else if case .postgresql(let pg) = alternateSession {
      collections = (try? await pg.listTables()) ?? []
      collectionsByDatabase[database] = collections
    } else if case .sqlite(let sqlite) = alternateSession {
      collections = (try? await sqlite.listTables()) ?? []
      collectionsByDatabase[database] = collections
    }
  }

  // MARK: - Sidebar lazy loading

  /// Loads (once) and caches collections for a database; called when the
  /// sidebar expands a database row.
  func loadCollections(for database: String) async {
    guard let session, collectionsByDatabase[database] == nil else { return }
    do {
      try await session.use(database: database)
      let names = try await session.listCollections()
      collectionsByDatabase[database] = names
      if database == selectedDatabase { collections = names }
    } catch { statusMessage = error.localizedDescription }
  }

  /// Loads collections for every database (cached), so the sidebar search
  /// can filter across all of them. No-op for already-loaded databases.
  func loadAllCollections() async { for db in databases { await loadCollections(for: db) } }

  /// Cached collections of `database`, filtered by the plain (non-$) search
  /// terms — every term must match (AND) — then sorted by last query
  /// execution, most-recent first; never-used last (alphabetical).
  func collections(for database: String) -> [String] {
    let names = collectionsByDatabase[database] ?? []
    let terms = searchTerms.collectionTerms
    let filtered =
      terms.isEmpty
      ? names
      : names.filter { name in terms.allSatisfy { name.localizedCaseInsensitiveContains($0) } }
    let used = collectionLastUsed[database] ?? [:]
    return filtered.sorted(by: recentFirstComparator(used))
  }

  /// Parsed view of the sidebar search field for the current state.
  var searchTerms: SearchTerms { SearchTerms(collectionSearch) }

  // MARK: - Open/usage history (SwiftData)

  private func loadOpenHistory() {
    var dbs: [String: Date] = [:]
    if let records = try? modelContext.fetch(FetchDescriptor<DatabaseOpenRecord>()) {
      for r in records { dbs[r.databaseName] = r.lastOpened }
    }
    databaseLastOpened = dbs

    var colls: [String: [String: Date]] = [:]
    if let records = try? modelContext.fetch(FetchDescriptor<CollectionOpenRecord>()) {
      for r in records { colls[r.databaseName, default: [:]][r.collectionName] = r.lastUsed }
    }
    collectionLastUsed = colls
  }

  private func markDatabaseOpened(_ database: String) {
    let now = Date.now
    databaseLastOpened[database] = now
    let record: DatabaseOpenRecord
    if let existing = try? modelContext.fetch(
      FetchDescriptor<DatabaseOpenRecord>(predicate: #Predicate { $0.databaseName == database })
    ).first {
      record = existing
    } else {
      record = DatabaseOpenRecord(databaseName: database)
      modelContext.insert(record)
    }
    record.lastOpened = now
    try? modelContext.save()
  }

  /// Records a query execution against `collection` for sidebar sorting.
  private func markCollectionUsed(_ database: String, _ collection: String) {
    let now = Date.now
    collectionLastUsed[database, default: [:]][collection] = now
    let record: CollectionOpenRecord
    if let existing = try? modelContext.fetch(
      FetchDescriptor<CollectionOpenRecord>(
        predicate: #Predicate { $0.databaseName == database && $0.collectionName == collection })
    ).first {
      record = existing
    } else {
      record = CollectionOpenRecord(databaseName: database, collectionName: collection)
      modelContext.insert(record)
    }
    record.lastUsed = now
    try? modelContext.save()
  }

  /// Sort closure: most-recent date first, never-seen last (alphabetical).
  private func recentFirstComparator(_ dates: [String: Date]) -> (String, String) -> Bool {
    { a, b in
      switch (dates[a], dates[b]) {
      case (let x?, let y?): return x > y
      case (nil, _?): return false
      case (_?, nil): return true
      case (nil, nil): return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
      }
    }
  }

  /// Databases sorted most-recently-opened first; never-opened last.
  var sortedDatabases: [String] { databases.sorted(by: recentFirstComparator(databaseLastOpened)) }

  // MARK: - Document selection & queries

  /// Selects a collection in an explicit database (sidebar path), switching
  /// the active database first when needed.
  func select(collection: String, in database: String) async {
    guard isSessionActive else { return }
    do {
      if selectedDatabase != database {
        if let mongo = session {
          try await mongo.use(database: database)
        } else if case .postgresql(let pg) = alternateSession {
          try await pg.use(database: database)
        } else if case .sqlite(let sqlite) = alternateSession {
          try await sqlite.use(database: database)
        }
        selectedDatabase = database
        collections = collectionsByDatabase[database] ?? []
      }
      selectedCollection = collection

      if let mongo = session {
        documents = try await mongo.find(in: collection, limit: 100)
        statusMessage = "\(documents.count) document(s) in \(collection)"
      } else if case .postgresql(let pg) = alternateSession {
        let rows = try await pg.select(sql: "SELECT * FROM \(collection)", limit: 100)
        documents = rows.map { Self.document(from: $0) }
        statusMessage = "\(rows.count) row(s) in \(collection)"
      } else if case .sqlite(let sqlite) = alternateSession {
        // Table names come from sqlite_master; quote as identifier so names
        // with dots/spaces/quotes survive.
        let rows = try await sqlite.select(sql: "SELECT * FROM \(Self.quotedIdentifier(collection)) LIMIT 100")
        documents = rows.map { Self.document(from: $0) }
        statusMessage = "\(rows.count) row(s) in \(collection)"
      } else if case .redis(let redis) = alternateSession {
        let entry = try await redis.entry(for: collection)
        redisSelectedEntry = entry
        documents = [Self.document(from: entry)]
        statusMessage = "\(entry.typeName) · TTL \(entry.ttl)s"
      }
      // Selecting is "opening", not usage — only query execution
      // (applyQuery) bumps the sidebar sort timestamp.
      markDatabaseOpened(database)
    } catch { statusMessage = error.localizedDescription }
  }

  /// Selects a collection in the current database (documents refresh path).
  func select(collection: String) async {
    await select(collection: collection, in: selectedDatabase ?? "")
  }

  // MARK: - Mutations (MongoDB only for now; SQL/Redis get their own flows later)

  /// Runs updateMany against the selected collection and refreshes the list.
  func runUpdate(filter: String, update: String) async throws -> MongoWriteResult {
    guard let session, let selectedCollection else { throw MongoDBError.notConnected }
    let f = try BSONSupport.document(fromQuery: filter)
    // Update operators ($set, $inc, ...) must stay strict JSON.
    let u = try BSONSupport.document(fromJSON: update)
    let result = try await session.updateMany(in: selectedCollection, filter: f, update: u)
    statusMessage = "Updated \(result.matchedCount) matched, \(result.modifiedCount) modified"
    await refreshAfterMutation(session, selectedCollection)
    return result
  }

  /// Runs deleteMany against the selected collection and refreshes the list.
  func runDelete(filter: String) async throws -> MongoDeleteResult {
    guard let session, let selectedCollection else { throw MongoDBError.notConnected }
    let f = try BSONSupport.document(fromQuery: filter)
    let result = try await session.deleteMany(from: selectedCollection, filter: f)
    statusMessage = "Deleted \(result.deletedCount) document(s)"
    await refreshAfterMutation(session, selectedCollection)
    return result
  }

  /// Replaces one value in the in-memory document at `index` (local edit
  /// only — not persisted to the server until write-back is added).
  func updateDocument(_ index: Int, at path: [BSONPathSegment], to value: BSON) {
    guard documents.indices.contains(index) else { return }
    var docs = documents
    docs[index] = BSONPath.setting(value, at: path, in: docs[index])
    documents = docs
    selectedDocument = docs[index]
  }

  /// Adds a new key/value field to the in-memory document at `index`.
  func addField(to index: Int, key: String, value: BSON) {
    guard documents.indices.contains(index), !key.isEmpty else { return }
    updateDocument(index, at: [.key(key)], to: value)
  }

  /// Applies the current query (filter/sort/projection) to the selected
  /// collection and stores the results in `documents`.
  func applyQuery() async throws -> [Document] {
    guard let session, let selectedCollection else { throw MongoDBError.notConnected }
    let docs = try await findCurrent(in: selectedCollection, session: session)
    documents = docs
    // A successful query execution counts as collection usage.
    markCollectionUsed(selectedDatabase ?? "", selectedCollection)
    return docs
  }

  /// Documents matching `filter` (capped at `limit`), for the delete preview.
  func previewDelete(filter: String, limit: Int? = 500) async throws -> [Document] {
    guard let session, let selectedCollection else { throw MongoDBError.notConnected }
    let f = try BSONSupport.document(fromQuery: filter)
    return try await session.find(in: selectedCollection, filter: f, limit: limit)
  }

  /// Runs the current query against `collection` without touching the
  /// display list — shared by `applyQuery` and post-mutation refresh.
  private func findCurrent(in collection: String, session: MongoConnection) async throws
    -> [Document]
  {
    let docFilter = try currentQuery.filter.flatMap { try BSONSupport.document(fromQuery: $0) }
    let docSort = try currentQuery.sort.flatMap { try BSONSupport.document(fromQuery: $0) }
    let docProj = try currentQuery.projection.flatMap { try BSONSupport.document(fromQuery: $0) }
    return try await session.find(
      in: collection, filter: docFilter, sort: docSort, projection: docProj)
  }

  /// Re-runs the current query so the list reflects a mutation.
  private func refreshAfterMutation(_ session: MongoConnection, _ collection: String) async {
    if let docs = try? await findCurrent(in: collection, session: session) { documents = docs }
  }

  // MARK: - Row/key -> Document conversion (shared UI rendering)

  /// PostgreSQL row as a display document: column/value pairs.
  static func document(from row: PostgresRowData) -> Document {
    var doc = Document()
    for (key, value) in row.values {
      doc[key] = bson(fromPostgres: value)
    }
    return doc
  }

  /// Redis key detail as a display document (type/value/ttl rows).
  static func document(from entry: RedisKeyEntry) -> Document {
    var doc = Document()
    doc["type"] = .string(entry.typeName)
    doc["value"] = .string(entry.displayValue)
    doc["ttl"] = .int32(Int32(clamping: entry.ttl))
    return doc
  }

  /// SQLite row as a display document: column/value pairs.
  static func document(from row: SQLiteRowData) -> Document {
    var doc = Document()
    for (key, value) in row.values {
      doc[key] = bson(fromSQLite: value)
    }
    return doc
  }

  private static func bson(fromPostgres value: PostgresValue) -> BSON {
    switch value {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let n): return .int64(n)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .json(let s): return .string(s)
    case .date(let date): return .datetime(date)
    case .bytes(let bytes): return .binary(try! BSONBinary(data: Data(bytes), subtype: .generic))
    }
  }

  private static func bson(fromSQLite value: SQLiteValue) -> BSON {
    switch value {
    case .null: return .null
    case .int(let n): return .int64(n)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .bytes(let bytes): return .binary(try! BSONBinary(data: Data(bytes), subtype: .generic))
    }
  }

  /// Double-quotes a SQLite identifier, escaping embedded quotes.
  static func quotedIdentifier(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

/// Tagged union over the non-Mongo live sessions.
@MainActor enum AlternateSession {
  case postgresql(PostgresConnection)
  case redis(RedisConnection)
  case sqlite(SQLiteConnection)

  var engine: DatabaseEngine {
    switch self {
    case .postgresql: .postgresql
    case .redis: .redis
    case .sqlite: .sqlite
    }
  }

  func close() async {
    switch self {
    case .postgresql(let c): await c.disconnect()
    case .redis(let c): await c.disconnect()
    case .sqlite(let c): await c.disconnect()
    }
  }
}

/// The active query driving the document list: raw filter/sort/projection
/// text, parsed with `QueryParser` (JSON, JS-style, or bare `key: value`).
struct QuerySpec {
  var filter: String?
  var sort: String?
  var projection: String?

  var isEmpty: Bool {
    filter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
      && sort?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
      && projection?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
  }
}

/// Parsed sidebar search: tokens starting with `$` filter database names,
/// plain tokens filter collection names. Order-independent; all terms of a
/// kind must match (AND). Example: `$maindb users` == `users $maindb` shows
/// databases whose name contains "maindb" with collections containing "users".
struct SearchTerms {
  let databaseTerms: [String]
  let collectionTerms: [String]

  var isSearching: Bool { !databaseTerms.isEmpty || !collectionTerms.isEmpty }
  var hasDatabaseTerms: Bool { !databaseTerms.isEmpty }

  init(_ raw: String) {
    let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    databaseTerms = tokens.filter { $0.hasPrefix("$") }.map { String($0.dropFirst()) }.filter {
      !$0.isEmpty
    }
    collectionTerms = tokens.filter { !$0.hasPrefix("$") }
  }
}
