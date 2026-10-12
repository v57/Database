import Foundation
import RedisWire
import Testing

/// Needs the `redis` service from docker-compose.yml (6379). Uses logical database 9.
@Suite(.serialized) struct RedisClientTests {
  static let config = RedisClient.Config(
    host: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["REDIS_PORT"] ?? "") ?? 6379, database: 9)

  @Test func storesAndReadsEveryType() async throws {
    let redis = try await RedisClient.connect(Self.config)
    defer { Task { await redis.close() } }
    try await redis.run("FLUSHDB")
    try await redis.run("SET", "greeting", "hello")
    try await redis.run("HSET", "session:1", "user", "maya", "cart", "3")
    try await redis.run("RPUSH", "queue", "a", "b", "c")
    try await redis.run("SADD", "online", "x", "y")
    try await redis.run("ZADD", "board", "10", "noor", "7", "ines")
    try await redis.run("XADD", "events", "*", "kind", "click")
    try await redis.run("PEXPIRE", "greeting", "60000")

    #expect(try await redis.run("GET", "greeting").string == "hello")
    #expect(try await redis.run("HGET", "session:1", "user").string == "maya")
    let ranked = try await redis.run("ZREVRANGE", "board", "0", "-1", "WITHSCORES").array.compactMap(\.string)
    #expect(ranked == ["noor", "10", "ines", "7"])

    let scan = try await redis.scanKeys()
    #expect(Set(scan.keys) == ["greeting", "session:1", "queue", "online", "board", "events"])
    #expect(scan.complete)
    let infos = try await redis.describe(keys: scan.keys.sorted())
    let byKey = Dictionary(uniqueKeysWithValues: infos.map { ($0.key, $0) })
    #expect(byKey["board"]?.type == "zset")
    #expect(byKey["board"]?.length == 2)
    #expect(byKey["queue"]?.length == 3)
    #expect(byKey["greeting"]?.ttlMilliseconds ?? 0 > 0)
    #expect(byKey["online"]?.ttlMilliseconds == -1)

    let keyspace = try await redis.keyspace()
    #expect(keyspace[9] == 6)
    try await redis.run("FLUSHDB")
  }

  @Test func returnsErrorRepliesWithoutBreakingTheStream() async throws {
    let redis = try await RedisClient.connect(Self.config)
    defer { Task { await redis.close() } }
    let reply = try await redis.command(["NOPE"])
    if case .error(let message) = reply {
      #expect(message.contains("unknown command"))
    } else {
      Issue.record("expected an error reply")
    }
    #expect(try await redis.run("PING").string == "PONG")
    await #expect(throws: RedisError.self) { try await redis.run("INCR", "greeting", "extra") }
  }

  @Test func formatsRepliesLikeRedisCLI() {
    let value = RESPValue.array([.bulk(Array("a".utf8)), .integer(2), .bulk(nil)])
    #expect(value.formatted() == "1) \"a\"\n2) (integer) 2\n3) (nil)")
  }
}

/// Many tasks sharing one connection must each get their own reply.
@Test func concurrentCallersGetTheirOwnReplies() async throws {
  let redis = try await RedisClient.connect(RedisClientTests.config)
  try await withThrowingTaskGroup(of: Bool.self) { group in
    for i in 0..<200 {
      group.addTask {
        if i % 2 == 0 {
          return try await redis.command(["ECHO", "value-\(i)"]).string == "value-\(i)"
        }
        let replies = try await redis.pipeline([["ECHO", "a\(i)"], ["ECHO", "b\(i)"]])
        return replies.map(\.string) == ["a\(i)", "b\(i)"]
      }
    }
    for try await ok in group { #expect(ok) }
  }
  await redis.close()
}
