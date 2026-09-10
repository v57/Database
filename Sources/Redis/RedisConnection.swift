import Foundation
import CHiredis

/// Async facade over a single Redis server connection, backed by the official
/// hiredis C library. NOT Sendable-declared on purpose: it owns a non-Sendable
/// connection context (a hiredis `redisContext`) that lives on a private serial
/// DispatchQueue, and is driven from the MainActor UI or from tests. All
/// operations are async and the only thread that ever touches the hiredis
/// context is that background queue.
///
/// "Collections" for Redis are logical database indexes (0-15); "documents"
/// are the keys of the selected index, rendered as type/value/TTL rows.
public final class RedisConnection {
  public let config: RedisConnectionConfig
  /// The hiredis context plus the private serial queue that owns it. All
  /// hiredis calls run on this queue; no C call ever touches the MainActor.
  private let session: RedisSession
  /// Selected logical database index (nil = server default 0).
  public private(set) var currentDatabase: Int?

  public init(config: RedisConnectionConfig) {
    self.config = config
    self.session = RedisSession()
  }

  public var isConnected: Bool { session.isConnected }

  /// Opens the TCP connection, performs AUTH when a password/ACL username is
  /// present, verifies with PING, and selects the configured database index.
  /// On failure the context is freed and a `RedisError.server` is thrown.
  public func connect() async throws {
    guard config.isValid else { throw RedisError.invalidConfig("host must not be empty") }
    do {
      let ping = try await session.connect(
        host: config.host, port: config.port,
        username: config.username, password: config.password,
        databaseIndex: config.databaseIndex)
      guard ping == "PONG" else {
        print("Redis connect: unexpected PING reply '\(ping)'")
        await session.disconnect()
        throw RedisError.server("PING did not return PONG (got '\(ping)')")
      }
      currentDatabase = config.databaseIndex
    } catch {
      await session.disconnect()
      if let e = error as? RedisError { throw e }
      throw RedisError.server(error.localizedDescription)
    }
  }

  /// Frees the hiredis connection, clears the session and the database index.
  public func disconnect() async {
    await session.disconnect()
    currentDatabase = nil
  }

  /// Redis exposes fixed logical indexes, not names — the UI shows these and
  /// marks which one is selected.
  public static let logicalDatabaseIndexes: [Int] = Array(0...15)

  public func listDatabases() async throws -> [Int] {
    guard session.isConnected else { throw RedisError.notConnected }
    return Self.logicalDatabaseIndexes
  }

  /// Selects the logical database (SELECT n) for subsequent key operations.
  public func use(databaseIndex index: Int) async throws {
    guard session.isConnected else { throw RedisError.notConnected }
    guard (0...15).contains(index) else {
      throw RedisError.invalidConfig("database index must be 0-15")
    }
    _ = try await session.command(["SELECT", String(index)])
    currentDatabase = index
  }

  /// Alias matching the MongoDB facade's string `use(database:)` shape for
  /// generic call sites.
  public func use(database name: String) async throws {
    guard let index = Int(name.trimmingCharacters(in: .whitespaces)) else {
      throw RedisError.invalidConfig("database must be an integer index 0-15")
    }
    try await use(databaseIndex: index)
  }

  /// Keys of the selected database, SCAN-based (non-blocking), optionally
  /// filtered by glob pattern; results capped at `count`.
  public func listKeys(matching search: String = "", count: Int = 1000) async throws -> [String] {
    guard session.isConnected else { throw RedisError.notConnected }
    var keys: [String] = []
    var cursor = "0"
    let pattern = search.isEmpty ? nil : "*\(search)*"
    repeat {
      let args: [String] = pattern.map {
        ["SCAN", cursor, "MATCH", $0, "COUNT", "1000"]
      } ?? ["SCAN", cursor, "COUNT", "1000"]
      let reply = try await session.command(args)
      guard case .array(let parts) = reply, parts.count >= 2 else { break }
      cursor = parts[0].stringValue
      keys.append(contentsOf: parts[1].stringArray ?? [])
      if keys.count >= count { break }
    } while cursor != "0"
    return Array(keys.sorted().prefix(count))
  }

  /// Keys matching an EXPLICIT glob pattern (`nil` = every key). Unlike
  /// `listKeys(matching:)` the pattern is used verbatim, so prefix/suffix/exact
  /// matches from the UI filter builder work.
  public func listKeys(pattern: String?, count: Int = 1000) async throws -> [String] {
    guard let pattern else { return try await listKeys(count: count) }
    guard session.isConnected else { throw RedisError.notConnected }
    var keys: [String] = []
    var cursor = "0"
    repeat {
      let reply = try await session.command(
        ["SCAN", cursor, "MATCH", pattern, "COUNT", "1000"])
      guard case .array(let parts) = reply, parts.count >= 2 else { break }
      cursor = parts[0].stringValue
      keys.append(contentsOf: parts[1].stringArray ?? [])
      if keys.count >= count { break }
    } while cursor != "0"
    return Array(keys.sorted().prefix(count))
  }

  /// Key details for an explicit glob pattern (`nil` = every key).
  public func entries(pattern: String?) async throws -> [RedisKeyEntry] {
    let keys = try await listKeys(pattern: pattern)
    var result: [RedisKeyEntry] = []
    for key in keys { result.append(try await entry(for: key)) }
    return result
  }

  /// Full detail for one key: TYPE + value + TTL as UI rows.
  public func entry(for key: String) async throws -> RedisKeyEntry {
    guard session.isConnected else { throw RedisError.notConnected }
    let typeReply = try await session.command(["TYPE", key])
    let typeName = typeReply.stringValue
    let valueString = try await displayValue(of: key, typeName: typeName)
    let ttl = try await ttlSeconds(for: key)
    return RedisKeyEntry(key: key, typeName: typeName, displayValue: valueString, ttl: ttl)
  }

  /// All keys with details (small local datasets; capped by `listKeys` count).
  public func entries(matching search: String = "") async throws -> [RedisKeyEntry] {
    let keys = try await listKeys(matching: search)
    var result: [RedisKeyEntry] = []
    for key in keys { result.append(try await entry(for: key)) }
    return result
  }

  // MARK: - Raw command access (tests seed through these)

  public func set(_ key: String, to value: String) async throws {
    guard session.isConnected else { throw RedisError.notConnected }
    _ = try await session.command(["SET", key, value])
  }

  public func get(_ key: String) async throws -> String? {
    guard session.isConnected else { throw RedisError.notConnected }
    let reply = try await session.command(["GET", key])
    switch reply {
    case .nilReply: return nil
    default: return reply.stringValue.isEmpty ? nil : reply.stringValue
    }
  }

  public func delete(_ keys: [String]) async throws -> Int {
    guard session.isConnected else { throw RedisError.notConnected }
    let reply = try await session.command(["DEL"] + keys)
    return Int(reply.intValue)
  }

  /// Sets an expiry on `key`.
  public func expire(_ key: String, after seconds: Int64) async throws {
    guard session.isConnected else { throw RedisError.notConnected }
    _ = try await session.command(["EXPIRE", key, String(seconds)])
  }

  // MARK: - Value rendering

  private func displayValue(of key: String, typeName: String) async throws -> String {
    switch typeName {
    case "string":
      let reply = try await session.command(["GET", key])
      return reply.stringValue
    case "list":
      let reply = try await session.command(["LRANGE", key, "0", "99"])
      return jsonish(reply.stringArray ?? [])
    case "set":
      let reply = try await session.command(["SMEMBERS", key])
      return jsonish((reply.stringArray ?? []).sorted())
    case "zset":
      let reply = try await session.command(["ZRANGE", key, "0", "99"])
      return jsonish(reply.stringArray ?? [])
    case "hash":
      let reply = try await session.command(["HGETALL", key])
      let str = reply.stringArray ?? []
      var pairs: [String] = []
      for i in stride(from: 0, to: str.count - 1, by: 2) where i + 1 < str.count {
        pairs.append("\(str[i]): \(str[i + 1])")
      }
      return jsonish(pairs)
    default: return "<\(typeName)>"
    }
  }

  private func ttlSeconds(for key: String) async throws -> Int {
    let reply = try await session.command(["TTL", key])
    // TTL returns an integer: >=0 seconds; -1 = no expiry; -2 = key missing.
    return Int(reply.intValue)
  }

  /// Renders a sequence of values as a compact JSON-ish array string so the
  /// existing document rows can expand/display it without Redis-specific code.
  private func jsonish(_ values: [String]) -> String {
    let encoded = values.map { $0.debugDescription }.joined(separator: ", ")
    return "[\(encoded)]"
  }
}

/// A parsed hiredis reply, translated into a value type that is safe to pass
/// off the background queue. Every `redisReply` is consumed and `freeReplyObject`d
/// inside the command helper before this enum leaves the queue.
enum RedisReply {
  case status(String)
  case string(String)
  case integer(Int64)
  case array([RedisReply])
  case nilReply
  case error(String)

  /// Convenience: the reply's string payload (status/string/error text).
  var stringValue: String {
    switch self {
    case .status(let s), .string(let s), .error(let s): return s
    case .integer(let i): return String(i)
    case .array, .nilReply: return ""
    }
  }

  var intValue: Int64 {
    switch self {
    case .integer(let i): return i
    case .error(let s): return Int64(s) ?? 0
    case .status, .string, .array, .nilReply: return 0
    }
  }

  /// Flat string array if this reply is an ARRAY of STRING/STATUS elements.
  var stringArray: [String]? {
    guard case .array(let parts) = self else { return nil }
    return parts.map { $0.stringValue }
  }
}
