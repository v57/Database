import Foundation
import Testing

@testable import Redis

@Suite struct RedisConnectionConfigTests {
  @Test func plainUri() {
    let c = RedisConnectionConfig(name: "local", host: "127.0.0.1", port: 6379)
    #expect(c.connectionString == "redis://127.0.0.1:6379")
  }

  @Test func uriWithPassword() {
    // .urlPasswordAllowed escapes spaces but keeps @/: literally (same
    // behavior as the MongoDB ConnectionConfig).
    let c = RedisConnectionConfig(
      name: "a", host: "redis.example.com", port: 6379, password: "pa ss")
    #expect(c.connectionString == "redis://:pa%20ss@redis.example.com:6379")
  }

  @Test func uriWithDatabaseIndex() {
    let c = RedisConnectionConfig(name: "a", host: "h", port: 6380, databaseIndex: 3)
    #expect(c.connectionString == "redis://h:6380/3")
  }

  @Test func defaults() {
    let c = RedisConnectionConfig(name: "x", host: "localhost")
    #expect(c.port == 6379)
    #expect(c.databaseIndex == nil)
    #expect(c.isValid)
    #expect(!RedisConnectionConfig(name: "x", host: "").isValid)
  }
}
