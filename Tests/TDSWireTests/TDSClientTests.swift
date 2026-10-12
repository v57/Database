import Foundation
import TDSWire
import Testing
import WireKit

/// Needs the `sqlserver` service from docker-compose.yml (1433, sa / DatabasePro#2026).
@Suite(.serialized) struct TDSClientTests {
  static let config = TDSClient.Config(
    host: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["MSSQL_PORT"] ?? "") ?? 1433,
    user: "sa", password: "DatabasePro#2026")

  @Test func logsInAndReportsVersion() async throws {
    let client = try await TDSClient.connect(Self.config)
    #expect(await client.serverVersion.hasPrefix("16."))
    #expect(await client.currentDatabase == "master")
    await client.close()
  }

  @Test func rejectsWrongPassword() async throws {
    var config = Self.config
    config.password = "nope"
    await #expect(throws: DBServerError.self) { try await TDSClient.connect(config) }
  }

  @Test func decodesTheTypeSystem() async throws {
    let client = try await TDSClient.connect(Self.config)
    defer { Task { await client.close() } }
    let result = try await client.execute(
      """
      SELECT CAST(1 AS tinyint) AS t, CAST(-2 AS smallint) AS s, 42 AS i, CAST(9000000000 AS bigint) AS b,
        CAST(1 AS bit) AS flag, CAST(1.5 AS float) AS f, CAST(2.25 AS real) AS r,
        CAST(-12345.6789 AS decimal(18,4)) AS d, CAST(12.3456 AS money) AS m,
        N'héllo ✓' AS nv, 'plain' AS v, CAST(NULL AS int) AS nothing,
        CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS g,
        CAST('2026-10-12' AS date) AS dt, CAST('10:02:03.1234567' AS time) AS tm,
        CAST('2026-10-12 10:02:03.123' AS datetime) AS dtm,
        CAST('2026-10-12 10:02:03.1234567' AS datetime2) AS dt2,
        CAST('2026-10-12 10:02:03 +03:00' AS datetimeoffset(0)) AS dto,
        CAST(0xDEAD AS varbinary(10)) AS bin, REPLICATE(CAST(N'x' AS nvarchar(max)), 5000) AS big
      """)
    let r = try #require(result.rows.first)
    let byName = Dictionary(uniqueKeysWithValues: zip(result.columns.map(\.name), r))
    #expect(byName["t"] == .int(1))
    #expect(byName["s"] == .int(-2))
    #expect(byName["i"] == .int(42))
    #expect(byName["b"] == .int(9_000_000_000))
    #expect(byName["flag"] == .bool(true))
    #expect(byName["f"] == .double(1.5))
    #expect(byName["r"] == .double(2.25))
    #expect(byName["d"] == .decimal("-12345.6789"))
    #expect(byName["m"] == .decimal("12.3456"))
    #expect(byName["nv"] == .text("héllo ✓"))
    #expect(byName["v"] == .text("plain"))
    #expect(byName["nothing"] == .null)
    #expect(byName["g"] == .uuid(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!))
    #expect(byName["dt"] == .text("2026-10-12"))
    #expect(byName["tm"] == .text("10:02:03.1234567"))
    #expect(byName["dtm"] == .text("2026-10-12 10:02:03.123"))
    #expect(byName["dt2"] == .text("2026-10-12 10:02:03.1234567"))
    #expect(byName["dto"] == .text("2026-10-12 10:02:03 +03:00"))
    #expect(byName["bin"] == .bytes([0xDE, 0xAD]))
    #expect(byName["big"]?.stringValue?.count == 5000)
    #expect(result.columns.first { $0.name == "d" }?.typeName == "decimal(18,4)")
  }

  @Test func batchesTransactionsAndErrors() async throws {
    let client = try await TDSClient.connect(Self.config)
    defer { Task { await client.close() } }
    _ = try await client.query(
      "IF DB_ID('wiretest') IS NULL CREATE DATABASE wiretest")
    try await client.use(database: "wiretest")
    #expect(await client.currentDatabase == "wiretest")
    let results = try await client.query(
      """
      IF OBJECT_ID('dbo.orders') IS NOT NULL DROP TABLE dbo.orders;
      CREATE TABLE dbo.orders (id int IDENTITY PRIMARY KEY, customer nvarchar(50), total decimal(10,2));
      INSERT INTO dbo.orders (customer, total) VALUES (N'Maya', 184.20), (N'Liam', 42.00);
      SELECT * FROM dbo.orders ORDER BY id;
      """)
    #expect(results.contains { $0.affectedRows == 2 })
    let select = try #require(results.last)
    #expect(select.rows.count == 2)
    #expect(select.rows[0][1] == .text("Maya"))

    _ = try await client.query("BEGIN TRANSACTION")
    #expect(await client.inTransaction)
    _ = try await client.query("UPDATE dbo.orders SET total = 0")
    _ = try await client.query("ROLLBACK")
    #expect(await client.inTransaction == false)
    let check = try await client.execute("SELECT SUM(total) AS s FROM dbo.orders")
    #expect(check.rows.first?.first == .decimal("226.20"))

    do {
      _ = try await client.query("SELECT * FROM dbo.nope")
      Issue.record("expected an error")
    } catch let error as DBServerError {
      #expect(error.code == "208")
    }
    try await client.use(database: "master")
    _ = try await client.query("DROP DATABASE wiretest")
  }
}
