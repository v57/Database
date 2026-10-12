import CQLWire
import Foundation
import Testing
import WireKit

/// Needs the `cassandra` (9042, cassandra/cassandra) and `scylla` (9043) services from docker-compose.yml.
@Suite(.serialized) struct CQLClientTests {
  static let cassandra = CQLClient.Config(
    host: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["CASSANDRA_PORT"] ?? "") ?? 9042,
    user: "cassandra", password: "cassandra")
  static let scylla = CQLClient.Config(
    host: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["SCYLLA_PORT"] ?? "") ?? 9043)

  @Test func cassandraNeedsAndAcceptsAPassword() async throws {
    var anonymous = Self.cassandra
    anonymous.user = nil
    await #expect(throws: WireError.self) { try await CQLClient.connect(anonymous) }
    var wrong = Self.cassandra
    wrong.password = "nope"
    await #expect(throws: DBServerError.self) { try await CQLClient.connect(wrong) }
    let client = try await CQLClient.connect(Self.cassandra)
    #expect(await client.isScylla == false)
    await client.close()
  }

  @Test func scyllaIsRecognized() async throws {
    let client = try await CQLClient.connect(Self.scylla)
    #expect(await client.isScylla)
    await client.close()
  }

  @Test(arguments: ["cassandra", "scylla"]) func roundTripsTypesAndPages(server: String) async throws {
    let client = try await CQLClient.connect(server == "cassandra" ? Self.cassandra : Self.scylla)
    defer { Task { await client.close() } }
    _ = try await client.query(
      "CREATE KEYSPACE IF NOT EXISTS wiretest WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}")
    try await client.use(keyspace: "wiretest")
    #expect(await client.keyspace == "wiretest")
    _ = try await client.query("DROP TABLE IF EXISTS readings")
    _ = try await client.query(
      """
      CREATE TABLE readings (sensor text, at timestamp, id uuid, value double, tags set<text>,
        attrs map<text, int>, raw blob, big varint, price decimal, day date, PRIMARY KEY (sensor, at))
      """)
    _ = try await client.query(
      """
      INSERT INTO readings (sensor, at, id, value, tags, attrs, raw, big, price, day) VALUES
      ('s1', '2026-10-12 10:02:00+0000', 5132b130-ae79-11ec-b909-0242ac120002, 21.5, {'a', 'b'}, {'x': 1},
       0xdead, -123456789012345678901234567890, 12.345, '2026-10-12')
      """)
    for minute in 0..<25 {
      _ = try await client.query(
        "INSERT INTO readings (sensor, at, value) VALUES ('s2', '2026-10-12 11:\(String(format: "%02d", minute)):00+0000', \(minute))"
      )
    }
    let one = try await client.query("SELECT * FROM readings WHERE sensor = 's1'")
    let row = try #require(one.result.rows.first)
    let record = Dictionary(uniqueKeysWithValues: zip(one.result.columns.map(\.name), row))
    #expect(record["sensor"] == .text("s1"))
    #expect(record["at"] == .text("2026-10-12 10:02:00.000Z"))
    #expect(record["value"] == .double(21.5))
    #expect(record["tags"] == .list([.text("a"), .text("b")]))
    #expect(record["attrs"] == .map([DBPair(key: .text("x"), value: .int(1))]))
    #expect(record["raw"] == .bytes([0xDE, 0xAD]))
    #expect(record["big"] == .decimal("-123456789012345678901234567890"))
    #expect(record["price"] == .decimal("12.345"))
    #expect(record["day"] == .text("2026-10-12"))
    #expect(record["id"] == .uuid(UUID(uuidString: "5132b130-ae79-11ec-b909-0242ac120002")!))
    #expect(one.result.columns.first { $0.name == "attrs" }?.typeName == "map<text, int>")

    let first = try await client.query("SELECT * FROM readings WHERE sensor = 's2'", pageSize: 10)
    #expect(first.result.rows.count == 10)
    #expect(first.pagingState != nil)
    let all = try await client.queryAll("SELECT * FROM readings WHERE sensor = 's2'")
    #expect(all.rows.count == 25)

    do {
      _ = try await client.query("SELECT * FROM no_such_table")
      Issue.record("expected an error")
    } catch let error as DBServerError {
      #expect(error.detail == "invalid query")
    }
    _ = try await client.query("DROP KEYSPACE wiretest")
  }
}
