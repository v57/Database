import Foundation
import MongoDB
import SQLQuery
import Testing

@testable import SQLite

/// End-to-end single-row edits: primary-key discovery, then statements from
/// SQLRowWrite run through `write(sql:)` with their changed-row counts.
@Suite struct RowWriteTests {
  @Test func primaryKeysOfTablesAndViews() async throws {
    let path = TestEnv.freshFile("pk")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "pk", path: path))
    defer { await conn.disconnect() }
    try await conn.execute(
      sql: """
        CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE pairs (b TEXT, a TEXT, PRIMARY KEY (a, b));
        CREATE TABLE loose (name TEXT);
        CREATE VIEW names AS SELECT name FROM people;
        """)
    #expect(try await conn.primaryKey(of: "people") == ["id"])
    #expect(try await conn.primaryKey(of: "pairs") == ["a", "b"])
    #expect(try await conn.primaryKey(of: "loose") == [])
    #expect(try await conn.primaryKey(of: "names") == [])
  }

  @Test func updateDeleteInsertChangeOneRow() async throws {
    let path = TestEnv.freshFile("write")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "write", path: path))
    defer { await conn.disconnect() }
    try await conn.execute(
      sql: "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER);"
        + "INSERT INTO people (name, age) VALUES ('ann', 30), ('bob', 40)")

    let update = try SQLRowWrite.update(
      "\"people\"", set: ["age": .int64(31)], key: ["id": .int64(1)], flavor: .sqlite)
    #expect(try await conn.write(sql: update) == 1)
    #expect(try await conn.count(sql: "SELECT count(*) FROM people WHERE age = 31") == 1)

    let missing = try SQLRowWrite.delete(from: "\"people\"", key: ["id": .int64(99)], flavor: .sqlite)
    #expect(try await conn.write(sql: missing) == 0)

    let insert = try SQLRowWrite.insert(
      into: "\"people\"", values: ["name": .string("cy")], flavor: .sqlite)
    #expect(try await conn.write(sql: insert) == 1)
    #expect(try await conn.count(sql: "SELECT count(*) FROM people") == 3)

    let delete = try SQLRowWrite.delete(from: "\"people\"", key: ["id": .int64(2)], flavor: .sqlite)
    #expect(try await conn.write(sql: delete) == 1)
    #expect(try await conn.count(sql: "SELECT count(*) FROM people") == 2)
  }

  @Test func writeRefusesSeveralStatements() async throws {
    let path = TestEnv.freshFile("multi")
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: "multi", path: path))
    defer { await conn.disconnect() }
    try await conn.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY)")
    await #expect(throws: SQLiteError.self) {
      try await conn.write(sql: "INSERT INTO t DEFAULT VALUES; DROP TABLE t")
    }
    #expect(try await conn.count(sql: "SELECT count(*) FROM t") == 0)
    #expect(try await conn.write(sql: "INSERT INTO t DEFAULT VALUES;") == 1)
  }
}
