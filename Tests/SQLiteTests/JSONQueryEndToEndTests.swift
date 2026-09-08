import Foundation
import Testing

@testable import SQLite
import SQLQuery

/// End-to-end: JSON-like query text compiled by SQLQueryCompiler must execute
/// as real SQL against a real SQLite file. Each test owns its own temp file.
@Suite struct JSONQueryEndToEndTests {
  /// People: 1 ann(30, no note), 2 bob(17, 'kid'), 3 O'Brien(42, no note),
  /// 4 cyd(NULL age, 'admin').
  private static let seedSQL = """
    CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, note TEXT, score REAL);
    INSERT INTO people VALUES (1, 'ann', 30, NULL, 3.5);
    INSERT INTO people VALUES (2, 'bob', 17, 'kid', 2.0);
    INSERT INTO people VALUES (3, 'O''Brien', 42, NULL, 4.5);
    INSERT INTO people VALUES (4, 'cyd', NULL, 'admin', 1.0);
    """

  private func seededConnection(_ label: String) async throws -> (SQLiteConnection, String) {
    let path = TestEnv.freshFile(label)
    TestEnv.createEmptyFile(at: path)
    let conn = try await TestEnv.connect(TestEnv.config(label: label, path: path))
    try await conn.execute(sql: Self.seedSQL)
    return (conn, path)
  }

  @Test func equalityFilterFindsApostropheName() async throws {
    let (conn, path) = try await seededConnection("apostrophe")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let sql = try SQLQueryCompiler.compile(filter: "{\"name\": \"O'Brien\"}", sort: nil,
      projection: nil)
    let rows = try await conn.select(sql: "SELECT * FROM people WHERE \(sql.whereBody!)")
    #expect(rows.count == 1)
    #expect(rows[0]["id"] == .int(3))
  }

  @Test func rangeFilterAndsOperators() async throws {
    let (conn, path) = try await seededConnection("range")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let sql = try SQLQueryCompiler.compile(filter: "{\"age\": {\"$gte\": 18}}", sort: nil,
      projection: nil)
    let rows = try await conn.select(
      sql: "SELECT * FROM people WHERE \(sql.whereBody!) ORDER BY id")
    #expect(rows.count == 2)
    #expect(rows.map { $0["id"] } == [.int(1), .int(3)])
  }

  @Test func nullEqualityAndExistsFilter() async throws {
    let (conn, path) = try await seededConnection("nulls")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }

    // note IS NULL: ann + O'Brien.
    let nullSQL = try SQLQueryCompiler.compile(filter: "{\"note\": null}", sort: nil,
      projection: nil)
    let nullRows = try await conn.select(sql: "SELECT * FROM people WHERE \(nullSQL.whereBody!)")
    #expect(nullRows.count == 2)

    // age $exists false: only cyd (NULL age).
    let existsSQL = try SQLQueryCompiler.compile(filter: "{\"age\": {\"$exists\": false}}",
      sort: nil, projection: nil)
    let existsRows = try await conn.select(sql: "SELECT * FROM people WHERE \(existsSQL.whereBody!)")
    #expect(existsRows.count == 1)
    #expect(existsRows[0]["name"] == .string("cyd"))
  }

  @Test func inFilterSelectsRows() async throws {
    let (conn, path) = try await seededConnection("in")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let sql = try SQLQueryCompiler.compile(filter: "{\"age\": {\"$in\": [17, 42]}}", sort: nil,
      projection: nil)
    let rows = try await conn.select(sql: "SELECT * FROM people WHERE \(sql.whereBody!)")
    #expect(rows.count == 2)
    #expect(rows.map { $0["name"] }.contains(.string("bob")))
    #expect(rows.map { $0["name"] }.contains(.string("O'Brien")))
  }

  @Test func orGroupKeepsPrecedenceInExecution() async throws {
    let (conn, path) = try await seededConnection("orprec")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    // (name = 'ann' OR age = 17) AND note IS NOT NULL -> only bob: ann has a
    // NULL note, and without the parentheses the ann branch would leak in.
    let sql = try SQLQueryCompiler.compile(
      filter: "{\"$or\": [{\"name\": \"ann\"}, {\"age\": 17}], \"note\": {\"$exists\": true}}",
      sort: nil, projection: nil)
    let rows = try await conn.select(sql: "SELECT * FROM people WHERE \(sql.whereBody!)")
    #expect(rows.count == 1)
    #expect(rows[0]["name"] == .string("bob"))
  }

  @Test func sortProjectionAndPaginationRun() async throws {
    let (conn, path) = try await seededConnection("proj")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let sql = try SQLQueryCompiler.compile(
      filter: "{\"age\": {\"$gte\": 18}}", sort: "{age: -1}", projection: "{name: 1, age: 1}")
    let statement = "SELECT \(sql.columns) FROM people WHERE \(sql.whereBody!)"
      + " ORDER BY \(sql.orderBy!)"
    let rows = try await conn.select(sql: statement)
    #expect(rows.count == 2)
    #expect(rows[0]["name"] == .string("O'Brien"))  // 42 first, descending
    #expect(rows[0]["age"] == .int(42))
    #expect(rows[0]["id"] == nil)  // projection dropped the non-requested column
  }

  @Test func rawSQLFragmentStillRuns() async throws {
    let (conn, path) = try await seededConnection("raw")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let sql = try SQLQueryCompiler.compile(filter: "age > 30", sort: nil, projection: nil)
    #expect(sql.whereBody == "age > 30")
    let rows = try await conn.select(sql: "SELECT * FROM people WHERE \(sql.whereBody!)")
    #expect(rows.count == 1)
    #expect(rows[0]["name"] == .string("O'Brien"))
  }

  @Test func compiledQueryPaginatizesWithLimitOffset() async throws {
    let (conn, path) = try await seededConnection("pages")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    // SQLite orders NULLs first on ASC: page 1 is cyd(NULL) then bob(17).
    let sql = try SQLQueryCompiler.compile(filter: "{}", sort: "{age: 1}", projection: nil)
    let page1 = try await conn.select(
      sql: "SELECT id FROM people ORDER BY \(sql.orderBy!)", limit: 2, offset: 0)
    let page2 = try await conn.select(
      sql: "SELECT id FROM people ORDER BY \(sql.orderBy!)", limit: 2, offset: 2)
    #expect(page1.map { $0["id"] } == [.int(4), .int(2)])
    #expect(page2.map { $0["id"] } == [.int(1), .int(3)])
  }
}
