import Foundation
import PostgresWire
import Testing
import WireKit

/// Needs the `postgres` service from docker-compose.yml (postgres/postgres on 5432).
@Suite(.serialized) struct PostgresClientTests {
  static let config = PostgresClient.Config(
    host: ProcessInfo.processInfo.environment["PG_HOST"] ?? "127.0.0.1",
    port: Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "") ?? 5432,
    user: "postgres", password: "postgres", database: "postgres")

  @Test func connectsWithSCRAMAndReportsVersion() async throws {
    let client = try await PostgresClient.connect(Self.config)
    #expect(await client.serverMajorVersion >= 14)
    await client.close()
  }

  @Test func rejectsWrongPassword() async throws {
    var config = Self.config
    config.password = "nope"
    await #expect(throws: DBServerError.self) { try await PostgresClient.connect(config) }
  }

  @Test func decodesCommonTypes() async throws {
    let client = try await PostgresClient.connect(Self.config)
    defer { Task { await client.close() } }
    let result = try await client.execute(
      """
      SELECT 42::int AS i, 9000000000::bigint AS big, 1.5::float8 AS f, 12.34::numeric AS n, true AS b,
             'héllo'::text AS t, NULL::text AS nothing, '\\xDEAD'::bytea AS raw,
             'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS id, '{"a":1}'::jsonb AS doc,
             DATE '2026-10-12' AS d
      """)
    #expect(result.columns.map(\.name) == ["i", "big", "f", "n", "b", "t", "nothing", "raw", "id", "doc", "d"])
    #expect(result.columns[0].typeName == "integer")
    let row = try #require(result.rows.first)
    #expect(row[0] == .int(42))
    #expect(row[1] == .int(9_000_000_000))
    #expect(row[2] == .double(1.5))
    #expect(row[3] == .decimal("12.34"))
    #expect(row[4] == .bool(true))
    #expect(row[5] == .text("héllo"))
    #expect(row[6] == .null)
    #expect(row[7] == .bytes([0xDE, 0xAD]))
    #expect(row[8] == .uuid(UUID(uuidString: "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")!))
    #expect(row[9] == .json(#"{"a": 1}"#))
    #expect(row[10] == .text("2026-10-12"))
  }

  @Test func runsSeveralStatementsAndCountsChanges() async throws {
    let client = try await PostgresClient.connect(Self.config)
    defer { Task { await client.close() } }
    let results = try await client.query(
      """
      DROP TABLE IF EXISTS wire_test; CREATE TABLE wire_test (id serial PRIMARY KEY, name text);
      INSERT INTO wire_test (name) VALUES ('a'), ('b'), ('c');
      UPDATE wire_test SET name = 'z' WHERE id > 1;
      SELECT * FROM wire_test ORDER BY id;
      """)
    #expect(results.count == 5)
    #expect(results[2].affectedRows == 3)
    #expect(results[3].affectedRows == 2)
    #expect(results[4].rows.count == 3)
    #expect(results[4].rows[2][1] == .text("z"))
    _ = try await client.query("DROP TABLE wire_test")
  }

  @Test func surfacesServerErrorsAndStaysUsable() async throws {
    let client = try await PostgresClient.connect(Self.config)
    defer { Task { await client.close() } }
    do {
      _ = try await client.query("SELECT * FROM no_such_table")
      Issue.record("expected an error")
    } catch let error as DBServerError {
      #expect(error.code == "42P01")
    }
    let after = try await client.execute("SELECT 1")
    #expect(after.rows.first?.first == .int(1))
  }
}

@Test func concurrentQueriesOnOneConnection() async throws {
  let client = try await PostgresClient.connect(PostgresClientTests.config)
  try await withThrowingTaskGroup(of: Bool.self) { group in
    for i in 0..<100 {
      group.addTask { try await client.execute("SELECT \(i) AS n").rows.first?.first == .int(Int64(i)) }
    }
    for try await ok in group { #expect(ok) }
  }
  await client.close()
}
