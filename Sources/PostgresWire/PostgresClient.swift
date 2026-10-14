import Foundation
import WireKit

/// A PostgreSQL client speaking the v3 frontend/backend protocol (simple queries, text results).
public actor PostgresClient {
  public struct Config: Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var password: String
    public var database: String
    /// TLS from the first byte (PostgreSQL 17+ `sslnegotiation=direct`).
    public var tls: TLSSettings
    public var applicationName: String
    public var connectTimeout: TimeInterval

    public init(
      host: String = "127.0.0.1", port: Int = 5432, user: String, password: String = "",
      database: String = "postgres", tls: TLSSettings = .off, applicationName: String = "Database",
      connectTimeout: TimeInterval = 15
    ) {
      self.host = host
      self.port = port
      self.user = user
      self.password = password
      self.database = database
      self.tls = tls
      self.applicationName = applicationName
      self.connectTimeout = connectTimeout
    }
  }

  public let config: Config
  private let wire: WireConnection
  private let exchange = AsyncMutex()
  public private(set) var parameters: [String: String] = [:]
  private var processID: Int32 = 0
  private var secretKey: [UInt8] = []

  private init(config: Config, wire: WireConnection) {
    self.config = config
    self.wire = wire
  }

  public static func connect(_ config: Config) async throws -> PostgresClient {
    var tls = config.tls
    if tls.enabled && tls.alpn.isEmpty { tls.alpn = ["postgresql"] }
    let wire = try await WireConnection.connect(
      host: config.host, port: config.port, tls: tls, timeout: config.connectTimeout)
    let client = PostgresClient(config: config, wire: wire)
    do {
      try await client.startup()
    } catch {
      wire.close()
      throw error
    }
    return client
  }

  public var serverVersion: String { parameters["server_version"] ?? "" }

  /// "17.2" → 170002-style major number, for feature checks.
  public var serverMajorVersion: Int {
    Int(serverVersion.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 0
  }

  public var isOpen: Bool { wire.isOpen }

  public func close() async {
    if wire.isOpen {
      var w = ByteWriter()
      w.write(UInt8(ascii: "X"))
      w.writeBE(Int32(4))
      try? await wire.send(w.bytes)
    }
    wire.close()
  }

  // MARK: - Messages

  private struct Message {
    var type: UInt8
    var body: [UInt8]
  }

  private func readMessage() async throws -> Message {
    let header = try await wire.read(exactly: 5)
    var reader = ByteReader(header)
    let type = try reader.readByte()
    let length = Int(try reader.readBE(Int32.self))
    guard length >= 4 else { throw WireError.protocolViolation("bad message length") }
    let body = try await wire.read(exactly: length - 4)
    return Message(type: type, body: body)
  }

  private func send(type: UInt8, _ body: [UInt8]) async throws {
    var w = ByteWriter(capacity: body.count + 5)
    w.write(type)
    w.writeBE(Int32(body.count + 4))
    w.write(body)
    try await wire.send(w.bytes)
  }

  // MARK: - Startup and authentication

  private func startup() async throws {
    var body = ByteWriter()
    body.writeBE(Int32(196608))  // protocol 3.0
    for (key, value) in [
      ("user", config.user), ("database", config.database), ("application_name", config.applicationName),
      ("client_encoding", "UTF8"), ("DateStyle", "ISO, YMD"),
    ] {
      body.writeCString(key)
      body.writeCString(value)
    }
    body.write(0)
    var packet = ByteWriter()
    packet.writeBE(Int32(body.count + 4))
    packet.write(body.bytes)
    try await wire.send(packet.bytes)

    var scram: SCRAMClient?
    while true {
      let message = try await readMessage()
      var reader = ByteReader(message.body)
      switch message.type {
      case UInt8(ascii: "R"):
        let code = try reader.readBE(Int32.self)
        switch code {
        case 0: break  // AuthenticationOk
        case 3:
          var w = ByteWriter()
          w.writeCString(config.password)
          try await send(type: UInt8(ascii: "p"), w.bytes)
        case 5:
          let salt = try reader.readBytes(4)
          let inner = Digest.md5Hex(Array((config.password + config.user).utf8))
          let outer = "md5" + Digest.md5Hex(Array(inner.utf8) + salt)
          var w = ByteWriter()
          w.writeCString(outer)
          try await send(type: UInt8(ascii: "p"), w.bytes)
        case 10:
          var mechanisms: [String] = []
          while reader.remaining > 1 { mechanisms.append(try reader.readCString()) }
          guard mechanisms.contains("SCRAM-SHA-256") else {
            throw WireError.authenticationFailed("server wants \(mechanisms.joined(separator: ", "))")
          }
          var client = SCRAMClient(hash: .sha256, username: "", password: config.password)
          let first = Array(client.clientFirstMessage().utf8)
          scram = client
          var w = ByteWriter()
          w.writeCString("SCRAM-SHA-256")
          w.writeBE(Int32(first.count))
          w.write(first)
          try await send(type: UInt8(ascii: "p"), w.bytes)
        case 11:
          guard var client = scram else { throw WireError.protocolViolation("SASL continue without start") }
          let serverFirst = String(decoding: reader.readRest(), as: UTF8.self)
          let final = try client.clientFinalMessage(serverFirst: serverFirst)
          scram = client
          try await send(type: UInt8(ascii: "p"), Array(final.utf8))
        case 12:
          let serverFinal = String(decoding: reader.readRest(), as: UTF8.self)
          try scram?.verify(serverFinal: serverFinal)
        default:
          throw WireError.unsupported("PostgreSQL authentication method \(code)")
        }
      case UInt8(ascii: "S"):
        let key = try reader.readCString()
        parameters[key] = try reader.readCString()
      case UInt8(ascii: "K"):
        processID = try reader.readBE(Int32.self)
        secretKey = reader.readRest()
      case UInt8(ascii: "Z"):
        return
      case UInt8(ascii: "E"):
        throw Self.serverError(message.body)
      case UInt8(ascii: "N"):
        continue
      case UInt8(ascii: "v"):
        continue  // NegotiateProtocolVersion: the server accepts our 3.0 subset
      default:
        throw WireError.protocolViolation("unexpected '\(Character(UnicodeScalar(message.type)))' during startup")
      }
    }
  }

  // MARK: - Queries

  /// Runs one or more `;`-separated statements and returns a result per statement.
  public func query(_ sql: String) async throws -> [DBResult] {
    try await exchange.run { try await self.simpleQuery(sql) }
  }

  private func simpleQuery(_ sql: String) async throws -> [DBResult] {
    var w = ByteWriter()
    w.writeCString(sql)
    try await send(type: UInt8(ascii: "Q"), w.bytes)

    var results: [DBResult] = []
    var current = DBResult()
    var typeOIDs: [Int32] = []
    var notices: [String] = []
    var failure: Error?

    while true {
      let message = try await readMessage()
      var reader = ByteReader(message.body)
      switch message.type {
      case UInt8(ascii: "T"):
        current = DBResult()
        typeOIDs = []
        let count = Int(try reader.readBE(Int16.self))
        for _ in 0..<count {
          let name = try reader.readCString()
          _ = try reader.readBE(Int32.self)  // table oid
          _ = try reader.readBE(Int16.self)  // column number
          let oid = try reader.readBE(Int32.self)
          _ = try reader.readBE(Int16.self)  // type size
          _ = try reader.readBE(Int32.self)  // type modifier
          _ = try reader.readBE(Int16.self)  // format
          typeOIDs.append(oid)
          current.columns.append(DBColumn(name: name, typeName: PostgresTypes.name(for: oid)))
        }
      case UInt8(ascii: "D"):
        let count = Int(try reader.readBE(Int16.self))
        var row: [DBValue] = []
        row.reserveCapacity(count)
        for i in 0..<count {
          let length = Int(try reader.readBE(Int32.self))
          if length < 0 {
            row.append(.null)
          } else {
            let bytes = try reader.readBytes(length)
            let oid = i < typeOIDs.count ? typeOIDs[i] : 25
            row.append(PostgresTypes.decode(text: String(decoding: bytes, as: UTF8.self), oid: oid))
          }
        }
        current.rows.append(row)
      case UInt8(ascii: "C"):
        let tag = try reader.readCString()
        current.commandTag = tag
        current.affectedRows = Self.affectedRows(fromTag: tag)
        current.messages = notices
        notices = []
        results.append(current)
        current = DBResult()
      case UInt8(ascii: "I"):
        results.append(DBResult(messages: notices))
        notices = []
      case UInt8(ascii: "N"):
        notices.append(Self.serverError(message.body).message)
      case UInt8(ascii: "E"):
        failure = Self.serverError(message.body)
      case UInt8(ascii: "S"):
        let key = try reader.readCString()
        parameters[key] = try reader.readCString()
      case UInt8(ascii: "Z"):
        if let failure { throw failure }
        return results
      case UInt8(ascii: "A"), UInt8(ascii: "G"), UInt8(ascii: "H"):
        // Notifications and COPY aren't used here; COPY gets refused below.
        if message.type == UInt8(ascii: "G") || message.type == UInt8(ascii: "H") {
          var fail = ByteWriter()
          fail.writeCString("COPY isn't supported in Database")
          try await send(type: UInt8(ascii: "f"), fail.bytes)
        }
      default:
        continue
      }
    }
  }

  /// The last statement's result, for single-statement calls.
  public func execute(_ sql: String) async throws -> DBResult {
    try await query(sql).last ?? DBResult()
  }

  /// Asks the server to cancel whatever this connection is running.
  public func cancel() async {
    guard processID != 0,
      let side = try? await WireConnection.connect(host: config.host, port: config.port, tls: config.tls, timeout: 5)
    else { return }
    var w = ByteWriter()
    w.writeBE(Int32(16))
    w.writeBE(Int32(80_877_102))
    w.writeBE(processID)
    w.write(secretKey)
    try? await side.send(w.bytes)
    side.close()
  }

  static func affectedRows(fromTag tag: String) -> Int? {
    let parts = tag.split(separator: " ")
    guard let verb = parts.first else { return nil }
    switch verb {
    case "INSERT", "UPDATE", "DELETE", "SELECT", "MOVE", "FETCH", "COPY", "MERGE":
      return parts.last.flatMap { Int($0) }
    default:
      return nil
    }
  }

  static func serverError(_ body: [UInt8]) -> DBServerError {
    var reader = ByteReader(body)
    var fields: [UInt8: String] = [:]
    while let type = try? reader.readByte(), type != 0 {
      fields[type] = (try? reader.readCString()) ?? ""
    }
    return DBServerError(
      engine: "PostgreSQL", code: fields[UInt8(ascii: "C")],
      message: fields[UInt8(ascii: "M")] ?? "Unknown error",
      detail: fields[UInt8(ascii: "D")] ?? fields[UInt8(ascii: "H")])
  }
}

/// PostgreSQL built-in type OIDs → names and value decoding.
public enum PostgresTypes {
  static let names: [Int32: String] = [
    16: "boolean", 17: "bytea", 18: "char", 19: "name", 20: "bigint", 21: "smallint", 23: "integer",
    24: "regproc", 25: "text", 26: "oid", 114: "json", 142: "xml", 650: "cidr", 700: "real",
    701: "double precision", 790: "money", 829: "macaddr", 869: "inet", 1000: "boolean[]", 1005: "smallint[]",
    1007: "integer[]", 1009: "text[]", 1014: "char[]", 1015: "varchar[]", 1016: "bigint[]", 1021: "real[]",
    1022: "double precision[]", 1042: "character", 1043: "character varying", 1082: "date", 1083: "time",
    1114: "timestamp", 1184: "timestamptz", 1186: "interval", 1266: "timetz", 1560: "bit", 1562: "varbit",
    1700: "numeric", 2249: "record", 2278: "void", 2950: "uuid", 3614: "tsvector", 3802: "jsonb",
    3904: "int4range", 3926: "int8range", 4089: "regnamespace", 1231: "numeric[]", 2951: "uuid[]",
    3807: "jsonb[]", 1115: "timestamp[]", 1185: "timestamptz[]", 1182: "date[]", 2205: "regclass",
  ]

  public static func name(for oid: Int32) -> String { names[oid] ?? "oid \(oid)" }

  public static func decode(text: String, oid: Int32) -> DBValue {
    switch oid {
    case 16: return .bool(text == "t")
    case 20, 21, 23, 26: return Int64(text).map(DBValue.int) ?? .text(text)
    case 700, 701:
      switch text {
      case "NaN": return .double(.nan)
      case "Infinity": return .double(.infinity)
      case "-Infinity": return .double(-.infinity)
      default: return Double(text).map(DBValue.double) ?? .text(text)
      }
    case 1700, 790: return .decimal(text)
    case 17:
      if text.hasPrefix("\\x") { return .bytes(hexBytes(text.dropFirst(2))) }
      return .bytes(Array(text.utf8))
    case 2950: return UUID(uuidString: text).map(DBValue.uuid) ?? .text(text)
    case 114, 3802: return .json(text)
    default: return .text(text)
    }
  }

  static func hexBytes(_ hex: Substring) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(hex.count / 2)
    var iterator = hex.utf8.makeIterator()
    while let a = iterator.next(), let b = iterator.next() {
      func nibble(_ c: UInt8) -> UInt8 {
        switch c {
        case 48...57: c - 48
        case 97...102: c - 87
        case 65...70: c - 55
        default: 0
        }
      }
      out.append(nibble(a) << 4 | nibble(b))
    }
    return out
  }
}
