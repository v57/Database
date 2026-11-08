import BSON
import Foundation
import Testing
import WireKit

@testable import DatabaseKit

/// A Read only connection in a query tab (D-018): what the checks refuse before the server, and the engine's own
/// refusal on SQLite (no server needed). PostgreSQL, MySQL and MariaDB are in `readOnlyQueryTabsRefuseWrites` below,
/// with the docker-compose servers.
@Suite struct ReadOnlyTests {
  @Test func liftingTheSessionModeIsRefused() {
    for sql in [
      "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE",
      "set default_transaction_read_only = off",
      "SET transaction_read_only TO DEFAULT",
      "RESET default_transaction_read_only",
      "RESET ALL",
      "DISCARD ALL",
      "BEGIN READ WRITE",
      "START TRANSACTION   READ\nWRITE",
      "SELECT set_config('default_transaction_read_only', 'off', false)",
      "SET SESSION TRANSACTION READ WRITE",
      "SET @@SESSION.transaction_read_only = 0",
      "SET tx_read_only = 0",
      "SELECT 1; SET default_transaction_read_only = off; COMMIT; UPDATE t SET a = 1",
      "DO $$ BEGIN EXECUTE 'SET default_transaction_read_only = off'; END $$",
    ] {
      #expect(ReadOnlyGuard.liftingStatement(sql) != nil, "\(sql)")
      #expect(throws: ReadOnlyError.self) { try ReadOnlyGuard.check(sql, engine: .postgres) }
    }
    for sql in [
      "SELECT * FROM orders WHERE status = 'shipped'",
      "SHOW transaction_read_only",
      "SELECT @@transaction_read_only",
      "SET search_path TO app",
      "SET TRANSACTION READ ONLY",
      "BEGIN; SELECT 1; COMMIT",
      "UPDATE orders SET total = 0",  // the server refuses this one
    ] {
      #expect(ReadOnlyGuard.liftingStatement(sql) == nil, "\(sql)")
    }
  }

  @Test func sqlServerRunsOnlyReads() {
    for (sql, word) in [
      ("UPDATE orders SET total = 0", "UPDATE"),
      ("SELECT 1\nDELETE FROM orders", "DELETE"),
      ("SELECT * INTO copy FROM orders", "INTO"),
      ("WITH x AS (SELECT id FROM orders) DELETE FROM orders WHERE id IN (SELECT id FROM x)", "DELETE"),
      ("EXEC sp_rename 'orders', 'old'", "EXEC"),
      ("create table t (id int)", "CREATE"),
      ("DBCC CHECKIDENT ('orders', RESEED, 0)", "DBCC"),
      ("CHECKPOINT", "CHECKPOINT"),
      ("/* note */ TRUNCATE TABLE orders", "TRUNCATE"),
    ] {
      #expect(ReadOnlyGuard.sqlServerWrite(sql) == word, "\(sql)")
    }
    for sql in [
      "SELECT * FROM orders WHERE status = 'delete me'",
      "SELECT [update], \"insert\" FROM orders -- drop later",
      "SELECT updated_at FROM orders /* DELETE */",
      "SET NOCOUNT ON; SELECT 1",
      "DECLARE @n int = 1; SELECT @n",
      "USE shop; SELECT TOP 10 * FROM dbo.orders",
      "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent",
    ] {
      #expect(ReadOnlyGuard.sqlServerWrite(sql) == nil, "\(sql)")
    }
  }

  @Test func mongoCommandsAndPipelines() throws {
    try ReadOnlyGuard.checkMongoCommand(["find": .string("orders"), "filter": .document([:])])
    try ReadOnlyGuard.checkMongoCommand(["listCollections": .int32(1)])
    try ReadOnlyGuard.checkMongoCommand(["aggregate": .string("orders"), "pipeline": .array([.document(["$match": .document([:])])])])
    #expect(throws: ReadOnlyError.self) {
      try ReadOnlyGuard.checkMongoCommand(["insert": .string("orders"), "documents": .array([])])
    }
    #expect(throws: ReadOnlyError.self) { try ReadOnlyGuard.checkMongoCommand(["dropDatabase": .int32(1)]) }
    #expect(throws: ReadOnlyError.self) {
      try ReadOnlyGuard.checkMongoCommand(
        ["aggregate": .string("orders"), "pipeline": .array([.document(["$out": .string("copy")])])])
    }
    #expect(throws: ReadOnlyError.self) {
      try ReadOnlyGuard.checkMongoCommand(["explain": .document(["delete": .string("orders")])])
    }
    #expect(throws: ReadOnlyError.self) {
      try ReadOnlyGuard.checkMongoPipeline([["$match": .document([:])], ["$merge": .document(["into": .string("x")])]])
    }
  }

  @Test func engineRefusalsBecomeReadOnlyErrors() {
    let postgres = DBServerError(
      engine: "PostgreSQL", code: "25006", message: "cannot execute UPDATE in a read-only transaction")
    #expect(ReadOnlyGuard.refusal(postgres)?.errorDescription?.contains("cannot execute UPDATE") == true)
    let mysql = DBServerError(
      engine: "MySQL", code: "1792 (25006)", message: "Cannot execute statement in a READ ONLY transaction.")
    #expect(ReadOnlyGuard.refusal(mysql) != nil)
    #expect(ReadOnlyGuard.refusal(DBServerError(engine: "PostgreSQL", code: "42P01", message: "no table")) == nil)
  }

  @Test func sqliteQueryTabRefusesWrites() async throws {
    let path = SQLSessionTests.tempFile("ro.sqlite")
    var profile = ConnectionProfile(engine: .sqlite, filePath: path)
    let (writable, _) = try await Connector.connect(profile, credentials: Credentials())
    _ = try await writable.run("CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT); INSERT INTO t VALUES (1, 'x')", context: QueryContext())
    await writable.close()

    profile.isReadOnly = true
    let (session, _) = try await Connector.connect(profile, credentials: Credentials())
    defer { Task { await session.close() } }
    let runs = try await session.run("SELECT a FROM t", context: QueryContext())
    #expect(runs.count == 1)
    for sql in ["UPDATE t SET a = 'y'", "DELETE FROM t", "CREATE TABLE u (id INTEGER)", "DROP TABLE t"] {
      await #expect(throws: ReadOnlyError.self, "\(sql)") { _ = try await session.run(sql, context: QueryContext()) }
    }
    let after = try await session.run("SELECT a FROM t", context: QueryContext())
    guard case .table(_, let rows, _)? = after.first?.outputs.first else {
      Issue.record("no table")
      return
    }
    #expect(rows.count == 1)
    #expect(rows.first?.first == .db(.text("x")))
  }

  /// Needs a Redis server: `REDIS_TEST_PORT` (database 9 is used). Commands missing from Database's list are refused
  /// from the server's own flags (SETRANGE, PFADD).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["REDIS_TEST_PORT"] != nil))
  func redisCommandLineRefusesWrites() async throws {
    let port = Int(ProcessInfo.processInfo.environment["REDIS_TEST_PORT"] ?? "") ?? 6379
    let (session, _) = try await Connector.connect(
      ConnectionProfile(engine: .redis, port: port, user: "", database: "9", isReadOnly: true), credentials: Credentials())
    defer { Task { await session.close() } }
    let context = QueryContext(database: "9")
    _ = try await session.run("GET d018:key\nSCAN 0", context: context)
    for command in ["SET d018:key 1", "SETRANGE d018:key 0 x", "PFADD d018:hll a", "EVAL \"return 1\" 0", "FLUSHDB"] {
      await #expect(throws: ReadOnlyError.self, "\(command)") { _ = try await session.run(command, context: context) }
    }
  }
}
