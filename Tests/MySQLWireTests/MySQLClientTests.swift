import Foundation
import MySQLWire
import Testing
import WireKit

/// Needs the `mysql` (3306) and `mariadb` (3307) services from docker-compose.yml.
@Suite(.serialized) struct MySQLClientTests {
  static func config(port: Int, user: String = "root", database: String? = nil) -> MySQLClient.Config {
    MySQLClient.Config(host: "127.0.0.1", port: port, user: user, password: "databasepro", database: database)
  }

  static let mysqlPort = Int(ProcessInfo.processInfo.environment["MYSQL_PORT"] ?? "") ?? 3306
  static let mariaPort = Int(ProcessInfo.processInfo.environment["MARIADB_PORT"] ?? "") ?? 3307

  @Test func mysqlLogsInWithCachingSHA2BothFullAndFast() async throws {
    // A fresh user has no cache entry, so the first login takes the RSA path, the second the fast path.
    let admin = try await MySQLClient.connect(Self.config(port: Self.mysqlPort))
    _ = try await admin.query(
      "DROP USER IF EXISTS 'wiretest'@'%'; CREATE USER 'wiretest'@'%' IDENTIFIED WITH caching_sha2_password BY 'S3cret!'"
    )
    await admin.close()
    var config = Self.config(port: Self.mysqlPort, user: "wiretest")
    config.password = "S3cret!"
    let first = try await MySQLClient.connect(config)
    #expect(await first.isMariaDB == false)
    await first.close()
    let second = try await MySQLClient.connect(config)
    try await second.ping()
    await second.close()
  }

  @Test func mariadbLogsInWithNativePassword() async throws {
    let client = try await MySQLClient.connect(Self.config(port: Self.mariaPort, database: "billing"))
    #expect(await client.isMariaDB)
    #expect(await client.currentDatabase == "billing")
    await client.close()
  }

  @Test func rejectsWrongPassword() async throws {
    var config = Self.config(port: Self.mysqlPort)
    config.password = "wrong"
    await #expect(throws: DBServerError.self) { try await MySQLClient.connect(config) }
  }

  @Test(arguments: [3306, 3307]) func roundTripsRowsAndTypes(port: Int) async throws {
    let client = try await MySQLClient.connect(Self.config(port: port))
    defer { Task { await client.close() } }
    let results = try await client.query(
      """
      CREATE DATABASE IF NOT EXISTS wiretest; USE wiretest;
      DROP TABLE IF EXISTS t;
      CREATE TABLE t (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50), price DECIMAL(10,2),
        big BIGINT UNSIGNED, ratio DOUBLE, raw VARBINARY(4), born DATE, doc JSON, flag BIT(1));
      INSERT INTO t (name, price, big, ratio, raw, born, doc, flag) VALUES
        ('héllo', 12.50, 18446744073709551615, 0.25, X'DEAD', '2026-10-12', '{"a": 1}', b'1'),
        (NULL, NULL, 1, NULL, NULL, NULL, NULL, b'0');
      SELECT * FROM t ORDER BY id;
      """)
    #expect(results.count == 6)
    #expect(results[4].affectedRows == 2)
    let select = try #require(results.last)
    #expect(select.columns.map(\.name) == ["id", "name", "price", "big", "ratio", "raw", "born", "doc", "flag"])
    let row = select.rows[0]
    #expect(row[0] == .int(1))
    #expect(row[1] == .text("héllo"))
    #expect(row[2] == .decimal("12.50"))
    #expect(row[3] == .decimal("18446744073709551615"))
    #expect(row[4] == .double(0.25))
    #expect(row[5] == .bytes([0xDE, 0xAD]))
    #expect(row[6] == .text("2026-10-12"))
    // MySQL has a JSON type; MariaDB's JSON is an alias for LONGTEXT.
    switch row[7] {
    case .json(let text), .text(let text): #expect(text.contains("\"a\""))
    default: Issue.record("doc should be JSON text, got \(row[7])")
    }
    #expect(row[8] == .int(1))
    #expect(select.rows[1][1] == .null)
    let update = try await client.execute("UPDATE t SET name = 'x' WHERE id > 0")
    #expect(update.affectedRows == 2)
    _ = try await client.query("DROP DATABASE wiretest")
  }

  @Test func reportsErrorsAndRecovers() async throws {
    let client = try await MySQLClient.connect(Self.config(port: Self.mysqlPort))
    defer { Task { await client.close() } }
    do {
      _ = try await client.query("SELECT * FROM mysql.no_such_table")
      Issue.record("expected an error")
    } catch let error as DBServerError {
      #expect(error.code?.hasPrefix("1146") == true)
    }
    let ok = try await client.execute("SELECT 1 + 1 AS two")
    #expect(ok.rows.first?.first == .int(2))
  }
}
