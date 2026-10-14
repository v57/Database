import Foundation
import RedisWire
import SSHTunnel
import WireKit

/// A key's value, shaped by its type.
public enum RedisValue: Sendable, Equatable {
  case string(String)
  case hash([(field: String, value: String)])
  case list([String])
  case set([String])
  case zset([(member: String, score: Double)])
  case stream([(id: String, fields: [(String, String)])])
  case json(String)
  case none
  case other(type: String)

  public static func == (a: RedisValue, b: RedisValue) -> Bool {
    switch (a, b) {
    case (.string(let x), .string(let y)), (.json(let x), .json(let y)): x == y
    case (.list(let x), .list(let y)), (.set(let x), .set(let y)): x == y
    case (.hash(let x), .hash(let y)): x.map { [$0.field, $0.value] } == y.map { [$0.field, $0.value] }
    case (.zset(let x), .zset(let y)): x.map { "\($0.member)\u{0}\($0.score)" } == y.map { "\($0.member)\u{0}\($0.score)" }
    case (.stream(let x), .stream(let y)): x.map(\.id) == y.map(\.id)
    case (.none, .none): true
    case (.other(let x), .other(let y)): x == y
    default: false
    }
  }
}

/// One change to a key; each becomes one or more commands.
public enum RedisMutation: Sendable, Hashable {
  case setString(key: String, value: String)
  case hashSet(key: String, field: String, value: String)
  case hashDelete(key: String, field: String)
  case listSet(key: String, index: Int, value: String)
  case listPush(key: String, value: String, atEnd: Bool)
  case listRemove(key: String, index: Int)
  case setAdd(key: String, member: String)
  case setRemove(key: String, member: String)
  case zsetAdd(key: String, member: String, score: Double)
  case zsetRemove(key: String, member: String)
  case streamAdd(key: String, fields: [String])
  case streamDelete(key: String, id: String)
  case jsonSet(key: String, path: String, json: String)
  /// Seconds; nil removes the expiry.
  case expire(key: String, seconds: Int?)
  case rename(key: String, to: String)
  case delete(key: String)

  public var key: String {
    switch self {
    case .setString(let k, _), .hashSet(let k, _, _), .hashDelete(let k, _), .listSet(let k, _, _),
      .listPush(let k, _, _), .listRemove(let k, _), .setAdd(let k, _), .setRemove(let k, _), .zsetAdd(let k, _, _),
      .zsetRemove(let k, _), .streamAdd(let k, _), .streamDelete(let k, _), .jsonSet(let k, _, _), .expire(let k, _),
      .rename(let k, _), .delete(let k):
      k
    }
  }

  public var commands: [[String]] {
    switch self {
    case .setString(let k, let v): [["SET", k, v, "KEEPTTL"]]
    case .hashSet(let k, let f, let v): [["HSET", k, f, v]]
    case .hashDelete(let k, let f): [["HDEL", k, f]]
    case .listSet(let k, let i, let v): [["LSET", k, String(i), v]]
    case .listPush(let k, let v, let end): [[end ? "RPUSH" : "LPUSH", k, v]]
    case .listRemove(let k, let i):
      // Lists have no remove-by-index: mark the slot, then remove the mark.
      [["LSET", k, String(i), "__databasepro_removed__"], ["LREM", k, "1", "__databasepro_removed__"]]
    case .setAdd(let k, let m): [["SADD", k, m]]
    case .setRemove(let k, let m): [["SREM", k, m]]
    case .zsetAdd(let k, let m, let s): [["ZADD", k, RedisSession.scoreText(s), m]]
    case .zsetRemove(let k, let m): [["ZREM", k, m]]
    case .streamAdd(let k, let fields): [["XADD", k, "*"] + fields]
    case .streamDelete(let k, let id): [["XDEL", k, id]]
    case .jsonSet(let k, let p, let j): [["JSON.SET", k, p, j]]
    case .expire(let k, let s?): [["EXPIRE", k, String(s)]]
    case .expire(let k, nil): [["PERSIST", k]]
    case .rename(let k, let to): [["RENAMENX", k, to]]
    case .delete(let k): [["DEL", k]]
    }
  }
}

/// How to put a key back the way it was.
public struct RedisUndo: Sendable {
  public var key: String
  /// `DUMP` of the key before the change; nil if it didn't exist.
  public var dump: [UInt8]?
  public var pttl: Int64
  /// For renames: the name the key has now.
  public var renamedTo: String?
}

/// Groups keys by a separator into a folder tree ("session:8f2c" → session › 8f2c).
public struct RedisKeyGroup: Sendable, Identifiable, Hashable {
  public var id: String { prefix }
  /// e.g. "session:"
  public var prefix: String
  public var count: Int
}

public enum RedisKeyTree {
  /// The first-level groups and the keys that sit at the top level.
  public static func group(_ keys: [String], separator: Character = ":", minimumGroup: Int = 2) -> (
    groups: [RedisKeyGroup], loose: [String]
  ) {
    var counts: [String: Int] = [:]
    for key in keys {
      if let index = key.firstIndex(of: separator), index != key.startIndex {
        counts[String(key[...index]), default: 0] += 1
      }
    }
    var groups: [RedisKeyGroup] = []
    var grouped: Set<String> = []
    for (prefix, count) in counts where count >= minimumGroup {
      groups.append(RedisKeyGroup(prefix: prefix, count: count))
      grouped.insert(prefix)
    }
    let loose = keys.filter { key in
      guard let index = key.firstIndex(of: separator), index != key.startIndex else { return true }
      return !grouped.contains(String(key[...index]))
    }
    return (groups.sorted { $0.prefix < $1.prefix }, loose.sorted())
  }
}

final class RedisSession: DatabaseSession, @unchecked Sendable {
  let profile: ConnectionProfile
  let client: RedisClient
  let tunnel: SSHTunnel?

  init(profile: ConnectionProfile, client: RedisClient, tunnel: SSHTunnel?) {
    self.profile = profile
    self.client = client
    self.tunnel = tunnel
  }

  var serverDescription: String {
    get async {
      let info = (try? await client.command(["INFO", "server"]).string) ?? ""
      let version = info.split(whereSeparator: \.isNewline).first { $0.hasPrefix("redis_version:") }?
        .dropFirst("redis_version:".count)
      return "Redis \(version.map(String.init) ?? "")"
    }
  }

  func close() async {
    await client.close()
    tunnel?.close()
  }

  // MARK: - Tree

  func children(of node: TreeNode?) async throws -> [TreeNode] {
    guard node == nil else { return [] }
    let keyspace = try await client.keyspace()
    let configured = Int(profile.database) ?? 0
    var indexes = Set(keyspace.keys)
    indexes.insert(0)
    indexes.insert(configured)
    return indexes.sorted().map { index in
      let ref = ObjectRef(database: String(index), name: "Database \(index)", kind: .redisDatabase)
      let count = keyspace[index] ?? 0
      return TreeNode(
        id: ref.id, title: "Database \(index)", detail: "\(SQLSession.compactCount(count)) key\(count == 1 ? "" : "s")",
        kind: .redisDatabase, database: String(index), ref: ref)
    }
  }

  private func select(_ ref: ObjectRef) async throws {
    let index = Int(ref.database ?? "") ?? 0
    if await client.database != index { try await client.select(index) }
  }

  // MARK: - Browse

  static let keyFields: [FieldInfo] = [
    FieldInfo(name: "key", typeName: "key", category: .text, isPrimaryKey: true, isNullable: false),
    FieldInfo(name: "type", typeName: "type", category: .text),
    FieldInfo(name: "holds", typeName: "count", category: .integer),
    FieldInfo(name: "size", typeName: "bytes", category: .integer),
    FieldInfo(name: "ttl", typeName: "milliseconds", category: .integer),
  ]

  func fields(of ref: ObjectRef) async throws -> [FieldInfo] { Self.keyFields }

  static func pattern(for search: String) -> String {
    let trimmed = search.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "*" }
    if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains("[") { return trimmed }
    // Plain text: anywhere in the key, with glob characters escaped.
    let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
    return "*\(escaped)*"
  }

  static func redisType(forFilter value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    switch value.lowercased() {
    case "sorted set", "zset": return "zset"
    case "json", "rejson-rl": return "ReJSON-RL"
    default: return value.lowercased()
    }
  }

  /// Keys matching the request, sorted (up to `limit`), and whether the scan saw them all.
  func matchingKeys(_ request: BrowseRequest, limit: Int = 5000) async throws -> ([String], Bool) {
    try await select(request.ref)
    var pattern = Self.pattern(for: request.search)
    // A key-prefix filter narrows the scan itself.
    for filter in request.activeFilters where filter.field == "key" && filter.op == .startsWith {
      pattern = filter.value + (pattern == "*" ? "*" : pattern)
    }
    let (keys, complete) = try await client.scanKeys(
      pattern: pattern, type: Self.redisType(forFilter: request.keyType), limit: limit)
    return (keys.sorted(), complete)
  }

  func browse(_ request: BrowseRequest) async throws -> BrowsePage {
    let ((keys, complete), elapsed) = try await timed { try await matchingKeys(request) }
    let page = Array(keys.dropFirst(request.offset).prefix(request.limit))
    let infos = try await client.describe(keys: page)
    let records = infos.map { info -> Record in
      Record(
        id: "key:" + info.key, key: RecordKey([RecordKey.Part(field: "key", value: .db(.text(info.key)))]),
        values: [
          "key": .db(.text(info.key)), "type": .db(.text(Self.typeLabel(info.type))),
          "holds": info.length.map { .db(.int($0)) } ?? .null,
          "size": info.memoryBytes.map { .db(.int($0)) } ?? .null, "ttl": .db(.int(info.ttlMilliseconds)),
        ])
    }
    var query = "SCAN 0 MATCH \(Self.pattern(for: request.search)) COUNT 500"
    if let type = Self.redisType(forFilter: request.keyType) { query += " TYPE \(type)" }
    var notes: [String] = []
    if !complete { notes.append("Showing the first \(keys.count.formatted()) matching keys. Narrow the search to see others.") }
    return BrowsePage(
      fields: Self.keyFields, records: records, total: keys.count, totalIsEstimate: !complete,
      hasMore: request.offset + request.limit < keys.count, query: query, elapsed: elapsed, notes: notes)
  }

  static func typeLabel(_ type: String) -> String {
    switch type {
    case "ReJSON-RL": "JSON"
    default: type.uppercased()
    }
  }

  func count(_ request: BrowseRequest) async throws -> Int {
    try await matchingKeys(request, limit: 1_000_000).0.count
  }

  // MARK: - Values

  /// Reads up to `limit` items of a key's value, plus the real length.
  public func value(of key: String, in ref: ObjectRef, limit: Int = 500) async throws -> (RedisValue, Int) {
    try await select(ref)
    let type = try await client.run("TYPE", key).string ?? "none"
    switch type {
    case "string":
      let value = try await client.run("GET", key).string ?? ""
      return (.string(value), value.utf8.count)
    case "hash":
      let total = Int(try await client.run("HLEN", key).int ?? 0)
      let items = try await scanPairs(["HSCAN", key], limit: limit)
      return (.hash(items.map { (field: $0.0, value: $0.1) }.sorted { $0.field < $1.field }), total)
    case "list":
      let total = Int(try await client.run("LLEN", key).int ?? 0)
      let items = try await client.run("LRANGE", key, "0", String(limit - 1)).array.compactMap(\.string)
      return (.list(items), total)
    case "set":
      let total = Int(try await client.run("SCARD", key).int ?? 0)
      var members: [String] = []
      var cursor = "0"
      repeat {
        let reply = try await client.run("SSCAN", key, cursor, "COUNT", "500").array
        cursor = reply.first?.string ?? "0"
        members += (reply.count > 1 ? reply[1].array : []).compactMap(\.string)
      } while cursor != "0" && members.count < limit
      return (.set(Array(members.sorted().prefix(limit))), total)
    case "zset":
      let total = Int(try await client.run("ZCARD", key).int ?? 0)
      let flat = try await client.run("ZRANGE", key, "0", String(limit - 1), "REV", "WITHSCORES").array.compactMap(\.string)
      var pairs: [(member: String, score: Double)] = []
      var i = 0
      while i + 1 < flat.count {
        pairs.append((member: flat[i], score: Double(flat[i + 1]) ?? 0))
        i += 2
      }
      return (.zset(pairs), total)
    case "stream":
      let total = Int(try await client.run("XLEN", key).int ?? 0)
      let entries = try await client.run("XREVRANGE", key, "+", "-", "COUNT", String(limit)).array
      let parsed = entries.compactMap { entry -> (id: String, fields: [(String, String)])? in
        let parts = entry.array
        guard parts.count == 2, let id = parts[0].string else { return nil }
        let flat = parts[1].array.compactMap(\.string)
        var fields: [(String, String)] = []
        var i = 0
        while i + 1 < flat.count {
          fields.append((flat[i], flat[i + 1]))
          i += 2
        }
        return (id: id, fields: fields)
      }
      return (.stream(parsed), total)
    case "ReJSON-RL":
      let json = try await client.run("JSON.GET", key, "$").string ?? "null"
      // JSON.GET with "$" wraps the document in an array.
      var text = json
      if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
      if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
        let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
      {
        text = String(decoding: pretty, as: UTF8.self)
      }
      return (.json(text), text.utf8.count)
    case "none":
      return (.none, 0)
    default:
      return (.other(type: type), 0)
    }
  }

  private func scanPairs(_ command: [String], limit: Int) async throws -> [(String, String)] {
    var cursor = "0"
    var out: [(String, String)] = []
    repeat {
      let reply = try await client.run(command + [cursor, "COUNT", "500"]).array
      cursor = reply.first?.string ?? "0"
      let flat = (reply.count > 1 ? reply[1].array : []).compactMap(\.string)
      var i = 0
      while i + 1 < flat.count {
        out.append((flat[i], flat[i + 1]))
        i += 2
      }
    } while cursor != "0" && out.count < limit
    return Array(out.prefix(limit))
  }

  public func ttl(of key: String, in ref: ObjectRef) async throws -> Int64 {
    try await select(ref)
    return try await client.run("PTTL", key).int ?? -2
  }

  static func scoreText(_ score: Double) -> String {
    score == score.rounded() && abs(score) < 1e15 ? String(Int64(score)) : String(score)
  }

  // MARK: - Changing keys

  /// Applies a change and returns how to undo it (a snapshot of the key from before).
  public func mutate(_ mutation: RedisMutation, in ref: ObjectRef) async throws -> RedisUndo {
    if profile.isReadOnly { throw ReadOnlyError() }
    try await select(ref)
    let snapshot = try await snapshot(mutation.key)
    var undo = snapshot
    if case .rename(_, let to) = mutation {
      undo.renamedTo = to
      if try await client.run("EXISTS", to).int == 1 {
        throw InputError("A key named \(to) already exists.")
      }
    }
    for command in mutation.commands {
      let reply = try await client.command(command)
      if case .error(let message) = reply { throw RedisError(message: message) }
    }
    return undo
  }

  /// Several changes, each undoable; stops at the first failure.
  public func mutate(_ mutations: [RedisMutation], in ref: ObjectRef) async throws -> [RedisUndo] {
    var undos: [RedisUndo] = []
    for mutation in mutations { undos.append(try await mutate(mutation, in: ref)) }
    return undos
  }

  private func snapshot(_ key: String) async throws -> RedisUndo {
    let dump = try await client.command(["DUMP", key])
    let pttl = try await client.run("PTTL", key).int ?? -1
    if case .bulk(let bytes?) = dump { return RedisUndo(key: key, dump: bytes, pttl: pttl) }
    return RedisUndo(key: key, dump: nil, pttl: -1)
  }

  public func undo(_ undo: RedisUndo, in ref: ObjectRef) async throws {
    try await select(ref)
    if let renamed = undo.renamedTo { try await client.run("DEL", renamed) }
    if let dump = undo.dump {
      let ttl = undo.pttl > 0 ? String(undo.pttl) : "0"
      let reply = try await client.commandBytes([
        Array("RESTORE".utf8), Array(undo.key.utf8), Array(ttl.utf8), dump, Array("REPLACE".utf8),
      ])
      if case .error(let message) = reply { throw RedisError(message: message) }
    } else {
      try await client.run("DEL", undo.key)
    }
  }

  /// Creates a key of the given type with a first value.
  public func create(key: String, type: String, first: [String], in ref: ObjectRef) async throws {
    if profile.isReadOnly { throw ReadOnlyError() }
    try await select(ref)
    if try await client.run("EXISTS", key).int == 1 { throw InputError("A key named \(key) already exists.") }
    let command: [String]
    switch type {
    case "string": command = ["SET", key, first.first ?? ""]
    case "hash": command = ["HSET", key] + (first.count >= 2 ? Array(first.prefix(2)) : ["field", first.first ?? ""])
    case "list": command = ["RPUSH", key, first.first ?? ""]
    case "set": command = ["SADD", key, first.first ?? ""]
    case "zset": command = ["ZADD", key, first.count > 1 ? first[1] : "0", first.first ?? ""]
    case "stream": command = ["XADD", key, "*"] + (first.count >= 2 ? Array(first.prefix(2)) : ["field", first.first ?? ""])
    case "json": command = ["JSON.SET", key, "$", first.first ?? "{}"]
    default: throw InputError("Unknown key type \(type).")
    }
    try await client.run(command)
  }

  // MARK: - Generic edits (deleting keys from the list)

  func parseInput(_ text: String, isNull: Bool, for field: FieldInfo) throws -> CellValue { .db(.text(text)) }

  func statements(for edits: [RecordEdit]) throws -> [String] {
    edits.compactMap { edit in
      guard case .delete = edit.kind, let key = edit.key?.parts.first?.value.dbValue?.stringValue else { return nil }
      return "DEL \(Self.quoteArgument(key))"
    }
  }

  func apply(_ edits: [RecordEdit]) async throws -> ApplyOutcome {
    if profile.isReadOnly { throw ReadOnlyError() }
    var statements: [String] = []
    for edit in edits {
      guard case .delete = edit.kind, let key = edit.key?.parts.first?.value.dbValue?.stringValue else {
        throw InputError("Redis keys are changed in the value editor.")
      }
      _ = try await mutate(.delete(key: key), in: edit.ref)
      statements.append("DEL \(Self.quoteArgument(key))")
    }
    return ApplyOutcome(changedItems: edits.count, undo: [], statements: statements)
  }

  // MARK: - Command line

  static func quoteArgument(_ arg: String) -> String {
    arg.isEmpty || arg.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" || $0.isNewline })
      ? "\"" + arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : arg
  }

  /// Splits a redis-cli line into arguments, honoring quotes and escapes.
  static func arguments(_ line: String) throws -> [String] {
    var args: [String] = []
    var current = ""
    var quote: Character?
    var inToken = false
    var escaped = false
    for ch in line {
      if escaped {
        switch ch {
        case "n": current.append("\n")
        case "t": current.append("\t")
        default: current.append(ch)
        }
        escaped = false
        continue
      }
      if let q = quote {
        if ch == "\\" && q == "\"" {
          escaped = true
        } else if ch == q {
          quote = nil
        } else {
          current.append(ch)
        }
        continue
      }
      if ch == "\"" || ch == "'" {
        quote = ch
        inToken = true
      } else if ch == " " || ch == "\t" {
        if inToken {
          args.append(current)
          current = ""
          inToken = false
        }
      } else {
        current.append(ch)
        inToken = true
      }
    }
    if quote != nil { throw InputError("A quote isn't closed.") }
    if inToken { args.append(current) }
    return args
  }

  static let writeCommands: Set<String> = [
    "SET", "SETEX", "PSETEX", "SETNX", "MSET", "MSETNX", "APPEND", "DEL", "UNLINK", "EXPIRE", "PEXPIRE", "EXPIREAT",
    "PERSIST", "RENAME", "RENAMENX", "INCR", "INCRBY", "INCRBYFLOAT", "DECR", "DECRBY", "GETDEL", "GETEX", "HSET",
    "HSETNX", "HMSET", "HDEL", "HINCRBY", "HINCRBYFLOAT", "LPUSH", "RPUSH", "LPOP", "RPOP", "LSET", "LREM", "LTRIM",
    "LINSERT", "LMOVE", "SADD", "SREM", "SPOP", "SMOVE", "ZADD", "ZREM", "ZINCRBY", "ZPOPMIN", "ZPOPMAX",
    "ZREMRANGEBYSCORE", "ZREMRANGEBYRANK", "XADD", "XDEL", "XTRIM", "FLUSHDB", "FLUSHALL", "RESTORE", "COPY", "MOVE",
    "JSON.SET", "JSON.DEL", "JSON.ARRAPPEND", "JSON.NUMINCRBY", "SWAPDB", "CONFIG",
  ]

  func run(_ text: String, context: QueryContext) async throws -> [QueryRun] {
    if let database = context.database, let index = Int(database), await client.database != index {
      try await client.select(index)
    }
    var runs: [QueryRun] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }
      let args = try Self.arguments(trimmed)
      guard let name = args.first?.uppercased() else { continue }
      if profile.isReadOnly && Self.writeCommands.contains(name) { throw ReadOnlyError() }
      let (reply, elapsed) = try await timed { try await client.command(args) }
      runs.append(QueryRun(outputs: [.text(reply.formatted())], elapsed: elapsed, statement: trimmed))
    }
    return runs
  }

  func explain(_ text: String, context: QueryContext) async throws -> String {
    let lines = try await client.run("SLOWLOG", "GET", "10").array.map { $0.formatted() }
    return "Redis runs commands directly, so there is no query plan. The slowest recent commands:\n\n"
      + lines.joined(separator: "\n\n")
  }

  func completions(context: QueryContext) async -> [Completion] {
    let common = [
      "GET", "SET", "DEL", "EXISTS", "EXPIRE", "TTL", "PTTL", "PERSIST", "TYPE", "SCAN", "KEYS", "HGET", "HSET",
      "HGETALL", "HDEL", "LRANGE", "LPUSH", "RPUSH", "LLEN", "SMEMBERS", "SADD", "SREM", "ZRANGE", "ZADD", "ZREM",
      "ZSCORE", "XADD", "XRANGE", "XLEN", "INFO", "DBSIZE", "MEMORY USAGE", "JSON.GET", "JSON.SET", "SELECT",
    ]
    return common.map { Completion(text: $0, detail: "command", kind: .command) }
  }
}
