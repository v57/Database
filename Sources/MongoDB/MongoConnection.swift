import Foundation
import CMongoC

/// Async facade over a single MongoDB server connection, backed by the
/// official libmongoc C library.
///
/// NOT Sendable-declared on purpose: it owns a non-Sendable `mongoc_client_t`
/// handle and is driven from the MainActor UI or from tests. All operations
/// are async and every blocking libmongoc/libbson call (client create, ping,
/// runCommand, find, insert, update, delete) runs on a private serial
/// DispatchQueue and is bridged back with an async/await CheckedContinuation,
/// so the MainActor is never blocked.
///
/// Access to the raw client pointer is serialized by that one queue; the
/// pointer lives in an `@unchecked Sendable` box that is only ever read or
/// written on the queue, so sending it across concurrency is safe.
public final class MongoConnection {
  public let config: ConnectionConfig
  /// Serialized libmongoc handle. The pointer is only accessed inside
  /// `runOnQueue`, so the `@unchecked Sendable` box is safe to send across
  /// concurrency.
  private final class ClientBox: @unchecked Sendable {
    var client: OpaquePointer?
  }
  private let box = ClientBox()
  /// Database selected via use(database:), for collection-scoped operations.
  public private(set) var currentDatabase: String?

  /// Every blocking C call is dispatched here so the MainActor never blocks.
  private static let queue = DispatchQueue(label: "dev.database.mongo.libmongoc", qos: .userInitiated)

  public init(config: ConnectionConfig) { self.config = config }

  public var isConnected: Bool { box.client != nil }

  // MARK: - libmongoc lifecycle

  /// libmongoc requires exactly one `mongoc_init()` before any client is made.
  private static let initializeLIBMongoC: Void = {
    mongoc_init()
  }()

  // MARK: - Queue bridge

  /// Runs a blocking closure on the background queue and bridges its result
  /// (or thrown error) back to the caller via a CheckedContinuation. The
  /// closure must only capture Sendable values (config, the box) — never `self`.
  private func runOnQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
      Self.queue.async {
        do { cont.resume(returning: try body()) }
        catch { cont.resume(throwing: error) }
      }
    }
  }

  // MARK: - Lifecycle

  /// Creates the libmongoc client from the connection URI, sets the structured
  /// error API, and verifies the server with a `{ping:1}` on the auth database
  /// (or `admin`). On failure the client is torn down and a MongoDBError is
  /// thrown.
  public func connect() async throws {
    Self.initializeLIBMongoC
    guard config.isValid else { throw MongoDBError.invalidConfig("host must not be empty") }
    let uri = config.connectionString
    let pingDB = (config.authSource ?? "admin")
    let box = self.box
    try await runOnQueue { () -> Void in
      guard let client = mongoc_client_new(uri) else {
        throw MongoDBError.invalidConfig("Could not build a MongoDB client")
      }
      mongoc_client_set_error_api(client, Int32(MONGOC_ERROR_API_VERSION_2))
      var ok = false
      defer { if !ok { mongoc_client_destroy(client) } }
      // Ping the auth database when credentials are present, else admin.
      try Self.ping(client: client, database: pingDB)
      box.client = client
      ok = true
    }
  }

  public func disconnect() async {
    let box = self.box
    try? await runOnQueue { () -> Void in
      if let c = box.client {
        mongoc_client_destroy(c)
        box.client = nil
      }
    }
    currentDatabase = nil
  }

  // MARK: - Databases & collections

  /// Over all database names, alphabetical.
  public func listDatabases() async throws -> [String] {
    let box = self.box
    return try await runOnQueue {
      guard let c = box.client else { throw MongoDBError.notConnected }
      return try Self.databaseNames(client: c)
    }
  }

  /// Switches the active database (UI selection; see `currentDatabase`).
  public func use(database: String) async throws {
    guard box.client != nil else { throw MongoDBError.notConnected }
    currentDatabase = database
  }

  /// Collection names in the current database, optionally filtered by
  /// case-insensitive substring (client-side; collection counts are small).
  public func listCollections(matching search: String = "") async throws -> [String] {
    let box = self.box
    let db = try requireDatabaseName()
    let names = try await runOnQueue {
      guard let c = box.client else { throw MongoDBError.notConnected }
      return try Self.collectionNames(client: c, database: db)
    }
    guard !search.isEmpty else { return names }
    return names.filter { $0.localizedCaseInsensitiveContains(search) }
  }

  // MARK: - Operations

  /// Runs a find on `collection` in the current database. `filter` defaults to
  /// "match everything"; `sort`/`projection` are optional BSON documents
  /// (e.g. `["age": -1]`, `["name": 1]`). Returns ALL matches (small local
  /// datasets); use `limit` to cap.
  public func find(
    in collection: String, filter: Document? = nil, sort: Document? = nil,
    projection: Document? = nil, limit: Int? = nil
  ) async throws -> [Document] {
    let db = try requireDatabaseName()
    let collectionName = collection
    let box = self.box
    return try await runOnQueue {
      guard let c = box.client else { throw MongoDBError.notConnected }
      guard let coll = mongoc_client_get_collection(c, db, collectionName) else {
        throw MongoDBError.invalidQuery("Could not open collection '\(collectionName)'")
      }
      defer { mongoc_collection_destroy(coll) }
      let filterBson = BSONCMap.encode(filter ?? Document())
      defer { bson_destroy(filterBson) }
      var optsBson: UnsafeMutablePointer<bson_t>?
      defer { if let o = optsBson { bson_destroy(o) } }
      if sort != nil || projection != nil || limit != nil {
        let opts = try Self.findOptions(sort: sort, projection: projection, limit: limit)
        optsBson = opts
      }
      let cursor = mongoc_collection_find_with_opts(coll, filterBson, optsBson, nil)
      guard let cursor else { throw MongoDBError.server("Could not start find cursor") }
      defer { mongoc_cursor_destroy(cursor) }
      var result: [Document] = []
      var doc: UnsafePointer<bson_t>? = nil
      var cErr = bson_error_t()
      while mongoc_cursor_next(cursor, &doc) {
        if let d = doc {
          let value = try BSONCMap.decode(UnsafeMutablePointer(mutating: d))
          if case .document(let docValue) = value { result.append(docValue) }
        }
        if let limit, result.count >= limit { break }
      }
      if mongoc_cursor_error(cursor, &cErr) {
        throw MongoDBError.server(Self.errorString(cErr))
      }
      return result
    }
  }

  public func updateMany(in collection: String, filter: Document, update: Document) async throws
    -> MongoWriteResult
  {
    let db = try requireDatabaseName()
    let collectionName = collection
    let box = self.box
    let result: (matched: Int, modified: Int, upsertedId: String?) = try await runOnQueue {
      guard let c = box.client else { throw MongoDBError.notConnected }
      guard let coll = mongoc_client_get_collection(c, db, collectionName) else {
        throw MongoDBError.invalidQuery("Could not open collection '\(collectionName)'")
      }
      defer { mongoc_collection_destroy(coll) }
      let filterBson = BSONCMap.encode(filter)
      defer { bson_destroy(filterBson) }
      let updateBson = BSONCMap.encode(update)
      defer { bson_destroy(updateBson) }
      let reply = bson_new()!
      defer { bson_destroy(reply) }
      var err = bson_error_t()
      let ok = mongoc_collection_update_many(coll, filterBson, updateBson, nil, reply, &err)
      guard ok else { throw MongoDBError.server(Self.errorString(err)) }
      return try Self.parseUpdateReply(reply)
    }
    return MongoWriteResult(
      matchedCount: result.matched, modifiedCount: result.modified, upsertedId: result.upsertedId)
  }

  public func deleteMany(from collection: String, filter: Document) async throws
    -> MongoDeleteResult
  {
    let db = try requireDatabaseName()
    let collectionName = collection
    let box = self.box
    let deleted = try await runOnQueue { () -> Int in
      guard let c = box.client else { throw MongoDBError.notConnected }
      guard let coll = mongoc_client_get_collection(c, db, collectionName) else {
        throw MongoDBError.invalidQuery("Could not open collection '\(collectionName)'")
      }
      defer { mongoc_collection_destroy(coll) }
      let filterBson = BSONCMap.encode(filter)
      defer { bson_destroy(filterBson) }
      let reply = bson_new()!
      defer { bson_destroy(reply) }
      var err = bson_error_t()
      let ok = mongoc_collection_delete_many(coll, filterBson, nil, reply, &err)
      guard ok else { throw MongoDBError.server(Self.errorString(err)) }
      return try Self.parseDeleteReply(reply)
    }
    return MongoDeleteResult(deletedCount: deleted)
  }

  /// Inserts a single document; returns the count accepted.
  public func insertOne(in collection: String, document: Document) async throws
    -> MongoInsertResult
  {
    let db = try requireDatabaseName()
    let collectionName = collection
    let box = self.box
    let inserted = try await runOnQueue { () -> Int in
      guard let c = box.client else { throw MongoDBError.notConnected }
      guard let coll = mongoc_client_get_collection(c, db, collectionName) else {
        throw MongoDBError.invalidQuery("Could not open collection '\(collectionName)'")
      }
      defer { mongoc_collection_destroy(coll) }
      let docBson = BSONCMap.encode(document)
      defer { bson_destroy(docBson) }
      let reply = bson_new()!
      defer { bson_destroy(reply) }
      var err = bson_error_t()
      let ok = mongoc_collection_insert_one(coll, docBson, nil, reply, &err)
      guard ok else { throw MongoDBError.server(Self.errorString(err)) }
      return try Self.parseInsertReply(reply)
    }
    return MongoInsertResult(insertedCount: inserted)
  }

  /// Inserts many documents; returns the count accepted.
  public func insertMany(in collection: String, documents: [Document]) async throws
    -> MongoInsertResult
  {
    let db = try requireDatabaseName()
    let collectionName = collection
    let box = self.box
    let inserted = try await runOnQueue { () -> Int in
      guard let c = box.client else { throw MongoDBError.notConnected }
      guard let coll = mongoc_client_get_collection(c, db, collectionName) else {
        throw MongoDBError.invalidQuery("Could not open collection '\(collectionName)'")
      }
      defer { mongoc_collection_destroy(coll) }
      // libmongoc takes `const bson_t **`. We keep the encoded bson_t pointers
      // alive for the call, then free them.
      let docs: [UnsafeMutablePointer<bson_t>] = documents.map { BSONCMap.encode($0) }
      defer { docs.forEach { bson_destroy($0) } }
      guard !docs.isEmpty else { return 0 }
      var rawPtrs: [UnsafePointer<bson_t>?] = docs.map { UnsafePointer($0) }
      let reply = bson_new()!
      defer { bson_destroy(reply) }
      var err = bson_error_t()
      let ok = rawPtrs.withUnsafeMutableBufferPointer { bp in
        mongoc_collection_insert_many(coll, bp.baseAddress, bp.count, nil, reply, &err)
      }
      guard ok else { throw MongoDBError.server(Self.errorString(err)) }
      return try Self.parseInsertReply(reply)
    }
    return MongoInsertResult(insertedCount: inserted)
  }

  /// Drops an entire database (TestEnv uses this to clean up per-test DBs).
  public func dropDatabase(_ name: String) async throws {
    let box = self.box
    try await runOnQueue { () -> Void in
      guard let c = box.client else { throw MongoDBError.notConnected }
      guard let db = mongoc_client_get_database(c, name) else {
        throw MongoDBError.invalidQuery("Could not open database '\(name)'")
      }
      defer { mongoc_database_destroy(db) }
      var err = bson_error_t()
      let ok = mongoc_database_drop(db, &err)
      guard ok else { throw MongoDBError.server(Self.errorString(err)) }
    }
  }

  // MARK: - Internals

  private func requireDatabaseName() throws -> String {
    guard box.client != nil else { throw MongoDBError.notConnected }
    guard let db = currentDatabase else { throw MongoDBError.notConnected }
    return db
  }

  // MARK: - libmongoc helpers (all run on the queue)

  /// Runs `{ping:1}` on the given database; throws `MongoDBError.server` with
  /// the driver's error message on failure.
  private static func ping(client: OpaquePointer, database: String) throws {
    let cmd = bson_new()!
    defer { bson_destroy(cmd) }
    _ = bson_append_int32(cmd, "ping", 4, 1)
    let reply = bson_new()!
    defer { bson_destroy(reply) }
    var err = bson_error_t()
    let ok = mongoc_client_command_simple(client, database, cmd, nil, reply, &err)
    guard ok else { throw MongoDBError.server(errorString(err)) }
  }

  private static func databaseNames(client: OpaquePointer) throws -> [String] {
    let cmd = bson_new()!
    defer { bson_destroy(cmd) }
    let k = "listDatabases"
    _ = bson_append_int32(cmd, k, Int32(k.utf8.count), 1)
    let reply = bson_new()!
    defer { bson_destroy(reply) }
    var err = bson_error_t()
    let ok = mongoc_client_command_simple(client, "admin", cmd, nil, reply, &err)
    guard ok else { throw MongoDBError.server(errorString(err)) }
    // reply.databases[].name
    var names: [String] = []
    let replyPtr = UnsafeMutablePointer<bson_t>(OpaquePointer(reply))
    var it = bson_iter_t()
    bson_iter_init(&it, replyPtr)
    while bson_iter_next(&it) {
      if String(cString: bson_iter_key(&it)) == "databases" {
        var sub = bson_iter_t()
        if bson_iter_recurse(&it, &sub) {
          while bson_iter_next(&sub) {
            var dsub = bson_iter_t()
            if bson_iter_recurse(&sub, &dsub) {
              while bson_iter_next(&dsub) {
                if String(cString: bson_iter_key(&dsub)) == "name" {
                  var len: UInt32 = 0
                  if let s = bson_iter_utf8(&dsub, &len) {
                    names.append(String(cString: s))
                  }
                }
              }
            }
          }
        }
      }
    }
    return names.sorted()
  }

  private static func collectionNames(client: OpaquePointer, database: String) throws -> [String] {
    guard let db = mongoc_client_get_database(client, database) else {
      throw MongoDBError.invalidQuery("Could not open database '\(database)'")
    }
    defer { mongoc_database_destroy(db) }
    let cmd = bson_new()!
    defer { bson_destroy(cmd) }
    let k = "listCollections"
    _ = bson_append_int32(cmd, k, Int32(k.utf8.count), 1)
    let reply = bson_new()!
    defer { bson_destroy(reply) }
    var err = bson_error_t()
    let ok = mongoc_database_command_simple(db, cmd, nil, reply, &err)
    guard ok else { throw MongoDBError.server(errorString(err)) }
    // reply.cursor.firstBatch[].name
    var names: [String] = []
    let replyPtr = UnsafeMutablePointer<bson_t>(OpaquePointer(reply))
    var it = bson_iter_t()
    bson_iter_init(&it, replyPtr)
    while bson_iter_next(&it) {
      if String(cString: bson_iter_key(&it)) == "cursor" {
        var sub = bson_iter_t()
        if bson_iter_recurse(&it, &sub) {
          while bson_iter_next(&sub) {
            if String(cString: bson_iter_key(&sub)) == "firstBatch" {
              var arr = bson_iter_t()
              if bson_iter_recurse(&sub, &arr) {
                while bson_iter_next(&arr) {
                  var doc = bson_iter_t()
                  if bson_iter_recurse(&arr, &doc) {
                    while bson_iter_next(&doc) {
                      if String(cString: bson_iter_key(&doc)) == "name" {
                        var len: UInt32 = 0
                        if let s = bson_iter_utf8(&doc, &len) {
                          names.append(String(cString: s))
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    return names.sorted()
  }

  private static func findOptions(sort: Document?, projection: Document?, limit: Int?) throws
    -> UnsafeMutablePointer<bson_t>
  {
    let opts = BSONCMap.encode(BSONDocument())
    if let sort {
      let sortBson = BSONCMap.encode(sort)
      _ = bson_append_document(opts, "sort", 4, sortBson)
      bson_destroy(sortBson)
    }
    if let projection {
      let projBson = BSONCMap.encode(projection)
      _ = bson_append_document(opts, "projection", 10, projBson)
      bson_destroy(projBson)
    }
    if let limit {
      _ = bson_append_int32(opts, "limit", 5, Int32(limit))
    }
    return opts
  }

  private static func parseUpdateReply(_ reply: UnsafeMutablePointer<bson_t>) throws
    -> (matched: Int, modified: Int, upsertedId: String?)
  {
    let value = try BSONCMap.decode(reply)
    guard case .document(let doc) = value else {
      throw MongoDBError.server("Unexpected update reply")
    }
    let matched = Self.intField(doc, "matchedCount")
    let modified = Self.intField(doc, "modifiedCount")
    let upsertedId = Self.extendedJSONString(doc, "upserted", [
      "upserted", "upsertedId", "upsertedID",
    ])
    return (matched, modified, upsertedId)
  }

  private static func parseDeleteReply(_ reply: UnsafeMutablePointer<bson_t>) throws -> Int {
    let value = try BSONCMap.decode(reply)
    guard case .document(let doc) = value else {
      throw MongoDBError.server("Unexpected delete reply")
    }
    return Self.intField(doc, "deletedCount")
  }

  private static func parseInsertReply(_ reply: UnsafeMutablePointer<bson_t>) throws -> Int {
    let value = try BSONCMap.decode(reply)
    guard case .document(let doc) = value else {
      throw MongoDBError.server("Unexpected insert reply")
    }
    // insert_one/many reply: insertedCount or n.
    return Self.intField(doc, "insertedCount") != 0 ? Self.intField(doc, "insertedCount")
      : Self.intField(doc, "n")
  }

  private static func intField(_ doc: BSONDocument, _ key: String) -> Int {
    switch doc[key] {
    case .int32(let i): return Int(i)
    case .int64(let i): return Int(i)
    case .double(let d): return Int(d)
    default: return 0
    }
  }

  private static func extendedJSONString(_ doc: BSONDocument, _ key: String, _ aliases: [String])
    -> String?
  {
    for name in [key] + aliases {
      if let value = doc[name], value != .null {
        return String(describing: value)
      }
    }
    return nil
  }

  private static func errorString(_ err: bson_error_t) -> String {
    withUnsafePointer(to: err.message) {
      String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self))
    }
  }
}
