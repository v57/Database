import Foundation
import Testing

@testable import SQLite

/// Result rows must preserve the SELECT's column order. The app derives its
/// List keys and Table columns from the row's key order, so a dictionary-derived
/// order (hash-seed dependent, and unrelated to the query) made columns show up
/// in a different order than the statement asked for — reported by the user as
/// columns "randomly sorting" on each results update.
@Suite struct RowColumnOrderTests {
  private static let seedSQL = """
    CREATE TABLE zoo (zebra TEXT, apple INTEGER, monkey REAL);
    INSERT INTO zoo VALUES ('z', 1, 1.5);
    INSERT INTO zoo VALUES ('zz', 2, 2.5);
    """

  private func seededConnection(_ label: String) async throws -> (SQLiteConnection, String) {
    let path = TestEnv.freshFile(label)
    TestEnv.createEmptyFile(at: path)
    let conn = try await TestEnv.connect(TestEnv.config(label: label, path: path))
    try await conn.execute(sql: Self.seedSQL)
    return (conn, path)
  }

  @Test func columnsFollowTheSelectOrder() async throws {
    let (conn, path) = try await seededConnection("selectorder")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    // Deliberately NOT the table's declaration order: zebra, apple, monkey.
    let rows = try await conn.select(sql: "SELECT zebra, apple, monkey FROM zoo")
    #expect(rows.count == 2)
    #expect(rows[0].columns == ["zebra", "apple", "monkey"])
    #expect(rows[1].columns == ["zebra", "apple", "monkey"])
  }

  @Test func columnsFollowTheOrderOfAProjectionSubset() async throws {
    let (conn, path) = try await seededConnection("projectionorder")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let rows = try await conn.select(sql: "SELECT monkey, zebra FROM zoo")
    #expect(rows[0].columns == ["monkey", "zebra"])
  }

  @Test func repeatedQueriesKeepTheSameColumnOrder() async throws {
    let (conn, path) = try await seededConnection("stableorder")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    // The original symptom: a fresh query returned the same columns in a
    // different order each time.
    let first = try await conn.select(sql: "SELECT * FROM zoo")
    let second = try await conn.select(sql: "SELECT * FROM zoo")
    #expect(first[0].columns == second[0].columns)
    #expect(first[0].columns == ["zebra", "apple", "monkey"])
  }

  @Test func duplicateColumnNamesKeepTheOrderAndTheLastValue() async throws {
    let (conn, path) = try await seededConnection("duplicates")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    // `a` twice: the order keeps both slots, the value is the last occurrence
    // (the documented behaviour — the old init crashed on duplicates instead).
    let rows = try await conn.select(sql: "SELECT apple AS a, zebra AS a, monkey AS m FROM zoo")
    #expect(rows[0].columns == ["a", "a", "m"])
    #expect(rows[0]["a"] == .string("z"))
    #expect(rows[0]["m"] == .double(1.5))
  }
}
