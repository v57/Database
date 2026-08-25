import Foundation

@testable import PostgreSQL

/// Integration-test support: localhost PostgreSQL from docker-compose
/// (postgres/postgres). Each test gets its own SCHEMA (the Postgres analogue
/// of the MongoDB per-test database) dropped on the way out, so parallel tests
/// stay safe.
enum TestEnv {
  static let host = "127.0.0.1"
  static let port: UInt16 = 5432
  static let user = "postgres"
  static let password = "postgres"

  static func config(database: String? = nil) -> PostgresConnectionConfig {
    PostgresConnectionConfig(
      name: "test", host: host, port: port, username: user, password: password,
      defaultDatabase: database)
  }

  static func freshSchemaName(_ label: String) -> String {
    // Lowercase: unquoted identifiers fold to lower in PostgreSQL, and
    // information_schema returns the folded name.
    "dbclient_\(label)_\(UUID().uuidString.prefix(8))".lowercased()
  }

  /// Connects and returns a ready-to-use facade.
  static func connect(_ config: PostgresConnectionConfig) async throws -> PostgresConnection {
    let conn = PostgresConnection(config: config)
    try await conn.connect()
    return conn
  }

  /// Creates `schema` and returns it; call in test body before creating tables.
  static func makeSchema(_ conn: PostgresConnection, _ schema: String) async throws {
    try await conn.execute(sql: "CREATE SCHEMA IF NOT EXISTS \(schema)")
  }

  /// Drops `schema` with everything in it — call in defer/cleanup paths.
  static func dropSchema(_ conn: PostgresConnection, _ schema: String) async {
    try? await conn.execute(sql: "DROP SCHEMA IF EXISTS \(schema) CASCADE")
  }
}
