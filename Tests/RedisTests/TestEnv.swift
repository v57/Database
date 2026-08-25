import Foundation

@testable import Redis

/// Integration-test support: localhost Redis from docker-compose. Keys are
/// namespaced per test and deleted on the way out so parallel tests stay safe.
enum TestEnv {
  static let host = "127.0.0.1"
  static let port: UInt16 = 6379

  static func config() -> RedisConnectionConfig {
    RedisConnectionConfig(name: "test", host: host, port: port)
  }

  static func freshKeyPrefix(_ label: String) -> String {
    "dbclient:\(label):\(UUID().uuidString.prefix(8)):"
  }

  /// Connects and returns a ready-to-use facade.
  static func connect(_ config: RedisConnectionConfig) async throws -> RedisConnection {
    let conn = RedisConnection(config: config)
    try await conn.connect()
    return conn
  }

  /// Deletes every key under `prefix` (SCAN + DEL) — call in `defer` paths.
  static func cleanup(_ conn: RedisConnection, prefix: String) async {
    guard let keys = try? await conn.listKeys(matching: prefix, count: 10_000) else { return }
    _ = try? await conn.delete(keys)
  }
}
