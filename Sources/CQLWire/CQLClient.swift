import Foundation
import WireKit

/// A Cassandra / ScyllaDB client speaking CQL native protocol v4.
public actor CQLClient {
  public struct Config: Sendable {
    public var host: String
    public var port: Int
    public var user: String?
    public var password: String?
    public var keyspace: String?
    public var tls: TLSSettings
    public var connectTimeout: TimeInterval
    /// How to reach the server: TCP from this device, or a channel of an SSH connection.
    public var dialer: WireDialer

    public init(
      host: String = "127.0.0.1", port: Int = 9042, user: String? = nil, password: String? = nil,
      keyspace: String? = nil, tls: TLSSettings = .off, connectTimeout: TimeInterval = 15,
      dialer: WireDialer = .direct
    ) {
      self.host = host
      self.port = port
      self.user = user
      self.password = password
      self.keyspace = keyspace
      self.tls = tls
      self.connectTimeout = connectTimeout
      self.dialer = dialer
    }
  }

  public enum Consistency: UInt16, Sendable, CaseIterable {
    case any = 0, one = 1, two = 2, three = 3, quorum = 4, all = 5, localQuorum = 6, eachQuorum = 7
    case localOne = 0x0A

    public var label: String {
      switch self {
      case .any: "Any"
      case .one: "One"
      case .two: "Two"
      case .three: "Three"
      case .quorum: "Quorum"
      case .all: "All"
      case .localQuorum: "Local quorum"
      case .eachQuorum: "Each quorum"
      case .localOne: "Local one"
      }
    }
  }

  enum Opcode: UInt8 {
    case error = 0x00, startup = 0x01, ready = 0x02, authenticate = 0x03, options = 0x05, supported = 0x06
    case query = 0x07, result = 0x08, register = 0x0B, event = 0x0C, authChallenge = 0x0E
    case authResponse = 0x0F, authSuccess = 0x10
  }

  public let config: Config
  private let wire: WireConnection
  private let exchange = AsyncMutex()
  public private(set) var keyspace: String?
  public private(set) var supported: [String: [String]] = [:]
  public var consistency: Consistency = .localOne

  private init(config: Config, wire: WireConnection) {
    self.config = config
    self.wire = wire
  }

  public static func connect(_ config: Config) async throws -> CQLClient {
    let wire = try await config.dialer.connect(
      host: config.host, port: config.port, tls: config.tls, timeout: config.connectTimeout)
    let client = CQLClient(config: config, wire: wire)
    do {
      try await client.startup()
      if let keyspace = config.keyspace, !keyspace.isEmpty { try await client.use(keyspace: keyspace) }
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

  /// ScyllaDB adds SCYLLA_* keys to the SUPPORTED reply.
  public var isScylla: Bool { supported.keys.contains { $0.hasPrefix("SCYLLA") } }

  // MARK: - Frames

  private func send(_ opcode: Opcode, _ body: [UInt8]) async throws {
    var w = ByteWriter(capacity: body.count + 9)
    w.write(0x04)
    w.write(0x00)
    w.writeBE(Int16(0))
    w.write(opcode.rawValue)
    w.writeBE(Int32(body.count))
    w.write(body)
    try await wire.send(w.bytes)
  }

  private func receive() async throws -> (Opcode, ByteReader) {
    while true {
      let header = try await wire.read(exactly: 9)
      var r = ByteReader(header)
      _ = try r.readByte()  // version
      let flags = try r.readByte()
      _ = try r.readBE(Int16.self)
      let opcodeByte = try r.readByte()
      let length = Int(try r.readBE(Int32.self))
      let body = try await wire.read(exactly: length)
      guard let opcode = Opcode(rawValue: opcodeByte) else {
        throw WireError.protocolViolation("unknown CQL opcode \(opcodeByte)")
      }
      if opcode == .event { continue }
      var reader = ByteReader(body)
      if flags & 0x02 != 0 {  // tracing id
        try reader.skip(16)
      }
      if flags & 0x08 != 0 {  // warnings
        let count = Int(try reader.readBE(Int16.self))
        for _ in 0..<count { _ = try Self.readString(&reader) }
      }
      if flags & 0x04 != 0 {  // custom payload
        let count = Int(try reader.readBE(Int16.self))
        for _ in 0..<count {
          _ = try Self.readString(&reader)
          _ = try Self.readBytes(&reader)
        }
      }
      if opcode == .error { throw try Self.serverError(&reader) }
      return (opcode, reader)
    }
  }

  // MARK: - Startup

  private func startup() async throws {
    try await send(.options, [])
    var (opcode, reader) = try await receive()
    if opcode == .supported {
      let count = Int(try reader.readBE(Int16.self))
      for _ in 0..<count {
        let key = try Self.readString(&reader)
        let listCount = Int(try reader.readBE(Int16.self))
        var values: [String] = []
        for _ in 0..<listCount { values.append(try Self.readString(&reader)) }
        supported[key] = values
      }
    }

    var w = ByteWriter()
    w.writeBE(Int16(1))
    Self.writeString(&w, "CQL_VERSION")
    Self.writeString(&w, "3.0.0")
    try await send(.startup, w.bytes)
    (opcode, reader) = try await receive()
    switch opcode {
    case .ready:
      return
    case .authenticate:
      let authenticator = try Self.readString(&reader)
      guard let user = config.user, !user.isEmpty else {
        throw WireError.authenticationFailed("this cluster needs a user name and password (\(authenticator))")
      }
      var token = ByteWriter()
      token.write(0)
      token.writeUTF8(user)
      token.write(0)
      token.writeUTF8(config.password ?? "")
      var body = ByteWriter()
      body.writeBE(Int32(token.count))
      body.write(token.bytes)
      try await send(.authResponse, body.bytes)
      let (reply, _) = try await receive()
      guard reply == .authSuccess else { throw WireError.authenticationFailed("unexpected \(reply)") }
    default:
      throw WireError.protocolViolation("unexpected \(opcode) after STARTUP")
    }
  }

  // MARK: - Queries

  public struct Page: Sendable {
    public var result: DBResult
    /// Pass back to `query` to read the next page.
    public var pagingState: [UInt8]?
    public var keyspace: String?
    public var table: String?
  }

  /// Runs one CQL statement. Rows come back a page at a time.
  public func query(
    _ cql: String, pageSize: Int = 200, pagingState: [UInt8]? = nil, consistency: Consistency? = nil
  ) async throws -> Page {
    try await exchange.run {
      try await self.runQuery(cql, pageSize: pageSize, pagingState: pagingState, consistency: consistency)
    }
  }

  private func runQuery(
    _ cql: String, pageSize: Int, pagingState: [UInt8]?, consistency: Consistency?
  ) async throws -> Page {
    var w = ByteWriter()
    let text = Array(cql.utf8)
    w.writeBE(Int32(text.count))
    w.write(text)
    w.writeBE((consistency ?? self.consistency).rawValue)
    var flags: UInt8 = 0x04
    if pagingState != nil { flags |= 0x08 }
    w.write(flags)
    w.writeBE(Int32(pageSize))
    if let pagingState {
      w.writeBE(Int32(pagingState.count))
      w.write(pagingState)
    }
    try await send(.query, w.bytes)
    var (opcode, reader) = try await receive()
    guard opcode == .result else { throw WireError.protocolViolation("expected RESULT, got \(opcode)") }
    let kind = try reader.readBE(Int32.self)
    switch kind {
    case 0x0002:
      return try Self.readRows(&reader)
    case 0x0003:
      keyspace = try Self.readString(&reader)
      return Page(result: DBResult(messages: ["Now using keyspace \(keyspace ?? "")"]), pagingState: nil)
    case 0x0005:
      let change = try Self.readString(&reader)
      let target = try Self.readString(&reader)
      let ks = try Self.readString(&reader)
      return Page(result: DBResult(messages: ["\(change.capitalized) \(target.lowercased()) in \(ks)"]), pagingState: nil)
    default:
      return Page(result: DBResult(), pagingState: nil)
    }
  }

  /// Reads every page, up to `limit` rows.
  public func queryAll(_ cql: String, limit: Int = 10000) async throws -> DBResult {
    var page = try await query(cql, pageSize: min(limit, 1000))
    var result = page.result
    while let state = page.pagingState, result.rows.count < limit {
      page = try await query(cql, pageSize: min(limit - result.rows.count, 1000), pagingState: state)
      result.rows += page.result.rows
    }
    return result
  }

  public func use(keyspace: String) async throws {
    _ = try await query("USE \(CQLText.identifier(keyspace))")
  }

  // MARK: - Decoding

  static func readRows(_ r: inout ByteReader) throws -> Page {
    let flags = try r.readBE(Int32.self)
    let columnCount = Int(try r.readBE(Int32.self))
    var pagingState: [UInt8]?
    if flags & 0x0002 != 0 { pagingState = try readBytes(&r) }
    var globalKeyspace: String?
    var globalTable: String?
    if flags & 0x0001 != 0 {
      globalKeyspace = try readString(&r)
      globalTable = try readString(&r)
    }
    var columns: [DBColumn] = []
    var types: [CQLType] = []
    if flags & 0x0004 == 0 {
      for _ in 0..<columnCount {
        var table = globalTable
        if globalKeyspace == nil {
          _ = try readString(&r)
          table = try readString(&r)
        }
        let name = try readString(&r)
        let type = try CQLType.read(&r)
        columns.append(DBColumn(name: name, typeName: type.name, table: table))
        types.append(type)
      }
    }
    let rowCount = Int(try r.readBE(Int32.self))
    var rows: [[DBValue]] = []
    rows.reserveCapacity(rowCount)
    for _ in 0..<rowCount {
      var row: [DBValue] = []
      for type in types {
        if let bytes = try readBytes(&r) {
          row.append(type.decode(bytes))
        } else {
          row.append(.null)
        }
      }
      rows.append(row)
    }
    return Page(
      result: DBResult(columns: columns, rows: rows), pagingState: pagingState, keyspace: globalKeyspace,
      table: globalTable)
  }

  static func readString(_ r: inout ByteReader) throws -> String {
    let length = Int(try r.readBE(UInt16.self))
    return try r.readUTF8(length)
  }

  static func writeString(_ w: inout ByteWriter, _ s: String) {
    let bytes = Array(s.utf8)
    w.writeBE(UInt16(bytes.count))
    w.write(bytes)
  }

  static func readBytes(_ r: inout ByteReader) throws -> [UInt8]? {
    let length = Int(try r.readBE(Int32.self))
    if length < 0 { return nil }
    return try r.readBytes(length)
  }

  static func serverError(_ r: inout ByteReader) throws -> DBServerError {
    let code = try r.readBE(Int32.self)
    let message = try readString(&r)
    let kind: String =
      switch code {
      case 0x0100: "bad credentials"
      case 0x1000: "unavailable"
      case 0x1001: "overloaded"
      case 0x1100: "write timeout"
      case 0x1200: "read timeout"
      case 0x2000: "syntax error"
      case 0x2100: "unauthorized"
      case 0x2200: "invalid query"
      case 0x2300: "configuration error"
      case 0x2400: "already exists"
      default: "error"
      }
    return DBServerError(engine: "CQL", code: String(format: "0x%04X", code), message: message, detail: kind)
  }
}

/// A CQL type option.
public indirect enum CQLType: Sendable, Hashable {
  case custom(String)
  case ascii, bigint, blob, boolean, counter, decimal, double, float, int, timestamp, uuid, varchar
  case varint, timeuuid, inet, date, time, smallint, tinyint, duration
  case list(CQLType)
  case set(CQLType)
  case map(CQLType, CQLType)
  case udt(keyspace: String, name: String, fields: [(String, CQLType)])
  case tuple([CQLType])

  public static func == (a: CQLType, b: CQLType) -> Bool { a.name == b.name }
  public func hash(into hasher: inout Hasher) { hasher.combine(name) }

  static func read(_ r: inout ByteReader) throws -> CQLType {
    let id = try r.readBE(UInt16.self)
    switch id {
    case 0x0000: return .custom(try CQLClient.readString(&r))
    case 0x0001: return .ascii
    case 0x0002: return .bigint
    case 0x0003: return .blob
    case 0x0004: return .boolean
    case 0x0005: return .counter
    case 0x0006: return .decimal
    case 0x0007: return .double
    case 0x0008: return .float
    case 0x0009: return .int
    case 0x000B: return .timestamp
    case 0x000C: return .uuid
    case 0x000D: return .varchar
    case 0x000E: return .varint
    case 0x000F: return .timeuuid
    case 0x0010: return .inet
    case 0x0011: return .date
    case 0x0012: return .time
    case 0x0013: return .smallint
    case 0x0014: return .tinyint
    case 0x0015: return .duration
    case 0x0020: return .list(try read(&r))
    case 0x0021: return .map(try read(&r), try read(&r))
    case 0x0022: return .set(try read(&r))
    case 0x0030:
      let keyspace = try CQLClient.readString(&r)
      let name = try CQLClient.readString(&r)
      let count = Int(try r.readBE(UInt16.self))
      var fields: [(String, CQLType)] = []
      for _ in 0..<count { fields.append((try CQLClient.readString(&r), try read(&r))) }
      return .udt(keyspace: keyspace, name: name, fields: fields)
    case 0x0031:
      let count = Int(try r.readBE(UInt16.self))
      var items: [CQLType] = []
      for _ in 0..<count { items.append(try read(&r)) }
      return .tuple(items)
    default:
      throw WireError.unsupported("CQL type \(id)")
    }
  }

  public var name: String {
    switch self {
    case .custom(let c):
      if c.contains("VectorType") { return "vector" }
      return c.split(separator: ".").last.map(String.init) ?? c
    case .ascii: return "ascii"
    case .bigint: return "bigint"
    case .blob: return "blob"
    case .boolean: return "boolean"
    case .counter: return "counter"
    case .decimal: return "decimal"
    case .double: return "double"
    case .float: return "float"
    case .int: return "int"
    case .timestamp: return "timestamp"
    case .uuid: return "uuid"
    case .varchar: return "text"
    case .varint: return "varint"
    case .timeuuid: return "timeuuid"
    case .inet: return "inet"
    case .date: return "date"
    case .time: return "time"
    case .smallint: return "smallint"
    case .tinyint: return "tinyint"
    case .duration: return "duration"
    case .list(let t): return "list<\(t.name)>"
    case .set(let t): return "set<\(t.name)>"
    case .map(let k, let v): return "map<\(k.name), \(v.name)>"
    case .udt(_, let name, _): return name
    case .tuple(let items): return "tuple<\(items.map(\.name).joined(separator: ", "))>"
    }
  }

  func decode(_ b: [UInt8]) -> DBValue {
    var r = ByteReader(b)
    switch self {
    case .ascii, .varchar: return .text(String(decoding: b, as: UTF8.self))
    case .bigint, .counter: return .int((try? r.readBE(Int64.self)) ?? 0)
    case .int: return .int(Int64((try? r.readBE(Int32.self)) ?? 0))
    case .smallint: return .int(Int64((try? r.readBE(Int16.self)) ?? 0))
    case .tinyint: return .int(Int64(Int8(bitPattern: b.first ?? 0)))
    case .boolean: return .bool(b.first != 0)
    case .blob, .custom: return .bytes(b)
    case .double: return .double((try? r.readDoubleBE()) ?? 0)
    case .float: return .double(Double((try? r.readFloatBE()) ?? 0))
    case .uuid, .timeuuid:
      guard b.count == 16 else { return .bytes(b) }
      return .uuid(
        UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])))
    case .varint: return .decimal(CQLText.bigInteger(b))
    case .decimal:
      guard b.count >= 4 else { return .bytes(b) }
      let scale = Int((try? r.readBE(Int32.self)) ?? 0)
      return .decimal(CQLText.scaled(CQLText.bigInteger(Array(b[4...])), scale: scale))
    case .timestamp:
      let ms = (try? r.readBE(Int64.self)) ?? 0
      return .text(CQLText.timestamp(milliseconds: ms))
    case .date:
      let days = Int64((try? r.readBE(UInt32.self)) ?? 0) - (1 << 31)
      return .text(CQLText.date(daysSinceEpoch: days))
    case .time:
      let ns = (try? r.readBE(Int64.self)) ?? 0
      return .text(CQLText.time(nanoseconds: ns))
    case .inet:
      if b.count == 4 { return .text(b.map(String.init).joined(separator: ".")) }
      return .text(stride(from: 0, to: b.count, by: 2).map { String(format: "%x", Int(b[$0]) << 8 | Int(b[$0 + 1])) }
        .joined(separator: ":"))
    case .duration:
      let months = CQLText.readVInt(&r)
      let days = CQLText.readVInt(&r)
      let nanos = CQLText.readVInt(&r)
      return .text(CQLText.duration(months: months, days: days, nanos: nanos))
    case .list(let t), .set(let t):
      let count = Int((try? r.readBE(Int32.self)) ?? 0)
      var items: [DBValue] = []
      for _ in 0..<max(count, 0) {
        guard let cell = try? CQLClient.readBytes(&r) else {
          items.append(.null)
          continue
        }
        items.append(t.decode(cell))
      }
      return .list(items)
    case .map(let k, let v):
      let count = Int((try? r.readBE(Int32.self)) ?? 0)
      var pairs: [DBPair] = []
      for _ in 0..<max(count, 0) {
        let key = (try? CQLClient.readBytes(&r)) ?? nil
        let value = (try? CQLClient.readBytes(&r)) ?? nil
        pairs.append(DBPair(key: key.map(k.decode) ?? .null, value: value.map(v.decode) ?? .null))
      }
      return .map(pairs)
    case .tuple(let types):
      return .list(types.map { t in ((try? CQLClient.readBytes(&r)) ?? nil).map(t.decode) ?? .null })
    case .udt(_, _, let fields):
      var pairs: [DBPair] = []
      for (name, t) in fields where !r.isAtEnd {
        let value = ((try? CQLClient.readBytes(&r)) ?? nil).map(t.decode) ?? .null
        pairs.append(DBPair(key: .text(name), value: value))
      }
      return .map(pairs)
    }
  }
}

/// Formatting helpers for CQL values and identifiers.
public enum CQLText {
  /// Quotes an identifier unless it's already a plain lowercase name.
  public static func identifier(_ name: String) -> String {
    let plain = name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil
    return plain ? name : "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// Two's complement big-endian → decimal string.
  static func bigInteger(_ bytes: [UInt8]) -> String {
    guard let first = bytes.first else { return "0" }
    let negative = first & 0x80 != 0
    var magnitude = bytes
    if negative {
      // Two's complement negate: invert and add one.
      magnitude = magnitude.map { ~$0 }
      var i = magnitude.count - 1
      while i >= 0 {
        let (sum, overflow) = magnitude[i].addingReportingOverflow(1)
        magnitude[i] = sum
        if !overflow { break }
        i -= 1
      }
    }
    var digits: [UInt8] = []
    while magnitude.contains(where: { $0 != 0 }) {
      var remainder = 0
      for i in magnitude.indices {
        let value = remainder << 8 | Int(magnitude[i])
        magnitude[i] = UInt8(value / 10)
        remainder = value % 10
      }
      digits.append(UInt8(remainder))
    }
    if digits.isEmpty { return "0" }
    let text = String(digits.reversed().map { Character(String($0)) })
    return negative ? "-" + text : text
  }

  static func scaled(_ integer: String, scale: Int) -> String {
    guard scale > 0 else { return integer }
    var negative = false
    var digits = integer
    if digits.hasPrefix("-") {
      negative = true
      digits.removeFirst()
    }
    while digits.count <= scale { digits = "0" + digits }
    digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -scale))
    return negative ? "-" + digits : digits
  }

  static let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()

  static func timestamp(milliseconds ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(ms) / 1000)
    let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let millis = ((ms % 1000) + 1000) % 1000
    return String(
      format: "%04d-%02d-%02d %02d:%02d:%02d.%03lldZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, millis)
  }

  static func date(daysSinceEpoch days: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(days) * 86400)
    let c = utc.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  static func time(nanoseconds ns: Int64) -> String {
    let seconds = ns / 1_000_000_000
    let fraction = ns % 1_000_000_000
    var text = String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    if fraction > 0 { text += String(format: ".%09lld", fraction) }
    return text
  }

  /// Zig-zag encoded unsigned vint (protocol v5 duration fields).
  static func readVInt(_ r: inout ByteReader) -> Int64 {
    guard let first = try? r.readByte() else { return 0 }
    var extra = 0
    var mask: UInt8 = 0x80
    while first & mask != 0 && extra < 8 {
      extra += 1
      mask >>= 1
    }
    var value = UInt64(first & (0xFF >> extra))
    for _ in 0..<extra { value = value << 8 | UInt64((try? r.readByte()) ?? 0) }
    return Int64(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
  }

  static func duration(months: Int64, days: Int64, nanos: Int64) -> String {
    var parts: [String] = []
    if months / 12 != 0 { parts.append("\(months / 12)y") }
    if months % 12 != 0 { parts.append("\(months % 12)mo") }
    if days != 0 { parts.append("\(days)d") }
    if nanos != 0 {
      var rest = nanos
      let hours = rest / 3_600_000_000_000
      rest %= 3_600_000_000_000
      let minutes = rest / 60_000_000_000
      rest %= 60_000_000_000
      let seconds = rest / 1_000_000_000
      rest %= 1_000_000_000
      if hours != 0 { parts.append("\(hours)h") }
      if minutes != 0 { parts.append("\(minutes)m") }
      if seconds != 0 { parts.append("\(seconds)s") }
      if rest != 0 { parts.append("\(rest)ns") }
    }
    return parts.isEmpty ? "0s" : parts.joined()
  }
}
