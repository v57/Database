import Foundation
import SQLiteKit
import Testing
import WireKit

struct SQLiteFileTests {
  @Test func createsQueriesAndCountsChanges() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try SQLiteFile(path: path)
    let results = try await db.query(
      """
      CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL, body TEXT, score REAL, raw BLOB);
      INSERT INTO notes (title, body, score, raw) VALUES ('Groceries', 'milk', 1.5, x'DEAD'), ('Ideas', NULL, NULL, NULL);
      UPDATE notes SET score = 2 WHERE id > 0;
      SELECT * FROM notes ORDER BY id;
      """)
    #expect(results.count == 4)
    #expect(results[1].affectedRows == 2)
    #expect(results[2].affectedRows == 2)
    let select = results[3]
    #expect(select.columns.map(\.typeName) == ["integer", "text", "text", "real", "blob"])
    #expect(select.columns.first?.table == "notes")
    #expect(select.rows[0] == [.int(1), .text("Groceries"), .text("milk"), .double(2), .bytes([0xDE, 0xAD])])
    #expect(select.rows[1][2] == .null)
    await #expect(throws: SQLiteError.self) { try await db.query("INSERT INTO notes (title) VALUES (NULL)") }
    await db.close()

    let readOnly = try SQLiteFile(path: path, readOnly: true)
    await #expect(throws: SQLiteError.self) { try await readOnly.query("DELETE FROM notes") }
    #expect(try await readOnly.execute("SELECT count(*) FROM notes").rows.first?.first == .int(2))
  }

  @Test func bindsParameters() async throws {
    let db = try SQLiteFile(path: ":memory:")
    _ = try await db.query("CREATE TABLE t (source TEXT, n INTEGER, raw BLOB)")
    let tricky = "it's 100% \"quoted\"; DROP TABLE t; --"
    _ = try await db.execute("INSERT INTO t VALUES (?1, ?2, ?3)", binds: [.text(tricky), .int(7), .bytes([1, 2])])
    let found = try await db.execute("SELECT n, raw FROM t WHERE source = ?1", binds: [.text(tricky)])
    #expect(found.rows == [[.int(7), .bytes([1, 2])]])
    #expect(try await db.execute("SELECT source FROM t").rows == [[.text(tricky)]])
    #expect(try await db.execute("SELECT count(*) FROM t WHERE source = ?", binds: [.text("x")]).rows == [[.int(0)]])
  }

  @Test func refusesAMissingFileWhenNotCreating() {
    #expect(throws: SQLiteError.self) { try SQLiteFile(path: "/nonexistent/dir/x.sqlite", create: false) }
  }
}
