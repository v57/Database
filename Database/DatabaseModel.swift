import Foundation
import MongoDB
import Observation
import PostgreSQL
import Redis
import SQLite
import SQLQuery
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
  /// Non-Mongo sessions (Redis/PostgreSQL/SQLite),
  /// tagged by engine. Only one of `session`/`alternateSession` is live at a time.
  var alternateSession: AlternateSession?
  var isConnecting = false
  var statusMessage = ""
  /// The last connect failure, surfaced by the sidebar as an alert (the
  /// window subtitle alone was too easy to miss). Cleared on the next attempt.
  var connectionError: String?

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
  /// The last load/query failure for the selected collection, shown in the
  /// documents pane; nil after the next successful load. While set,
  /// `documents` may still hold the previous query's results (the pane marks
  /// them as stale) — but never another collection's.
  var queryError: String?
  /// True while a collection's first page is loading after selection, so the
  /// pane shows progress instead of a premature "empty" state.
  var isLoadingDocuments = false
  /// Bumped by every load/query; a result whose generation is no longer
  /// current (a slower, older query or a previous collection) is dropped
  /// instead of overwriting newer results.
  private var queryGeneration = 0
  /// Redis: keys of the selected logical database (sidebar + list source).
  var redisEntries: [RedisKeyEntry] = []
  /// Redis: detail rows of the selected key, rendered as one document.
  var redisSelectedEntry: RedisKeyEntry?

  // MARK: - Pagination (Mongo / PostgreSQL / SQLite)
  /// How many documents/rows the initial load and each "load more" fetch.
  private let pageSize = 100
  /// Rows currently loaded in `documents` (the offset for the next page).
  private(set) var loadedCount = 0
  /// True when the last page filled `pageSize`, so more rows likely exist.
  private(set) var hasMore = false
  /// Guards against concurrent load-more fetches (scroll can fire rapidly).
  var isLoadingMore = false
  /// The last load-more failure; the footer shows it with a Retry button
  /// (its scroll trigger has already fired and won't fire again by itself).
  var loadMoreError: String?

  /// Name of the live connection, if any.
  var connectionName: String? {
    if let session { return session.config.name }
    switch alternateSession {
    case .postgresql(let c): return c.config.name
    case .redis(let c): return c.config.name
    case .sqlite(let c): return c.config.name
    case nil: return nil
    }
  }

  /// The engine of the live session, if any.
  var activeEngine: DatabaseEngine? {
    if session != nil { return .mongodb }
    return alternateSession?.engine
  }

  /// True when a session of ANY engine is open (sidebar gating, status dot).
  var isSessionActive: Bool { session != nil || alternateSession != nil }

  /// Inline edits, Add Field, Update and Delete write back to the server only
  /// for MongoDB; SQL rows and Redis keys are read-only in the UI.
  var canEditDocuments: Bool { session != nil }

  /// What the sidebar/pane calls the things listed under a database.
  var containerNoun: (singular: String, plural: String) {
    switch activeEngine {
    case .redis: ("key", "keys")
    case .postgresql, .sqlite: ("table", "tables")
    case .mongodb, nil: ("collection", "collections")
    }
  }

  /// Redis key listings stop at this many keys (SCAN cap in RedisConnection).
  static let redisKeyLimit = 1000

  /// True when a Redis database's key list hit the cap, so the sidebar can
  /// say that more keys exist than are shown.
  func isKeyListTruncated(_ database: String) -> Bool {
    activeEngine == .redis && (collectionsByDatabase[database]?.count ?? 0) >= Self.redisKeyLimit
  }

  /// What the pane calls one loaded item, for status/empty-state copy.
  var itemNoun: (singular: String, plural: String) {
    switch activeEngine {
    case .redis: ("key", "keys")
    case .postgresql, .sqlite: ("row", "rows")
    case .mongodb, nil: ("document", "documents")
    }
  }

  // MARK: - Connect / disconnect

  /// Connects with engine-tagged settings, loads the top-level tree, and
  /// selects the default database.
  func connect(_ settings: EngineSettings) async {
    await disconnect()
    // Sidebar order comes from the history as of connecting; it is not
    // re-sorted while the session runs (see markCollectionUsed).
    loadOpenHistory()
    isConnecting = true
    connectionError = nil
    statusMessage =
      settings.engine == .sqlite
      ? "Opening \((settings.host as NSString).lastPathComponent)…"
      : "Connecting to \(settings.host):\(settings.port)…"
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
        let initial = config.databaseIndex.map(String.init) ?? indexes.first ?? "0"
        await select(database: initial)

      case .sqlite(let config):
        let conn = SQLiteConnection(config: config)
        try await conn.connect()
        alternateSession = .sqlite(conn)
        statusMessage = "Connected to \(config.name)" + (conn.isReadOnly ? " (read-only)" : "")
        let dbs = try await conn.listDatabases()
        databases = dbs
        await select(database: dbs.first ?? "main")


      }
    } catch {
      // A half-open session (connected, then listing failed) is torn down so
      // the sidebar never shows a "connected" row with no databases.
      await disconnect()
      statusMessage = "Connection failed: \(error.localizedDescription)"
      connectionError = error.localizedDescription
    }
  }

  /// Opens a throwaway connection with `settings` and closes it again; throws
  /// the driver error on failure. Used by the form's "Test Connection" button.
  /// Does not touch the live session.
  func testConnection(_ settings: EngineSettings) async throws {
    switch settings {
    case .mongodb(let config):
      let conn = MongoConnection(config: config)
      try await conn.connect()
      await conn.disconnect()
    case .postgresql(let config):
      let conn = PostgresConnection(config: config)
      try await conn.connect()
      await conn.disconnect()
    case .redis(let config):
      let conn = RedisConnection(config: config)
      try await conn.connect()
      await conn.disconnect()
    case .sqlite(let config):
      let conn = SQLiteConnection(config: config)
      try await conn.connect()
      await conn.disconnect()
    }
  }

  /// Legacy overload so existing MongoDB-only call sites keep compiling.
  func connect(_ config: ConnectionConfig) async { await connect(EngineSettings.mongodb(config)) }

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
    currentQuery = QuerySpec(filter: nil, sort: nil, projection: nil)
    queryError = nil
    redisEntries = []
    loadedCount = 0
    hasMore = false
    isLoadingMore = false
    loadMoreError = nil
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
  /// Never switches the live session's database: Mongo lists another
  /// database's collections directly, PostgreSQL/Redis use a short-lived side
  /// connection (a PostgreSQL connection is bound to one database; a Redis
  /// SELECT would redirect the live session). Queries therefore always keep
  /// running against `selectedDatabase`.
  func loadCollections(for database: String) async {
    guard isSessionActive, collectionsByDatabase[database] == nil else { return }
    do {
      let names: [String]
      if let mongo = session {
        names = try await mongo.listCollections(in: database)
      } else if case .postgresql(let pg) = alternateSession {
        if database == pg.currentDatabase {
          names = try await pg.listTables()
        } else {
          var config = pg.config
          config.defaultDatabase = database
          let side = PostgresConnection(config: config)
          try await side.connect()
          do {
            names = try await side.listTables()
            await side.disconnect()
          } catch {
            await side.disconnect()
            throw error
          }
        }
      } else if case .redis(let redis) = alternateSession {
        if database == redis.currentDatabase.map(String.init) {
          names = try await redis.listKeys()
        } else {
          var config = redis.config
          config.databaseIndex = Int(database)
          let side = RedisConnection(config: config)
          try await side.connect()
          do {
            names = try await side.listKeys()
            await side.disconnect()
          } catch {
            await side.disconnect()
            throw error
          }
        }
      } else if case .sqlite(let sqlite) = alternateSession {
        names = try await sqlite.listTables()
      } else {
        return
      }
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

  /// Persists usage only: the in-memory dates that order the sidebar are
  /// refreshed on the next connect, so rows don't jump while being worked in.
  private func markDatabaseOpened(_ database: String) {
    let now = Date.now
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
    let isNewTarget = selectedCollection != collection || selectedDatabase != database
    // A query typed for one collection rarely fits another (SQL: unknown
    // columns; Mongo: silently empty results), so each collection opens
    // unfiltered. The pane clears its query bar on the same change.
    if isNewTarget { currentQuery = QuerySpec(filter: nil, sort: nil, projection: nil) }
    // Never leave the previous collection's rows on screen under the new
    // collection's name — clear them before loading.
    if isNewTarget { documents = [] }
    selectedCollection = collection
    queryError = nil
    queryGeneration &+= 1
    let generation = queryGeneration
    isLoadingDocuments = true
    defer { if generation == queryGeneration { isLoadingDocuments = false } }
    // Selecting a collection is "opening"/"viewing", NOT usage — only an
    // explicit query request (applyQuery/loadMore) bumps the sidebar sort
    // timestamp. Reset pagination so a fresh collection starts at page 0;
    // the first page is then loaded below and re-sets loadedCount/hasMore.
    resetPagination()
    do {
      if selectedDatabase != database {
        if let mongo = session {
          try await mongo.use(database: database)
        } else if case .postgresql(let pg) = alternateSession {
          try await pg.use(database: database)
        } else if case .redis(let redis) = alternateSession {
          try await redis.use(database: database)
        } else if case .sqlite(let sqlite) = alternateSession {
          try await sqlite.use(database: database)
        }
        selectedDatabase = database
        collections = collectionsByDatabase[database] ?? []
      }

      if case .redis(let redis) = alternateSession {
        let entry = try await redis.entry(for: collection)
        guard generation == queryGeneration else { return }
        redisSelectedEntry = entry
        documents = [Self.document(from: entry)]
        statusMessage = "\(entry.typeName) · \(Self.ttlText(entry.ttl))"
      } else {
        let docs = try await loadFirstPage(collection: collection)
        guard generation == queryGeneration else { return }
        documents = docs
        loadedCount = docs.count
        hasMore = docs.count >= pageSize
        statusMessage = loadedSummary(in: collection)
      }
    } catch {
      guard generation == queryGeneration else { return }
      documents = []
      queryError = error.localizedDescription
      statusMessage = error.localizedDescription
    }
  }

  /// Redis TTL in words: -1 = no expiry, -2 = the key is gone.
  static func ttlText(_ ttl: Int) -> String {
    switch ttl {
    case -1: "No expiry"
    case -2: "Key no longer exists"
    default: "Expires in \(ttl)s"
    }
  }

  /// "100+ documents" while more pages exist — the count is what is loaded,
  /// not a server-side total. The collection itself is the window title.
  private func loadedSummary(in collection: String? = nil) -> String {
    let noun = documents.count == 1 ? itemNoun.singular : itemNoun.plural
    let count = hasMore ? "\(documents.count)+" : "\(documents.count)"
    return "\(count) \(noun)"
  }

  /// Selects a collection in the current database (documents refresh path).
  func select(collection: String) async {
    await select(collection: collection, in: selectedDatabase ?? "")
  }

  // MARK: - Mutations (MongoDB only for now; SQL/Redis get their own flows later)

  /// Number of documents `filter` matches in the selected collection — the
  /// real impact of an Update/Delete, not a capped preview.
  func countMatching(filter: String) async throws -> Int {
    guard let session, let selectedCollection else { throw MongoDBError.notConnected }
    let f = try Self.filterDocument(fromText: filter)
    return try await session.countDocuments(in: selectedCollection, filter: f)
  }

  /// Validates the Update text without running it, so a typo is reported
  /// before the confirmation dialog rather than after.
  func validateUpdate(_ update: String) throws {
    _ = try Self.updateDocument(fromText: update)
  }

  /// Filter text for Update/Delete; blank means "every document" (the
  /// parser rejects empty input, so a blank filter used to fail outright).
  private static func filterDocument(fromText text: String) throws -> Document {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Document() }
    return try BSONSupport.document(fromQuery: text)
  }

  /// Update text in the same relaxed syntax as the Filter (`{ $set: { a: 1 } }`).
  /// Strict JSON is tried first so extended JSON (`{ "$oid": … }`, `$date`),
  /// which only the strict decoder understands, keeps working.
  private static func updateDocument(fromText text: String) throws -> Document {
    if let strict = try? BSONSupport.document(fromJSON: text) { return strict }
    return try BSONSupport.document(fromQuery: text)
  }

  /// Runs updateMany against the selected collection and refreshes the list.
  func runUpdate(filter: String, update: String) async throws -> MongoWriteResult {
    guard let session, let selectedCollection else { throw MongoDBError.notConnected }
    let f = try Self.filterDocument(fromText: filter)
    let u = try Self.updateDocument(fromText: update)
    let result = try await session.updateMany(in: selectedCollection, filter: f, update: u)
    await refreshAfterMutation(session, selectedCollection)
    statusMessage = "Updated \(result.matchedCount) matched, \(result.modifiedCount) modified"
    return result
  }

  /// Runs deleteMany against the selected collection and refreshes the list.
  func runDelete(filter: String) async throws -> MongoDeleteResult {
    guard let session, let selectedCollection else { throw MongoDBError.notConnected }
    let f = try Self.filterDocument(fromText: filter)
    let result = try await session.deleteMany(from: selectedCollection, filter: f)
    await refreshAfterMutation(session, selectedCollection)
    statusMessage = "Deleted \(result.deletedCount) document(s)"
    return result
  }

  /// Writes one value of the document at `index` back to the server
  /// (`updateOne`-style `{ _id } → { $set: { "a.0.b": value } }`), then mirrors
  /// it in the loaded copy. Throws — leaving the loaded copy untouched — when
  /// the engine is read-only, the document has no `_id`, or the path can't be
  /// expressed as a dotted `$set` key.
  func updateDocument(_ index: Int, at path: [BSONPathSegment], to value: BSON) async throws {
    guard let session, let selectedCollection else { throw EditError.readOnly }
    guard documents.indices.contains(index) else { return }
    guard let id = documents[index]["_id"] else { throw EditError.missingID }
    let dotted = try Self.dottedPath(path)
    var filter = Document()
    filter["_id"] = id
    var fields = Document()
    fields[dotted] = value
    var update = Document()
    update["$set"] = .document(fields)
    let result = try await session.updateMany(
      in: selectedCollection, filter: filter, update: update)
    guard result.matchedCount > 0 else { throw EditError.documentGone }
    // Re-index after the await: the list may have been replaced meanwhile.
    guard documents.indices.contains(index), documents[index]["_id"] == id else { return }
    var docs = documents
    docs[index] = BSONPath.setting(value, at: path, in: docs[index])
    documents = docs
    selectedDocument = docs[index]
    statusMessage = "Saved \(path.map(\.description).joined(separator: "."))"
  }

  /// Adds a new top-level field to the document at `index` on the server.
  func addField(to index: Int, key: String, value: BSON) async throws {
    guard documents.indices.contains(index), !key.isEmpty else { return }
    try await updateDocument(index, at: [.key(key)], to: value)
  }

  /// `[.key("a"), .index(0), .key("b")]` → `a.0.b`. Keys containing `.` or
  /// starting with `$` can't be addressed by a `$set` path.
  private static func dottedPath(_ path: [BSONPathSegment]) throws -> String {
    var parts: [String] = []
    for segment in path {
      switch segment {
      case .key(let key):
        guard !key.isEmpty, !key.contains("."), !key.hasPrefix("$") else {
          throw EditError.unaddressableKey(key)
        }
        parts.append(key)
      case .index(let i): parts.append(String(i))
      }
    }
    guard !parts.isEmpty else { throw EditError.unaddressableKey("") }
    return parts.joined(separator: ".")
  }

  enum EditError: LocalizedError {
    case readOnly, missingID, documentGone, unaddressableKey(String)

    var errorDescription: String? {
      switch self {
      case .readOnly: "Editing is only supported for MongoDB collections."
      case .missingID: "This document has no _id, so the change can't be saved."
      case .documentGone: "The document no longer exists on the server. Refresh and try again."
      case .unaddressableKey(let key):
        "The field name “\(key)” contains “.” or starts with “$”, so it can't be edited here."
      }
    }
  }

  /// Applies the current query (filter/sort/projection) to the selected
  /// collection and stores the results in `documents`. Works for every engine:
  /// Mongo (find), SQL (filter→WHERE, sort→ORDER BY, project→columns),
  /// Redis (filter=key glob, sort/project hidden). A successful query
  /// execution counts as collection usage and bumps the sidebar sort.
  func applyQuery() async throws -> [Document] {
    queryGeneration &+= 1
    let generation = queryGeneration
    do {
      let docs = try await runCurrentQuery(generation: generation)
      if generation == queryGeneration { queryError = nil }
      return docs
    } catch {
      if generation == queryGeneration { queryError = error.localizedDescription }
      throw error
    }
  }

  private func runCurrentQuery(generation: Int) async throws -> [Document] {
    guard let selectedCollection else { throw MongoDBError.notConnected }
    let docs: [Document]
    if let session {
      docs = try await findCurrentMongo(in: selectedCollection, session: session, limit: pageSize)
    } else if case .postgresql(let pg) = alternateSession {
      let rows = try await pg.select(sql: try selectSQL(in: selectedCollection), limit: pageSize)
      docs = rows.map { Self.document(from: $0) }
    } else if case .sqlite(let sqlite) = alternateSession {
      let rows = try await sqlite.select(sql: try selectSQL(in: selectedCollection), limit: pageSize)
      docs = rows.map { Self.document(from: $0) }
    } else if case .redis(let redis) = alternateSession {
      // The Redis Filter text is already a SCAN MATCH glob (built by the key
      // filter box via KeyGlob.query), so it is used verbatim.
      let entries = try await redis.entries(pattern: currentQuery.filter)
      docs = entries.map { Self.document(from: $0) }
      redisEntries = entries
    } else {
      throw MongoDBError.notConnected
    }
    // A newer query (or another collection) superseded this one meanwhile.
    guard generation == queryGeneration else { return docs }
    // Pagination resets only once the new results are in: a failing query
    // keeps the previous page (and its load-more state) consistent.
    resetPagination()
    documents = docs
    loadedCount = docs.count
    hasMore = docs.count >= pageSize && activeEngine != .redis
    if activeEngine == .redis, let pattern = currentQuery.filter {
      // A key filter lists matching keys of the whole database, not the
      // key selected in the sidebar — say so.
      let noun = docs.count == 1 ? itemNoun.singular : itemNoun.plural
      statusMessage = "\(docs.count) \(noun) matching \(pattern)"
    } else {
      statusMessage = loadedSummary(in: selectedCollection)
    }
    // A successful query execution counts as collection + database usage.
    let db = selectedDatabase ?? ""
    markCollectionUsed(db, selectedCollection)
    markDatabaseOpened(db)
    return docs
  }

  /// Loads the next page of the current query and appends to `documents`.
  func loadMoreDocuments() async {
    guard !isLoadingMore, hasMore, let selectedCollection else { return }
    guard activeEngine != .redis else { return }  // not paginated
    isLoadingMore = true
    loadMoreError = nil
    defer { isLoadingMore = false }
    let generation = queryGeneration
    do {
      let offset = loadedCount
      let page: [Document]
      if let session {
        page = try await findCurrentMongo(
          in: selectedCollection, session: session, skip: offset, limit: pageSize)
      } else if case .postgresql(let pg) = alternateSession {
        let rows = try await pg.select(
          sql: try selectSQL(in: selectedCollection), limit: pageSize, offset: offset)
        page = rows.map { Self.document(from: $0) }
      } else if case .sqlite(let sqlite) = alternateSession {
        let rows = try await sqlite.select(
          sql: try selectSQL(in: selectedCollection), limit: pageSize, offset: offset)
        page = rows.map { Self.document(from: $0) }
      } else {
        return
      }
      // A new query replaced the list meanwhile: this page belongs to the old one.
      guard generation == queryGeneration, loadedCount == offset else { return }
      documents.append(contentsOf: page)
      loadedCount += page.count
      hasMore = page.count >= pageSize
      statusMessage = loadedSummary(in: selectedCollection)
    } catch {
      guard generation == queryGeneration else { return }
      loadMoreError = error.localizedDescription
    }
  }

  /// Loads the FIRST page of the current query for the selected collection,
  /// WITHOUT touching `documents` (the caller assigns it). Drives the initial
  /// load on collection select and the post-mutation refresh.
  private func loadFirstPage(collection: String) async throws -> [Document] {
    if let session {
      return try await findCurrentMongo(in: collection, session: session, limit: pageSize)
    } else if case .postgresql(let pg) = alternateSession {
      let rows = try await pg.select(sql: try selectSQL(in: collection), limit: pageSize)
      return rows.map { Self.document(from: $0) }
    } else if case .sqlite(let sqlite) = alternateSession {
      let rows = try await sqlite.select(sql: try selectSQL(in: collection), limit: pageSize)
      return rows.map { Self.document(from: $0) }
    } else if case .redis(let redis) = alternateSession {
      let entries = try await redis.entries(pattern: currentQuery.filter)
      redisEntries = entries
      return entries.map { Self.document(from: $0) }
    }
    throw MongoDBError.notConnected
  }

  /// Documents matching `filter` (capped at `limit`), for the delete preview.
  func previewDelete(filter: String, limit: Int? = 500) async throws -> [Document] {
    guard let session, let selectedCollection else { throw MongoDBError.notConnected }
    let f = try Self.filterDocument(fromText: filter)
    return try await session.find(in: selectedCollection, filter: f, limit: limit)
  }

  /// Builds the SQL statement the current query bar implies. Each field is
  /// compiled per its text: Mongo-style JSON-like input (same dialect as the
  /// MongoDB query bar) becomes SQL — Filter→WHERE, Sort→ORDER BY,
  /// Projection→SELECT column list, with inline-escaped values — and anything
  /// else stays a raw SQL fragment spliced verbatim. Compile errors throw so
  /// the query bar can surface them; table names come from sidebar metadata,
  /// never from query text.
  private func selectSQL(in collection: String) throws -> String {
    switch activeEngine {
    case .postgresql: return try postgresSelectSQL(in: collection)
    case .mongodb, .redis, .sqlite: return try sqliteSelectSQL(in: collection)
    case nil: return "SELECT * FROM \(Self.quotedIdentifier(collection))"
    }
  }

  /// SQLite SELECT built from the query bar. JSON-like input is compiled by
  /// SQLQueryCompiler (raw text passes through as a WHERE/ORDER BY body; JSON
  /// projections are finally applied, raw column lists stay unapplied).
  private func sqliteSelectSQL(in collection: String) throws -> String {
    let table = Self.quotedIdentifier(collection)
    let query = try SQLQueryCompiler.compile(
      filter: currentQuery.filter, sort: currentQuery.sort, projection: currentQuery.projection)
    var sql = "SELECT \(query.columns) FROM \(table)"
    if let filter = query.whereBody, !filter.isEmpty { sql += " WHERE \(filter)" }
    if let sort = query.orderBy, !sort.isEmpty { sql += " ORDER BY \(sort)" }
    return sql
  }

  /// PostgreSQL variant of `sqliteSelectSQL`: the compiled SQL parts are
  /// identical — only the FROM-table quoting differs (schema.table splits
  /// into two quoted identifiers, not one).
  private func postgresSelectSQL(in collection: String) throws -> String {
    let table = collection.split(separator: ".").map { Self.quotedIdentifier(String($0)) }
      .joined(separator: ".")
    let query = try SQLQueryCompiler.compile(
      filter: currentQuery.filter, sort: currentQuery.sort, projection: currentQuery.projection)
    var sql = "SELECT \(query.columns) FROM \(table)"
    if let filter = query.whereBody, !filter.isEmpty { sql += " WHERE \(filter)" }
    if let sort = query.orderBy, !sort.isEmpty { sql += " ORDER BY \(sort)" }
    return sql
  }



  /// MongoDB documents via the current query bar: filter/sort/projection are
  /// parsed as MongoDB query syntax. Does NOT touch the display list.
  private func findCurrentMongo(
    in collection: String, session: MongoConnection, skip: Int? = nil, limit: Int? = nil
  ) async throws -> [Document] {
    let docFilter = try currentQuery.filter.flatMap { try BSONSupport.document(fromQuery: $0) }
    let docSort = try currentQuery.sort.flatMap { try BSONSupport.document(fromQuery: $0) }
    let docProj = try currentQuery.projection.flatMap { try BSONSupport.document(fromQuery: $0) }
    return try await session.find(
      in: collection, filter: docFilter, sort: docSort, projection: docProj, limit: limit,
      skip: skip)
  }

  /// Re-runs the current query from the first page so the list (and its
  /// pagination state) reflects a mutation.
  private func refreshAfterMutation(_ session: MongoConnection, _ collection: String) async {
    queryGeneration &+= 1
    let generation = queryGeneration
    guard let docs = try? await findCurrentMongo(in: collection, session: session, limit: pageSize)
    else { return }
    guard generation == queryGeneration else { return }
    resetPagination()
    documents = docs
    loadedCount = docs.count
    hasMore = docs.count >= pageSize
  }

  /// Resets pagination cursor state (new collection or new query).
  private func resetPagination() {
    loadedCount = 0
    hasMore = false
    isLoadingMore = false
    loadMoreError = nil
  }

  // MARK: - Row/key -> Document conversion (shared UI rendering)

  /// PostgreSQL row as a display document: column/value pairs in the SELECT's
  /// column order (walking `row.values` would give hash order instead).
  static func document(from row: PostgresRowData) -> Document {
    var doc = Document()
    for key in row.columns {
      guard let value = row.values[key] else { continue }
      doc[key] = bson(fromPostgres: value)
    }
    return doc
  }

  /// Redis key detail as a display document (type/value/ttl rows).
  static func document(from entry: RedisKeyEntry) -> Document {
    var doc = Document()
    // The key name comes first: a filtered key list without it was a column
    // of anonymous values.
    doc["key"] = .string(entry.key)
    doc["type"] = .string(entry.typeName)
    doc["value"] = .string(entry.displayValue)
    doc["ttl"] = .int32(Int32(clamping: entry.ttl))
    return doc
  }

  /// SQLite row as a display document: column/value pairs in the SELECT's
  /// column order (walking `row.values` would give hash order instead).
  static func document(from row: SQLiteRowData) -> Document {
    var doc = Document()
    for key in row.columns {
      guard let value = row.values[key] else { continue }
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
struct QuerySpec: Equatable {
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
