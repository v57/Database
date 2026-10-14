import DuckDBKit
import Foundation
import Testing
import WireKit

// DuckDB is a download, not a build dependency: these run once the app (or a test setup) has installed it.
@Suite(.enabled(if: DuckDBLibrary.isInstalled, "DuckDB isn't installed in \(DuckDBLibrary.directory.path)"))
struct DuckDBFileTests {
  static func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duck-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func storesTablesInAFileAndReadsTypes() async throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("analytics.duckdb").path
    let db = try DuckDBFile(path: path)
    _ = try await db.query(
      """
      CREATE TABLE sales (id INTEGER PRIMARY KEY, region VARCHAR, revenue DECIMAL(12,2), day DATE,
        tags VARCHAR[], meta STRUCT(src VARCHAR, n INT), big HUGEINT, ratio DOUBLE, raw BLOB, ok BOOLEAN, u UUID);
      INSERT INTO sales VALUES
        (1, 'Europe', 2941880.50, DATE '2026-01-01', ['a', 'b'], {'src': 'web', 'n': 1},
         170141183460469231731687303715884105727, 0.5, '\\xDE\\xAD'::BLOB, true, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'),
        (2, 'Africa', 268960.00, NULL, [], NULL, 1, NULL, NULL, false, NULL);
      """)
    let result = try await db.query("SELECT * FROM sales ORDER BY id")
    #expect(result.columns.map(\.typeName).prefix(4) == ["INTEGER", "VARCHAR", "DECIMAL(12,2)", "DATE"])
    let row = try #require(result.rows.first)
    #expect(row[0] == .int(1))
    #expect(row[1] == .text("Europe"))
    #expect(row[2] == .decimal("2941880.50"))
    #expect(row[3] == .text("2026-01-01"))
    #expect(row[4] == .list([.text("a"), .text("b")]))
    #expect(row[5] == .map([DBPair(key: .text("src"), value: .text("web")), DBPair(key: .text("n"), value: .int(1))]))
    #expect(result.columns[4].typeName == "VARCHAR[]")
    #expect(result.columns[5].typeName == "STRUCT(src VARCHAR, n INTEGER)")
    #expect(row[6] == .decimal("170141183460469231731687303715884105727"))
    #expect(row[7] == .double(0.5))
    #expect(row[8] == .bytes([0xDE, 0xAD]))
    #expect(row[9] == .bool(true))
    #expect(row[10] == .uuid(UUID(uuidString: "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")!))
    #expect(result.rows[1][3] == .null)
    let times = try await db.query(
      "SELECT TIMESTAMP '2026-10-12 10:02:03.5' AS ts, TIME '01:02:03' AS t, INTERVAL 3 DAY AS i, MAP {'k': 1} AS m, -12.5::DECIMAL(5,1) AS d")
    #expect(times.rows.first == [.text("2026-10-12 10:02:03.5"), .text("01:02:03"), .text("3 days"),
      .map([DBPair(key: .text("k"), value: .int(1))]), .decimal("-12.5")])

    let update = try await db.query("UPDATE sales SET region = 'EU' WHERE id = 1")
    #expect(update.affectedRows == 1)
    await db.close()

    let reopened = try DuckDBFile(path: path, readOnly: true)
    let check = try await reopened.query("SELECT region FROM sales WHERE id = 1")
    #expect(check.rows.first?.first == .text("EU"))
    await #expect(throws: DuckDBError.self) { try await reopened.query("DELETE FROM sales") }
  }

  @Test func readsParquetCSVAndJSONFilesDirectly() async throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let csv = dir.appendingPathComponent("customers.csv")
    try "id,name,city\n1,Maya,Lisbon\n2,Liam,Oslo\n".write(to: csv, atomically: true, encoding: .utf8)
    let json = dir.appendingPathComponent("events.json")
    try #"[{"kind": "click", "n": 3}, {"kind": "view", "n": 5}]"#.write(to: json, atomically: true, encoding: .utf8)
    let parquet = dir.appendingPathComponent("sales.parquet")

    let db = try DuckDBFile(path: nil)
    _ = try await db.query("COPY (SELECT range AS id, range * 1.5 AS amount FROM range(1000)) TO '\(parquet.path)' (FORMAT parquet)")
    let p = try await db.query("SELECT count(*) AS n, sum(amount) AS total FROM '\(parquet.path)'")
    #expect(p.rows.first?.first == .int(1000))
    let c = try await db.query("SELECT name FROM '\(csv.path)' WHERE city = 'Oslo'")
    #expect(c.rows.first?.first == .text("Liam"))
    let j = try await db.query("SELECT sum(n) FROM read_json_auto('\(json.path)')")
    #expect(j.rows.first?.first?.intValue == 8)
  }

  @Test func reportsSQLErrors() async throws {
    let db = try DuckDBFile(path: nil)
    await #expect(throws: DuckDBError.self) { try await db.query("SELECT * FROM nowhere") }
    #expect(try await db.query("SELECT 42").rows.first?.first == .int(42))
  }
}

/// Writes the demo DuckDB and Parquet files when Scripts/seed-demo.py asks for them.
@Test(.enabled(if: DuckDBLibrary.isInstalled && ProcessInfo.processInfo.environment["DATABASE_DEMO_DIR"] != nil))
func writesDemoFiles() async throws {
  let folder = ProcessInfo.processInfo.environment["DATABASE_DEMO_DIR"]!
  let path = folder + "/analytics.duckdb"
  try? FileManager.default.removeItem(atPath: path)
  try? FileManager.default.removeItem(atPath: path + ".wal")
  let db = try DuckDBFile(path: path)
  _ = try await db.query(
    """
    CREATE TABLE events AS SELECT range AS id, (DATE '2026-01-01' + INTERVAL (range % 280) DAY) AS day,
      ['click', 'view', 'buy'][(range % 3) + 1] AS kind, (range % 97) AS user_id FROM range(5000);
    CREATE TABLE sessions AS SELECT range AS id, (range % 97) AS user_id, (range % 1800) + 30 AS seconds FROM range(2000);
    COPY (SELECT range AS order_id,
        ['Europe', 'North America', 'Asia Pacific', 'Latin America', 'Middle East', 'Africa'][(range % 6) + 1] AS region,
        ((hash(range) % 40000) / 100.0 + 20 + (range % 6) * 7.5)::DECIMAL(12,2) AS revenue, DATE '2026-01-01' + INTERVAL (range % 280) DAY AS order_date,
        ['web', 'store', 'app'][(range % 3) + 1] AS channel
      FROM range(60000)) TO '\(folder)/sales_2026.parquet' (FORMAT parquet);
    """)
  await db.close()
}
