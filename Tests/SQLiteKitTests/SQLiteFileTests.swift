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

  @Test func refusesAMissingFileWhenNotCreating() {
    #expect(throws: SQLiteError.self) { try SQLiteFile(path: "/nonexistent/dir/x.sqlite", create: false) }
  }
}
