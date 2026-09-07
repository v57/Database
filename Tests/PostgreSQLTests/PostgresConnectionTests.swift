import Foundation
import Testing

@testable import PostgreSQL

/// Integration tests against the localhost compose PostgreSQL. Each test
/// creates its own schema and drops it on the way out.
@Suite(.serialized) struct PostgresConnectionTests {
  @Test func connectListsDatabasesAndDisconnects() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    #expect(conn.isConnected)
    let dbs = try await conn.listDatabases()
    #expect(dbs.contains("postgres"))
    await conn.disconnect()
    #expect(!conn.isConnected)
  }

  @Test func selectDecodesRowTypes() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    let rows = try await conn.select(
      sql: "SELECT 1 AS n, 'txt' AS s, true AS b, 2.5::float8 AS f, NULL AS nothing", limit: 10)
    #expect(rows.count == 1)
    #expect(rows[0]["n"] == .int(1))
    #expect(rows[0]["s"] == .string("txt"))
    #expect(rows[0]["b"] == .bool(true))
    #expect(rows[0]["f"] == .double(2.5))
    #expect(rows[0]["nothing"] == .null)
  }

  @Test func executeCreateInsertSelectDrop() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    let schema = TestEnv.freshSchemaName("crud")
    await TestEnv.dropSchema(conn, schema)
    try await TestEnv.makeSchema(conn, schema)

    try await conn.execute(
      sql: "CREATE TABLE \(schema).people (id serial PRIMARY KEY, name text, age int)")
    try await conn.execute(sql: "INSERT INTO \(schema).people (name, age) VALUES ('ada', 36)")
    try await conn.execute(
      sql: "INSERT INTO \(schema).people (name, age) VALUES ('grace', 45), ('edsger', 68)")

    let count = try await conn.count(sql: "SELECT count(*)::bigint FROM \(schema).people")
    #expect(count == 3)

    let rows = try await conn.select(
      sql: "SELECT name FROM \(schema).people WHERE age > 40 ORDER BY name")
    #expect(rows.count == 2)
    #expect(rows[0]["name"] == .string("edsger"))
    #expect(rows[1]["name"] == .string("grace"))

    try await conn.execute(sql: "DELETE FROM \(schema).people WHERE age > 40")
    let after = try await conn.count(sql: "SELECT count(*)::bigint FROM \(schema).people")
    #expect(after == 1)

    await TestEnv.dropSchema(conn, schema)
    await conn.disconnect()
  }

  @Test func listTablesSeesCreatedTable() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    let schema = TestEnv.freshSchemaName("tables")
    await TestEnv.dropSchema(conn, schema)
    try await TestEnv.makeSchema(conn, schema)

    // Nothing yet in the fresh schema.
    let before = try await conn.listTables(matching: schema)
    #expect(before.isEmpty)

    try await conn.execute(sql: "CREATE TABLE \(schema).widgets (id int)")
    let after = try await conn.listTables(matching: schema)
    #expect(after == ["\(schema).widgets"])

    await TestEnv.dropSchema(conn, schema)
    await conn.disconnect()
  }

  @Test func useRecordsSelection() async throws {
    let conn = try await TestEnv.connect(TestEnv.config(database: "postgres"))
    defer { await conn.disconnect() }
    try await conn.use(database: "template1")
    #expect(conn.currentDatabase == "template1")
  }

  @Test func badSQLThrowsServerError() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    do {
      _ = try await conn.select(sql: "SELECT * FROM definitely_missing_table_42")
      Issue.record("Expected server error")
    } catch let error as PostgreSQLError {
      if case .server = error {} else { Issue.record("Expected .server, got \(error)") }
    }
  }

  @Test func selectHonorsLimitAndOffset() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    let schema = TestEnv.freshSchemaName("page")
    await TestEnv.dropSchema(conn, schema)
    try await TestEnv.makeSchema(conn, schema)

    try await conn.execute(sql: "CREATE TABLE \(schema).nums (v int)")
    // Insert 12 rows 0..11 via a VALUES list.
    let values = (0..<12).map { "(\($0))" }.joined(separator: ", ")
    try await conn.execute(sql: "INSERT INTO \(schema).nums (v) VALUES \(values)")

    let p1 = try await conn.select(
      sql: "SELECT v FROM \(schema).nums ORDER BY v", limit: 5, offset: 0)
    #expect(p1.map { $0["v"] } == [.int(0), .int(1), .int(2), .int(3), .int(4)])
    let p2 = try await conn.select(
      sql: "SELECT v FROM \(schema).nums ORDER BY v", limit: 5, offset: 5)
    #expect(p2.map { $0["v"] } == [.int(5), .int(6), .int(7), .int(8), .int(9)])
    let p3 = try await conn.select(
      sql: "SELECT v FROM \(schema).nums ORDER BY v", limit: 5, offset: 10)
    #expect(p3.map { $0["v"] } == [.int(10), .int(11)])
    await conn.disconnect()
  }

  @Test func connectFailsWithBadCredentials() async {
    let bad = PostgresConnectionConfig(
      name: "bad", host: "127.0.0.1", port: 5432, username: "postgres",
      password: "definitely-wrong-password")
    let conn = PostgresConnection(config: bad)
    await #expect(throws: (any Error).self) { try await conn.connect() }
  }
}
