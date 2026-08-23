import Foundation
import MongoSwift
import NIO

/// Async facade over a single MongoDB server connection.
/// NOT Sendable-declared on purpose: it owns a non-Sendable MongoClient and is
/// driven from the MainActor UI or from tests. All operations are async.
public final class MongoConnection {
  public let config: ConnectionConfig
  private var client: MongoClient?
  private var eventLoopGroup: MultiThreadedEventLoopGroup?
  public private(set) var currentDatabase: String?

  public init(config: ConnectionConfig) { self.config = config }

  public var isConnected: Bool { client != nil }

  /// Creates the client and verifies the server with a ping. On failure the
  /// client is torn down and a MongoDBError is thrown.
  public func connect() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let c: MongoClient
    do {
      // v1.3.1 requires an explicit NIO EventLoopGroup.
      c = try MongoClient(config.connectionString, using: group)
    } catch {
      group.shutdownGracefully { _ in }
      throw MongoDBError.invalidConfig("Cannot build client: \(error.localizedDescription)")
    }
    do {
      // Ping the auth database when credentials are present, else admin.
      let pingDB = config.authSource ?? "admin"
      _ = try await c.db(pingDB).runCommand(["ping": 1])
    } catch {
      try? await c.close()
      group.shutdownGracefully { _ in }
      throw MongoDBError.server("Connection failed: \(error.localizedDescription)")
    }
    client = c
    eventLoopGroup = group
  }

  public func disconnect() async {
    if let c = client { try? await c.close() }
    client = nil
    currentDatabase = nil
    if let g = eventLoopGroup {
      g.shutdownGracefully { _ in }
      eventLoopGroup = nil
    }
  }

  public func listDatabases() async throws -> [String] {
    guard let c = client else { throw MongoDBError.notConnected }
    do { return try await c.listDatabaseNames().sorted() } catch {
      throw MongoDBError.server(error.localizedDescription)
    }
  }

  public func use(database: String) async throws {
    guard client != nil else { throw MongoDBError.notConnected }
    currentDatabase = database
  }

  /// Collection names in the current database, optionally filtered by
  /// case-insensitive substring (client-side; collection counts are small).
  public func listCollections(matching search: String = "") async throws -> [String] {
    guard let c = client, let db = currentDatabase else { throw MongoDBError.notConnected }
    do {
      let names = try await c.db(db).listCollectionNames().sorted()
      guard !search.isEmpty else { return names }
      return names.filter { $0.localizedCaseInsensitiveContains(search) }
    } catch { throw MongoDBError.server(error.localizedDescription) }
  }

  /// Runs a find on `collection` in the current database. `filter` defaults
  /// to "match everything"; `sort`/`projection` are optional BSON documents
  /// (e.g. `["age": -1]`, `["name": 1]`). Returns ALL matches (small local
  /// datasets); use `limit` to cap.
  public func find(
    in collection: String, filter: Document? = nil, sort: Document? = nil,
    projection: Document? = nil, limit: Int? = nil
  ) async throws -> [Document] {
    let coll = try requireCollection(collection)
    do {
      var options = FindOptions()
      options.sort = sort
      options.projection = projection
      options.limit = limit
      let cursor = try await coll.find(filter ?? [:], options: options)
      return try await cursor.toArray()
    } catch { throw MongoDBError.server(error.localizedDescription) }
  }

  public func updateMany(in collection: String, filter: Document, update: Document) async throws
    -> MongoWriteResult
  {
    let coll = try requireCollection(collection)
    do {
      guard let r = try await coll.updateMany(filter: filter, update: update) else {
        return MongoWriteResult(matchedCount: 0, modifiedCount: 0, upsertedId: nil)
      }
      return MongoWriteResult(
        matchedCount: r.matchedCount, modifiedCount: r.modifiedCount,
        upsertedId: r.upsertedID.map { String(describing: $0) })
    } catch { throw MongoDBError.server(error.localizedDescription) }
  }

  public func deleteMany(from collection: String, filter: Document) async throws
    -> MongoDeleteResult
  {
    let coll = try requireCollection(collection)
    do {
      guard let r = try await coll.deleteMany(filter) else {
        return MongoDeleteResult(deletedCount: 0)
      }
      return MongoDeleteResult(deletedCount: r.deletedCount)
    } catch { throw MongoDBError.server(error.localizedDescription) }
  }

  private func requireCollection(_ name: String) throws -> MongoCollection<Document> {
    guard let c = client, let db = currentDatabase else { throw MongoDBError.notConnected }
    return c.db(db).collection(name)
  }
}
