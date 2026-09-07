import Foundation
import Testing

@testable import SQLite

/// Integration tests against real temp SQLite files — no server required.
/// Every test owns its file, so parallel execution is safe.
@Suite struct SQLiteConnectionTests {
  @Test func missingFileFailsToConnect() async {
    let path = TestEnv.freshFile("missing")
    let conn = SQLiteConnection(config: TestEnv.config(label: "missing", path: path))
    do {
      try await conn.connect()
      Issue.record("connect must fail for a missing file")
    } catch {
      guard case .fileNotFound = error as? SQLiteError else {
        Issue.record("expected fileNotFound, got \(error)")
        return
      }
    }
  }

  @Test func randomFileIsRejectedAsNotADatabase() async throws {
    let path = TestEnv.freshFile("random")
    try Data("definitely not a sqlite file".utf8).write(to: URL(fileURLWithPath: path))
    defer { TestEnv.remove(path) }
    let conn = SQLiteConnection(config: TestEnv.config(label: "random", path: path))
    do {
      try await conn.connect()
      Issue.record("connect must reject a non-database file")
    } catch {
      guard case .notADatabase = error as? SQLiteError else {
        Issue.record("expected notADatabase, got \(error)")
        return
      }
    }
  }

  @Test func connectListsSingleMainDatabase() async throws {
    let path = TestEnv.freshFile("main")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "main", path: path))
    defer { await conn.disconnect() }
    #expect(conn.isConnected)
    #expect(conn.currentDatabase == "main")
    #expect(try await conn.listDatabases() == ["main"])
  }

  @Test func useOnlyAcceptsMain() async throws {
    let path = TestEnv.freshFile("use")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "use", path: path))
    defer { await conn.disconnect() }
    try await conn.use(database: "main")
    #expect(conn.currentDatabase == "main")
    do {
      try await conn.use(database: "other")
      Issue.record("use(database:) must reject anything but main")
    } catch {
      guard case .unsupported = error as? SQLiteError else {
        Issue.record("expected unsupported, got \(error)")
        return
      }
    }
  }

  @Test func listTablesIncludesViewsAndFilters() async throws {
    let path = TestEnv.freshFile("tables")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "tables", path: path))
    defer { await conn.disconnect() }
    try await conn.execute(
      sql: """
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, score REAL);
        CREATE VIEW active_users AS SELECT id, name FROM users WHERE score >= 0;
        """)
    let tables = try await conn.listTables()
    #expect(tables.contains("users"))
    #expect(tables.contains("active_users"))
    #expect(!tables.contains { $0.hasPrefix("sqlite_") })

    let filtered = try await conn.listTables(matching: "active")
    #expect(filtered == ["active_users"])
  }

  @Test func selectDecodesAllStorageClasses() async throws {
    let path = TestEnv.freshFile("types")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "types", path: path))
    defer { await conn.disconnect() }
    try await conn.execute(
      sql: """
        CREATE TABLE types (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT);
        INSERT INTO types VALUES (42, 3.5, 'hello', X'00FF', NULL);
        """)
    let rows = try await conn.select(sql: "SELECT i, r, t, b, n FROM types")
    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row["i"] == .int(42))
    #expect(row["r"] == .double(3.5))
    #expect(row["t"] == .string("hello"))
    #expect(row["b"] == .bytes([0x00, 0xFF]))
    #expect(row["n"] == .null)
  }

  @Test func selectHonorsLimit() async throws {
    let path = TestEnv.freshFile("limit")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "limit", path: path))
    defer { await conn.disconnect() }
    try await conn.execute(sql: "CREATE TABLE nums (v INTEGER)")
    for i in 0..<20 { try await conn.execute(sql: "INSERT INTO nums VALUES (\(i))") }
    let rows = try await conn.select(sql: "SELECT v FROM nums", limit: 5)
    #expect(rows.count == 5)
  }

  @Test func selectHonorsOffset() async throws {
    let path = TestEnv.freshFile("offset")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "offset", path: path))
    defer { await conn.disconnect() }
    try await conn.execute(sql: "CREATE TABLE nums (v INTEGER)")
    for i in 0..<12 { try await conn.execute(sql: "INSERT INTO nums VALUES (\(i))") }

    // Page 1 (limit 5, offset 0) then page 2 (limit 5, offset 5) then the tail.
    let p1 = try await conn.select(sql: "SELECT v FROM nums ORDER BY v", limit: 5, offset: 0)
    #expect(p1.map { $0["v"] } == [.int(0), .int(1), .int(2), .int(3), .int(4)])
    let p2 = try await conn.select(sql: "SELECT v FROM nums ORDER BY v", limit: 5, offset: 5)
    #expect(p2.map { $0["v"] } == [.int(5), .int(6), .int(7), .int(8), .int(9)])
    let p3 = try await conn.select(sql: "SELECT v FROM nums ORDER BY v", limit: 5, offset: 10)
    #expect(p3.map { $0["v"] } == [.int(10), .int(11)])
  }

  @Test func executeRunsDMLAndCountReflectsChanges() async throws {
    let path = TestEnv.freshFile("dml")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "dml", path: path))
    defer { await conn.disconnect() }
    try await conn.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, v TEXT)")
    try await conn.execute(sql: "INSERT INTO items (v) VALUES ('a'), ('b'), ('c')")
    #expect(try await conn.count(sql: "SELECT count(*) FROM items") == 3)

    try await conn.execute(sql: "UPDATE items SET v = 'x' WHERE v = 'b'")
    #expect(try await conn.count(sql: "SELECT count(*) FROM items WHERE v = 'x'") == 1)

    try await conn.execute(sql: "DELETE FROM items WHERE v = 'a'")
    #expect(try await conn.count(sql: "SELECT count(*) FROM items") == 2)
  }

  @Test func readOnlyFileConnectsReadOnly() async throws {
    let path = TestEnv.freshFile("ro")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    do {
      let seed = try await TestEnv.connect(TestEnv.config(label: "ro", path: path))
      try await seed.execute(sql: "CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('x');")
      await seed.disconnect()
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

    let conn = try await TestEnv.connect(TestEnv.config(label: "ro", path: path))
    defer { await conn.disconnect() }
    #expect(conn.isReadOnly)
    let rows = try await conn.select(sql: "SELECT v FROM t")
    #expect(rows.count == 1)
    do {
      try await conn.execute(sql: "INSERT INTO t VALUES ('y')")
      Issue.record("execute must fail on a read-only database")
    } catch {
      guard case .invalidQuery = error as? SQLiteError else {
        Issue.record("expected invalidQuery (SQLITE_READONLY), got \(error)")
        return
      }
    }
  }

  @Test func invalidQueryReportsSQLiteError() async throws {
    let path = TestEnv.freshFile("badquery")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "badquery", path: path))
    defer { await conn.disconnect() }
    do {
      _ = try await conn.select(sql: "SELECT * FROM missing_table")
      Issue.record("select must fail for a missing table")
    } catch {
      guard case .invalidQuery(let message) = error as? SQLiteError else {
        Issue.record("expected invalidQuery, got \(error)")
        return
      }
      #expect(message.contains("missing_table"))
    }
  }
}
