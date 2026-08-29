import Foundation

@testable import MongoDB

/// Integration-test support: localhost server, per-test databases so tests can
/// run in parallel, each db dropped on the way out. Seeding and dropping go
/// through the `MongoConnection` facade (insertMany / dropDatabase), so the test
/// target has no MongoDB driver imports.
enum TestEnv {
  static let host = "127.0.0.1"
  static let port: UInt16 = 27017

  static func config() -> ConnectionConfig {
    // directConnection: the local server is a replica set advertising
    // docker-compose hostnames (mongo/mongo2/mongo3) that don't resolve
    // on the host. Bypass topology discovery and talk to 127.0.0.1
    // directly, otherwise every operation hits a 30s server-selection
    // timeout trying to resolve those names.
    ConnectionConfig(name: "test", host: host, port: port, directConnection: true)
  }

  static func freshDBName(_ label: String) -> String {
    "dbclient_\(label)_\(UUID().uuidString.prefix(8))"
  }

  /// Opens a connected facade for seeding/dropping.
  static func makeConnection() async throws -> MongoConnection {
    let conn = MongoConnection(config: config())
    try await conn.connect()
    return conn
  }

  /// Seed a collection via the facade's insertMany. `use(database:)` selects the
  /// target database so collection-scoped ops address it.
  static func seed(database: String, collection: String, docs: [Document]) async throws {
    let conn = try await makeConnection()
    defer { await conn.disconnect() }
    try await conn.use(database: database)
    _ = try await conn.insertMany(in: collection, documents: docs)
  }

  /// Drop a per-test database via the facade's dropDatabase.
  static func drop(database: String) async throws {
    let conn = try await makeConnection()
    defer { await conn.disconnect() }
    try await conn.dropDatabase(database)
  }
}
