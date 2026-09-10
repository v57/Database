import Foundation
import Testing

@testable import SQLite
import MongoDB
import SQLQuery

/// End-to-end: rules built by the UI filter builder (Sources/MongoDB/FilterRules.swift)
/// must render to filter text, compile to SQL, and return the right rows from a
/// real SQLite file. Each test owns its own temp file; no server needed.
@Suite struct FilterRulesEndToEndTests {
  /// Same seed as JSONQueryEndToEndTests: 1 ann(30), 2 bob(17), 3 O'Brien(42),
  /// 4 cyd(NULL age).
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

  /// Rules -> filter text -> SQL -> rows, exactly the way DatabaseModel does it.
  private func rows(matching rules: [FilterRule], in conn: SQLiteConnection) async throws
    -> [SQLiteRowData]
  {
    let filter = try #require(FilterText.render(rules, dialect: .sql))
    let parts = try SQLQueryCompiler.compile(filter: filter, sort: nil, projection: nil)
    return try await conn.select(
      sql: "SELECT * FROM people WHERE \(parts.whereBody!) ORDER BY id")
  }

  @Test func greaterThanChipSelectsOlderPeople() async throws {
    let (conn, path) = try await seededConnection("chipgt")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let found = try await rows(
      matching: [FilterRule(field: "age", op: .greaterThan, value: .int64(30))], in: conn)
    #expect(found.count == 1)
    #expect(found[0]["name"] == .string("O'Brien"))
  }

  @Test func containsChipMatchesSubstring() async throws {
    let (conn, path) = try await seededConnection("chipcontains")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let found = try await rows(
      matching: [FilterRule(field: "name", op: .contains, value: .string("ob"))], in: conn)
    #expect(found.count == 1)
    #expect(found[0]["name"] == .string("bob"))
  }

  @Test func containsEscapesWildcardsEndToEnd() async throws {
    let (conn, path) = try await seededConnection("chiplike")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    // A literal '%' must not match everything.
    let found = try await rows(
      matching: [FilterRule(field: "note", op: .contains, value: .string("%"))], in: conn)
    #expect(found.isEmpty)
  }

  @Test func twoChipsAreAnded() async throws {
    let (conn, path) = try await seededConnection("chipand")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let found = try await rows(matching: [
      FilterRule(field: "age", op: .greaterOrEqual, value: .int64(18)),
      FilterRule(field: "note", op: .isEmpty),
    ], in: conn)
    #expect(found.map { $0["name"] } == [.string("ann"), .string("O'Brien")])
  }

  @Test func isNotEmptyChipUsesExistsTrue() async throws {
    let (conn, path) = try await seededConnection("chipnotempty")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let found = try await rows(
      matching: [FilterRule(field: "note", op: .isNotEmpty)], in: conn)
    #expect(found.map { $0["name"] } == [.string("bob"), .string("cyd")])
  }

  @Test func inListChipSelectsBothRows() async throws {
    let (conn, path) = try await seededConnection("chipin")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let found = try await rows(
      matching: [FilterRule(field: "age", op: .inList, value: .array([.int64(17), .int64(42)]))],
      in: conn)
    #expect(found.count == 2)
  }

  @Test func sortTextFromColumnMenuOrdersRows() async throws {
    let (conn, path) = try await seededConnection("chipsort")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let parts = try SQLQueryCompiler.compile(
      filter: "{\"age\": {\"$gte\": 18}}", sort: FilterText.sort("age", ascending: false),
      projection: nil)
    let found = try await conn.select(
      sql: "SELECT * FROM people WHERE \(parts.whereBody!) ORDER BY \(parts.orderBy!)")
    #expect(found.map { $0["name"] } == [.string("O'Brien"), .string("ann")])
  }

  @Test func columnUISortAndProjectionCompileAndRun() async throws {
    let (conn, path) = try await seededConnection("columnui")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let allFields = ["id", "name", "age", "note"]
    // What the table header produces: click `age` twice, hide `note`.
    let sort = try #require(SortText.render([SortKey(field: "age", ascending: false)], dialect: .sql))
    let projection = try #require(
      ProjectionText.render(hidden: ["note"], allFields: allFields, dialect: .sql))
    let parts = try SQLQueryCompiler.compile(filter: nil, sort: sort, projection: projection)
    #expect(parts.columns == "\"id\", \"name\", \"age\"")
    // `age DESC` is the SQL spelling, so the compiler passes it through verbatim
    // as the raw ORDER BY fragment (only `{age: -1}`-style text is a document).
    #expect(parts.orderBy == "age DESC")
    let rows = try await conn.select(
      sql: "SELECT \(parts.columns) FROM people ORDER BY \(parts.orderBy!)")
    #expect(rows.count == 4)
    #expect(rows[0]["id"] == .int(3))     // age 42 first (descending); NULL age sorts last
    #expect(rows[0]["note"] == nil)       // hidden by the projection
  }

  @Test func hiddenColumnFromTheListMenuDropsOutOfTheSQLColumns() async throws {
    let (conn, path) = try await seededConnection("hidecolumn")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let allFields = ["id", "name", "age", "note"]
    let projection = try #require(
      ProjectionText.hide("name", in: "", allFields: allFields, dialect: .sql))
    #expect(projection == "{ id: 1, age: 1, note: 1 }")
    let parts = try SQLQueryCompiler.compile(filter: nil, sort: nil, projection: projection)
    let rows = try await conn.select(sql: "SELECT \(parts.columns) FROM people")
    #expect(rows.count == 4)
    #expect(rows[0]["name"] == nil)
    #expect(rows[0]["age"] == .int(30))
  }
}
