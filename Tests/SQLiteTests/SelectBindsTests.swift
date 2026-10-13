import Foundation
import Testing

@testable import SQLite

/// `select(sql:binds:)` binds text values, so quotes and wildcards in them are data, never SQL.
@Suite struct SelectBindsTests {
  private func seededConnection(_ label: String) async throws -> (SQLiteConnection, String) {
    let path = TestEnv.freshFile(label)
    TestEnv.createEmptyFile(at: path)
    let conn = try await TestEnv.connect(TestEnv.config(label: label, path: path))
    try await conn.execute(
      sql: """
        CREATE TABLE t (source TEXT, target TEXT);
        INSERT INTO t VALUES ('It''s here', 'Es ist hier');
        INSERT INTO t VALUES ('100% done', 'Fertig');
        INSERT INTO t VALUES ('other', 'Andere');
        """)
    return (conn, path)
  }

  @Test func bindsMatchTextWithQuotes() async throws {
    let (conn, path) = try await seededConnection("bindquote")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let rows = try await conn.select(sql: "SELECT target FROM t WHERE source = ?1", binds: ["It's here"])
    #expect(rows.count == 1)
    #expect(rows.first?["target"] == .string("Es ist hier"))
  }

  @Test func bindsFillParametersInOrderWithLimit() async throws {
    let (conn, path) = try await seededConnection("bindorder")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let rows = try await conn.select(
      sql: "SELECT source FROM t WHERE source = ?1 OR source = ?2 ORDER BY source",
      binds: ["100% done", "other"], limit: 1)
    #expect(rows.map { $0["source"] } == [.string("100% done")])
  }

  @Test func injectionAttemptIsJustText() async throws {
    let (conn, path) = try await seededConnection("bindinject")
    defer { TestEnv.remove(path) }
    defer { await conn.disconnect() }
    let rows = try await conn.select(sql: "SELECT * FROM t WHERE source = ?1", binds: ["x' OR '1'='1"])
    #expect(rows.isEmpty)
  }
}
