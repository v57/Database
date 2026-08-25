import Foundation
import NIOCore
import NIOPosix
@preconcurrency import RediStack

/// Async facade over a single Redis server connection.
/// NOT Sendable-declared on purpose: it owns a non-Sendable `RedisConnection`
/// and is driven from the MainActor UI or from tests. All operations are async
/// (RediStack's EventLoopFuture surface is bridged with `.get()`).
///
/// "Collections" for Redis are logical database indexes (0-15); "documents"
/// are the keys of the selected index, rendered as type/value/TTL rows.
public final class RedisConnection {
  public let config: RedisConnectionConfig
  private var connection: RediStack.RedisConnection?
  private var eventLoopGroup: MultiThreadedEventLoopGroup?
  /// Selected logical database index (nil = server default 0).
  public private(set) var currentDatabase: Int?

  public init(config: RedisConnectionConfig) { self.config = config }

  public var isConnected: Bool { connection?.isConnected ?? false }

  /// Opens the TCP connection (driver performs AUTH/SELECT from the config)
  /// and verifies it with PING before reporting connected.
  public func connect() async throws {
    guard config.isValid else { throw RedisError.invalidConfig("host must not be empty") }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
      // ACL users authenticate with AUTH username password (address init);
      // password-only setups use the classic AUTH (hostname init).
      let configuration: RediStack.RedisConnection.Configuration
      if let u = config.username, !u.isEmpty {
        configuration = try RediStack.RedisConnection.Configuration(
          address: .makeAddressResolvingHost(config.host, port: Int(config.port)), username: u,
          password: config.password, initialDatabase: config.databaseIndex)
      } else {
        configuration = try RediStack.RedisConnection.Configuration(
          hostname: config.host, port: Int(config.port), password: config.password,
          initialDatabase: config.databaseIndex)
      }
      let c = try await RediStack.RedisConnection.make(
        configuration: configuration, boundEventLoop: group.any()
      ).get()
      _ = try await c.ping().get()
      connection = c
      eventLoopGroup = group
      currentDatabase = config.databaseIndex
    } catch {
      group.shutdownGracefully { _ in }
      throw RedisError.server(error.localizedDescription)
    }
  }

  public func disconnect() async {
    if let c = connection { _ = c.close() }
    connection = nil
    currentDatabase = nil
    if let g = eventLoopGroup {
      g.shutdownGracefully { _ in }
      eventLoopGroup = nil
    }
  }

  /// Redis exposes fixed logical indexes, not names — the UI shows these and
  /// marks which one is selected.
  public static let logicalDatabaseIndexes: [Int] = Array(0...15)

  public func listDatabases() async throws -> [Int] {
    guard connection != nil else { throw RedisError.notConnected }
    return Self.logicalDatabaseIndexes
  }

  /// Selects the logical database (SELECT n) for subsequent key operations.
  public func use(databaseIndex index: Int) async throws {
    guard let c = connection else { throw RedisError.notConnected }
    guard (0...15).contains(index) else {
      throw RedisError.invalidConfig("database index must be 0-15")
    }
    _ = try await c.select(database: index).get()
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
    guard let c = connection else { throw RedisError.notConnected }
    do {
      var keys: [String] = []
      var cursor = 0
      let pattern = search.isEmpty ? nil : "*\(search)*"
      repeat {
        let (next, batch) = try await c.scan(startingFrom: cursor, matching: pattern).get()
        keys.append(contentsOf: batch)
        cursor = next
        if keys.count >= count { break }
      } while cursor != 0
      return Array(keys.sorted().prefix(count))
    } catch { throw RedisError.server(error.localizedDescription) }
  }

  /// Full detail for one key: TYPE + value + TTL as UI rows.
  public func entry(for key: String) async throws -> RedisKeyEntry {
    guard let c = connection else { throw RedisError.notConnected }
    let k = RedisKey(key)
    do {
      // RediStack 1.6.x has no TYPE wrapper — raw command; reply is a simple
      // status string (string/list/set/zset/hash/stream/none).
      let typeReply = try await c.send(command: "TYPE", with: [.init(from: k)]).get()
      let typeName = typeReply.string ?? "none"
      let valueString = try await displayValue(of: k, typeName: typeName)
      let lifetime = try await c.ttl(k).get()
      let ttlSeconds: Int
      switch lifetime {
      case .limited(.seconds(let s)): ttlSeconds = Int(s)
      case .limited(.milliseconds(let ms)): ttlSeconds = Int(ms / 1000)
      case .unlimited: ttlSeconds = -1
      case .keyDoesNotExist: ttlSeconds = -2
      }
      return RedisKeyEntry(key: key, typeName: typeName, displayValue: valueString, ttl: ttlSeconds)
    } catch let e as RedisError { throw e } catch {
      throw RedisError.server(error.localizedDescription)
    }
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
    guard let c = connection else { throw RedisError.notConnected }
    do { _ = try await c.set(RedisKey(key), to: value).get() } catch {
      throw RedisError.server(error.localizedDescription)
    }
  }

  public func get(_ key: String) async throws -> String? {
    guard let c = connection else { throw RedisError.notConnected }
    do {
      let v = try await c.get(RedisKey(key)).get()
      return v.string
    } catch { throw RedisError.server(error.localizedDescription) }
  }

  public func delete(_ keys: [String]) async throws -> Int {
    guard let c = connection else { throw RedisError.notConnected }
    do { return try await c.delete(keys.map { RedisKey($0) }).get() } catch {
      throw RedisError.server(error.localizedDescription)
    }
  }

  /// Sets an expiry on `key`.
  public func expire(_ key: String, after seconds: Int64) async throws {
    guard let c = connection else { throw RedisError.notConnected }
    do { _ = try await c.expire(RedisKey(key), after: .seconds(seconds)).get() } catch {
      throw RedisError.server(error.localizedDescription)
    }
  }

  // MARK: - Value rendering

  private func displayValue(of key: RedisKey, typeName: String) async throws -> String {
    guard let c = connection else { throw RedisError.notConnected }
    switch typeName {
    case "string": return (try await c.get(key).get()).string ?? ""
    case "list":
      let items = try await c.lrange(from: key, indices: 0...99).get()
      return jsonish(items.compactMap(\.string))
    case "set":
      let members = try await c.smembers(of: key).get()
      return jsonish(members.compactMap(\.string))
    case "zset":
      let members = try await c.zrange(from: key, indices: 0...99).get()
      return jsonish(members.compactMap(\.string))
    case "hash":
      let fields = try await c.hgetall(from: key).get()
      let pairs = fields.keys.sorted().map { "\($0): \(fields[$0]?.string ?? "")" }
      return jsonish(pairs)
    default: return "<\(typeName)>"
    }
  }

  /// Renders a sequence of values as a compact JSON-ish array string so the
  /// existing document rows can expand/display it without Redis-specific code.
  private func jsonish(_ values: [String]) -> String {
    let encoded = values.map { $0.debugDescription }.joined(separator: ", ")
    return "[\(encoded)]"
  }
}
