import Foundation
import WireKit

/// A RESP2 reply.
public indirect enum RESPValue: Sendable, Hashable {
  case simple(String)
  case error(String)
  case integer(Int64)
  case bulk([UInt8]?)
  case array([RESPValue]?)

  public var string: String? {
    switch self {
    case .simple(let s): s
    case .bulk(let b): b.map { String(decoding: $0, as: UTF8.self) }
    case .integer(let i): String(i)
    default: nil
    }
  }

  public var int: Int64? {
    switch self {
    case .integer(let i): i
    case .bulk, .simple: string.flatMap { Int64($0) }
    default: nil
    }
  }

  public var array: [RESPValue] {
    if case .array(let items) = self { return items ?? [] }
    return []
  }

  public var isNil: Bool {
    switch self {
    case .bulk(nil), .array(nil): true
    default: false
    }
  }

  /// redis-cli style rendering, for the command line.
  public func formatted(indent: String = "") -> String {
    switch self {
    case .simple(let s): return s
    case .error(let e): return "(error) \(e)"
    case .integer(let i): return "(integer) \(i)"
    case .bulk(nil), .array(nil): return "(nil)"
    case .bulk(let b?): return "\"" + String(decoding: b, as: UTF8.self) + "\""
    case .array(let items?):
      if items.isEmpty { return "(empty array)" }
      return items.enumerated().map { i, item in
        let prefix = "\(i + 1)) "
        let inner = item.formatted(indent: indent + String(repeating: " ", count: prefix.count))
        return (i == 0 ? "" : indent) + prefix + inner
      }.joined(separator: "\n")
    }
  }
}

public struct RedisError: Error, LocalizedError, Sendable {
  public var message: String
  public init(message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// A Redis client over RESP2.
public actor RedisClient {
  public struct Config: Sendable {
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?
    public var database: Int
    public var tls: TLSSettings
    public var connectTimeout: TimeInterval

    public init(
      host: String = "127.0.0.1", port: Int = 6379, username: String? = nil, password: String? = nil,
      database: Int = 0, tls: TLSSettings = .off, connectTimeout: TimeInterval = 15
    ) {
      self.host = host
      self.port = port
      self.username = username
      self.password = password
      self.database = database
      self.tls = tls
      self.connectTimeout = connectTimeout
    }
  }

  public let config: Config
  private let wire: WireConnection
  private let exchange = AsyncMutex()
  public private(set) var database: Int

  private init(config: Config, wire: WireConnection) {
    self.config = config
    self.wire = wire
    self.database = config.database
  }

  public static func connect(_ config: Config) async throws -> RedisClient {
    let wire = try await WireConnection.connect(
      host: config.host, port: config.port, tls: config.tls, timeout: config.connectTimeout)
    let client = RedisClient(config: config, wire: wire)
    do {
      if let password = config.password, !password.isEmpty {
        if let user = config.username, !user.isEmpty {
          try await client.check(client.command(["AUTH", user, password]))
        } else {
          try await client.check(client.command(["AUTH", password]))
        }
      }
      if config.database != 0 { try await client.select(config.database) }
      _ = try await client.check(client.command(["PING"]))
    } catch {
      wire.close()
      throw error
    }
    return client
  }

  public var isOpen: Bool { wire.isOpen }

  public func close() {
    wire.close()
  }

  @discardableResult
  private func check(_ value: RESPValue) throws -> RESPValue {
    if case .error(let message) = value { throw RedisError(message: message) }
    return value
  }

  /// Sends one command and returns the raw reply (errors come back as `.error`).
  public func command(_ args: [String]) async throws -> RESPValue {
    try await commandBytes(args.map { Array($0.utf8) })
  }

  public func commandBytes(_ args: [[UInt8]]) async throws -> RESPValue {
    try await exchange.run { try await self.sendAndRead(args) }
  }

  private func sendAndRead(_ args: [[UInt8]]) async throws -> RESPValue {
    var w = ByteWriter()
    w.writeUTF8("*\(args.count)\r\n")
    for arg in args {
      w.writeUTF8("$\(arg.count)\r\n")
      w.write(arg)
      w.writeUTF8("\r\n")
    }
    try await wire.send(w.bytes)
    return try await readReply()
  }

  /// Like `command`, but throws on an error reply.
  @discardableResult
  public func run(_ args: String...) async throws -> RESPValue {
    try check(try await command(args))
  }

  @discardableResult
  public func run(_ args: [String]) async throws -> RESPValue {
    try check(try await command(args))
  }

  /// Several commands in one round trip.
  public func pipeline(_ commands: [[String]]) async throws -> [RESPValue] {
    try await exchange.run { try await self.sendPipeline(commands) }
  }

  private func sendPipeline(_ commands: [[String]]) async throws -> [RESPValue] {
    var w = ByteWriter()
    for args in commands {
      w.writeUTF8("*\(args.count)\r\n")
      for arg in args {
        let bytes = Array(arg.utf8)
        w.writeUTF8("$\(bytes.count)\r\n")
        w.write(bytes)
        w.writeUTF8("\r\n")
      }
    }
    try await wire.send(w.bytes)
    var replies: [RESPValue] = []
    for _ in commands { replies.append(try await readReply()) }
    return replies
  }

  public func select(_ index: Int) async throws {
    try check(try await command(["SELECT", String(index)]))
    database = index
  }

  private func readReply() async throws -> RESPValue {
    let line = try await wire.readLine()
    guard let prefix = line.first else { throw WireError.protocolViolation("empty RESP line") }
    let rest = String(line.dropFirst())
    switch prefix {
    case "+": return .simple(rest)
    case "-": return .error(rest)
    case ":":
      guard let i = Int64(rest) else { throw WireError.protocolViolation("bad integer") }
      return .integer(i)
    case "$":
      guard let length = Int(rest) else { throw WireError.protocolViolation("bad bulk length") }
      if length < 0 { return .bulk(nil) }
      let bytes = try await wire.read(exactly: length + 2)
      return .bulk(Array(bytes.prefix(length)))
    case "*":
      guard let count = Int(rest) else { throw WireError.protocolViolation("bad array length") }
      if count < 0 { return .array(nil) }
      var items: [RESPValue] = []
      items.reserveCapacity(count)
      for _ in 0..<count { items.append(try await readReply()) }
      return .array(items)
    default:
      throw WireError.protocolViolation("unknown RESP type \(prefix)")
    }
  }

  // MARK: - Helpers the browser uses

  /// SCAN with MATCH/TYPE until `limit` keys or the cursor ends.
  public func scanKeys(pattern: String = "*", type: String? = nil, limit: Int = 2000) async throws -> (
    keys: [String], complete: Bool
  ) {
    var cursor = "0"
    var keys: [String] = []
    repeat {
      var args = ["SCAN", cursor, "MATCH", pattern, "COUNT", "500"]
      if let type { args += ["TYPE", type] }
      let reply = try check(try await command(args)).array
      guard reply.count == 2 else { throw WireError.protocolViolation("bad SCAN reply") }
      cursor = reply[0].string ?? "0"
      keys += reply[1].array.compactMap(\.string)
    } while cursor != "0" && keys.count < limit
    return (Array(keys.prefix(limit)), cursor == "0")
  }

  /// Type, TTL and memory use for many keys in one round trip.
  public func describe(keys: [String]) async throws -> [RedisKeyInfo] {
    if keys.isEmpty { return [] }
    var commands: [[String]] = []
    for key in keys {
      commands.append(["TYPE", key])
      commands.append(["PTTL", key])
      commands.append(["MEMORY", "USAGE", key])
    }
    let replies = try await pipeline(commands)
    var infos: [RedisKeyInfo] = []
    for (i, key) in keys.enumerated() {
      let type = replies[i * 3].string ?? "none"
      let pttl = replies[i * 3 + 1].int ?? -1
      let memory = replies[i * 3 + 2].int
      infos.append(RedisKeyInfo(key: key, type: type, ttlMilliseconds: pttl, memoryBytes: memory))
    }
    // Sizes need the type, so they go in a second round trip.
    let sizeCommands = infos.map { info -> [String] in
      switch info.type {
      case "string": ["STRLEN", info.key]
      case "hash": ["HLEN", info.key]
      case "list": ["LLEN", info.key]
      case "set": ["SCARD", info.key]
      case "zset": ["ZCARD", info.key]
      case "stream": ["XLEN", info.key]
      default: ["EXISTS", info.key]
      }
    }
    let sizes = try await pipeline(sizeCommands)
    for i in infos.indices { infos[i].length = sizes[i].int }
    return infos
  }

  /// Keys per logical database, from INFO keyspace.
  public func keyspace() async throws -> [Int: Int] {
    let info = try check(try await command(["INFO", "keyspace"])).string ?? ""
    var out: [Int: Int] = [:]
    for line in info.split(whereSeparator: \.isNewline) where line.hasPrefix("db") {
      let parts = line.split(separator: ":")
      guard parts.count == 2, let index = Int(parts[0].dropFirst(2)) else { continue }
      for field in parts[1].split(separator: ",") where field.hasPrefix("keys=") {
        out[index] = Int(field.dropFirst(5))
      }
    }
    return out
  }

  public func databaseCount() async throws -> Int {
    let reply = try await command(["CONFIG", "GET", "databases"]).array
    if reply.count == 2, let n = reply[1].int { return Int(n) }
    return 16
  }
}

public struct RedisKeyInfo: Sendable, Hashable, Identifiable {
  public var id: String { key }
  public var key: String
  public var type: String
  /// -1 = never expires, -2 = gone.
  public var ttlMilliseconds: Int64
  public var memoryBytes: Int64?
  public var length: Int64?
}
