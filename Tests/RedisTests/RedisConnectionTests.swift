import Foundation
import Testing

@testable import Redis

/// Integration tests against the localhost compose Redis. Each test uses its
/// own key prefix and cleans up, so Swift Testing's parallel execution is safe.
@Suite(.serialized) struct RedisConnectionTests {
  @Test func connectPingsAndDisconnects() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    #expect(conn.isConnected)
    #expect(conn.currentDatabase == nil)
    await conn.disconnect()
    #expect(!conn.isConnected)
  }

  @Test func setGetRoundtrip() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    let key = TestEnv.freshKeyPrefix("kv") + "greeting"
    await TestEnv.cleanup(conn, prefix: "dbclient:kv:")

    try await conn.set(key, to: "hello")
    let value = try await conn.get(key)
    #expect(value == "hello")
    await TestEnv.cleanup(conn, prefix: "dbclient:kv:")
    let gone = try await conn.get(key)
    #expect(gone == nil)
  }

  @Test func listKeysFiltersBySubstring() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    let prefix = TestEnv.freshKeyPrefix("scan")
    for i in 0..<5 { try await conn.set("\(prefix)item\(i)", to: "\(i)") }
    // A decoy outside the prefix must not appear.
    try await conn.set("dbclient:unrelated:key", to: "x")

    let keys = try await conn.listKeys(matching: prefix, count: 100)
    #expect(keys.count == 5)
    #expect(keys.allSatisfy { $0.hasPrefix(prefix) })

    await TestEnv.cleanup(conn, prefix: "dbclient:")
  }

  @Test func entryReportsTypeValueAndTTL() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    let prefix = TestEnv.freshKeyPrefix("entry")

    try await conn.set("\(prefix)str", to: "v")
    try await conn.expire("\(prefix)str", after: 120)

    let entry = try await conn.entry(for: "\(prefix)str")
    #expect(entry.typeName == "string")
    #expect(entry.displayValue == "v")
    #expect(entry.ttl > 0 && entry.ttl <= 120)

    await TestEnv.cleanup(conn, prefix: "dbclient:entry")
  }

  @Test func deleteRemovesKeys() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    let prefix = TestEnv.freshKeyPrefix("del")
    try await conn.set("\(prefix)a", to: "1")
    try await conn.set("\(prefix)b", to: "2")

    let removed = try await conn.delete(["\(prefix)a", "\(prefix)b"])
    #expect(removed == 2)
    #expect(try await conn.get("\(prefix)a") == nil)
  }

  @Test func selectSwitchesLogicalDatabase() async throws {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    try await conn.use(databaseIndex: 2)
    #expect(conn.currentDatabase == 2)
    // Key written in db 2 is invisible from db 0.
    let key = TestEnv.freshKeyPrefix("db2") + "only"
    try await conn.set(key, to: "here")
    try await conn.use(databaseIndex: 0)
    let fromDb0 = try await conn.get(key)
    #expect(fromDb0 == nil)
    try await conn.use(databaseIndex: 2)
    let fromDb2 = try await conn.get(key)
    #expect(fromDb2 == "here")
    try await conn.delete([key])
    try await conn.use(databaseIndex: 0)
  }

  @Test func connectFailsLoudlyWhenServerIsDown() async {
    let bad = RedisConnectionConfig(name: "bad", host: "127.0.0.1", port: 6390)
    let conn = RedisConnection(config: bad)
    await #expect(throws: (any Error).self) { try await conn.connect() }
  }
}
