import Foundation
import Security
import WireKit

/// A MySQL / MariaDB client speaking the classic protocol (COM_QUERY, text results).
public actor MySQLClient {
  public struct Config: Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var password: String
    public var database: String?
    public var connectTimeout: TimeInterval

    public init(
      host: String = "127.0.0.1", port: Int = 3306, user: String, password: String = "",
      database: String? = nil, connectTimeout: TimeInterval = 15
    ) {
      self.host = host
      self.port = port
      self.user = user
      self.password = password
      self.database = database
      self.connectTimeout = connectTimeout
    }
  }

  // Capability flags.
  static let longPassword: UInt32 = 0x1
  static let longFlag: UInt32 = 0x4
  static let connectWithDB: UInt32 = 0x8
  static let protocol41: UInt32 = 0x200
  static let transactions: UInt32 = 0x2000
  static let secureConnection: UInt32 = 0x8000
  static let multiStatements: UInt32 = 0x10000
  static let multiResults: UInt32 = 0x20000
  static let psMultiResults: UInt32 = 0x40000
  static let pluginAuth: UInt32 = 0x80000
  static let pluginAuthLenencData: UInt32 = 0x200000

  public let config: Config
  private let wire: WireConnection
  private let exchange = AsyncMutex()
  private var sequence: UInt8 = 0
  public private(set) var serverVersion = ""
  public private(set) var connectionID: UInt32 = 0
  public private(set) var currentDatabase: String?

  /// MariaDB reports itself in the version string ("11.8.2-MariaDB").
  public var isMariaDB: Bool { serverVersion.localizedCaseInsensitiveContains("mariadb") }

  private init(config: Config, wire: WireConnection) {
    self.config = config
    self.wire = wire
    self.currentDatabase = config.database
  }

  public static func connect(_ config: Config) async throws -> MySQLClient {
    let wire = try await WireConnection.connect(host: config.host, port: config.port, timeout: config.connectTimeout)
    let client = MySQLClient(config: config, wire: wire)
    do {
      try await client.handshake()
    } catch {
      wire.close()
      throw error
    }
    return client
  }

  public var isOpen: Bool { wire.isOpen }

  public func close() async {
    if wire.isOpen {
      sequence = 0
      try? await writePacket([0x01])
    }
    wire.close()
  }

  // MARK: - Packets

  private func readPacket() async throws -> [UInt8] {
    var payload: [UInt8] = []
    while true {
      let header = try await wire.read(exactly: 4)
      let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
      sequence = header[3] &+ 1
      payload += try await wire.read(exactly: length)
      if length < 0xFF_FFFF { return payload }
    }
  }

  private func writePacket(_ payload: [UInt8]) async throws {
    var w = ByteWriter(capacity: payload.count + 4)
    var offset = 0
    repeat {
      let chunk = min(0xFF_FFFF, payload.count - offset)
      w.write(UInt8(chunk & 0xFF))
      w.write(UInt8((chunk >> 8) & 0xFF))
      w.write(UInt8((chunk >> 16) & 0xFF))
      w.write(sequence)
      sequence &+= 1
      w.write(payload[offset..<offset + chunk])
      offset += chunk
      if chunk < 0xFF_FFFF { break }
    } while true
    try await wire.send(w.bytes)
  }

  // MARK: - Handshake

  private func handshake() async throws {
    let greeting = try await readPacket()
    if greeting.first == 0xFF { throw Self.serverError(greeting) }
    var r = ByteReader(greeting)
    let protocolVersion = try r.readByte()
    guard protocolVersion == 10 else { throw WireError.unsupported("MySQL protocol \(protocolVersion)") }
    serverVersion = try r.readCString()
    connectionID = try r.readLE(UInt32.self)
    var scramble = try r.readBytes(8)
    try r.skip(1)
    var capabilities = UInt32(try r.readLE(UInt16.self))
    _ = try r.readByte()  // charset
    _ = try r.readLE(UInt16.self)  // status
    capabilities |= UInt32(try r.readLE(UInt16.self)) << 16
    let authDataLength = Int(try r.readByte())
    try r.skip(10)
    var pluginName = "mysql_native_password"
    if capabilities & Self.secureConnection != 0 {
      let part2Length = max(13, authDataLength - 8)
      scramble += try r.readBytes(part2Length).prefix(part2Length - 1)
    }
    if capabilities & Self.pluginAuth != 0, !r.isAtEnd {
      pluginName = (try? r.readCString()) ?? pluginName
    }

    var flags =
      Self.longPassword | Self.longFlag | Self.protocol41 | Self.transactions | Self.secureConnection
      | Self.multiStatements | Self.multiResults | Self.psMultiResults | Self.pluginAuth
      | Self.pluginAuthLenencData
    if config.database?.isEmpty == false { flags |= Self.connectWithDB }
    flags &= capabilities | Self.connectWithDB

    let authResponse = try Self.authResponse(plugin: pluginName, password: config.password, scramble: scramble)
    var w = ByteWriter()
    w.writeLE(flags)
    w.writeLE(UInt32(16 * 1024 * 1024))
    w.write(45)  // utf8mb4_general_ci
    w.write([UInt8](repeating: 0, count: 23))
    w.writeCString(config.user)
    Self.writeLengthEncoded(&w, authResponse.count)
    w.write(authResponse)
    if flags & Self.connectWithDB != 0, let db = config.database { w.writeCString(db) }
    w.writeCString(pluginName)
    try await writePacket(w.bytes)

    try await finishAuthentication(plugin: pluginName, scramble: scramble)
  }

  private func finishAuthentication(plugin: String, scramble: [UInt8]) async throws {
    var plugin = plugin
    var scramble = scramble
    while true {
      let packet = try await readPacket()
      guard let head = packet.first else { throw WireError.truncated }
      switch head {
      case 0x00:
        return
      case 0xFF:
        throw Self.serverError(packet)
      case 0xFE:
        // AuthSwitchRequest: another plugin and a fresh scramble.
        var r = ByteReader(packet, offset: 1)
        plugin = try r.readCString()
        var data = r.readRest()
        if data.last == 0 { data.removeLast() }
        scramble = data
        try await writePacket(try Self.authResponse(plugin: plugin, password: config.password, scramble: scramble))
      case 0x01:
        // caching_sha2_password: 3 = fast auth succeeded (OK follows), 4 = send the full password.
        guard packet.count >= 2 else { throw WireError.truncated }
        if plugin == "caching_sha2_password" && packet[1] == 0x03 { continue }
        if plugin == "caching_sha2_password" && packet[1] == 0x04 {
          try await writePacket([0x02])  // ask for the server's RSA key
          let keyPacket = try await readPacket()
          guard keyPacket.first == 0x01 else { throw Self.serverError(keyPacket) }
          let pem = String(decoding: keyPacket.dropFirst(), as: UTF8.self)
          var plain = Array(config.password.utf8) + [0]
          for i in plain.indices { plain[i] ^= scramble[i % scramble.count] }
          try await writePacket(try RSAPublicKey.encryptOAEP(plain, pem: pem))
          continue
        }
        throw WireError.protocolViolation("unexpected auth data")
      default:
        throw WireError.protocolViolation("unexpected packet 0x\(String(head, radix: 16)) during login")
      }
    }
  }

  static func authResponse(plugin: String, password: String, scramble: [UInt8]) throws -> [UInt8] {
    if password.isEmpty { return [] }
    let pw = Array(password.utf8)
    switch plugin {
    case "mysql_native_password":
      let stage1 = Digest.sha1(pw)
      let stage2 = Digest.sha1(stage1)
      return Digest.xor(stage1, Digest.sha1(scramble.prefix(20) + stage2))
    case "caching_sha2_password":
      let stage1 = Digest.sha256(pw)
      let stage2 = Digest.sha256(stage1)
      return Digest.xor(stage1, Digest.sha256(stage2 + scramble.prefix(20)))
    case "mysql_clear_password":
      return pw + [0]
    default:
      throw WireError.unsupported("the \(plugin) login method")
    }
  }

  // MARK: - Commands

  /// Runs one or more statements; returns one result per statement.
  public func query(_ sql: String) async throws -> [DBResult] {
    try await exchange.run { try await self.comQuery(sql) }
  }

  private func comQuery(_ sql: String) async throws -> [DBResult] {
    sequence = 0
    try await writePacket([0x03] + Array(sql.utf8))
    var results: [DBResult] = []
    while true {
      let (result, more) = try await readResult()
      results.append(result)
      if !more { return results }
    }
  }

  public func execute(_ sql: String) async throws -> DBResult {
    try await query(sql).last ?? DBResult()
  }

  public func use(database: String) async throws {
    try await exchange.run { try await self.initDB(database) }
  }

  private func initDB(_ database: String) async throws {
    sequence = 0
    try await writePacket([0x02] + Array(database.utf8))
    let packet = try await readPacket()
    if packet.first == 0xFF { throw Self.serverError(packet) }
    currentDatabase = database
  }

  public func ping() async throws {
    try await exchange.run { try await self.comPing() }
  }

  private func comPing() async throws {
    sequence = 0
    try await writePacket([0x0E])
    let packet = try await readPacket()
    if packet.first == 0xFF { throw Self.serverError(packet) }
  }

  /// Kills whatever this connection is running, from a second connection.
  public func cancel() async {
    guard let side = try? await MySQLClient.connect(config) else { return }
    _ = try? await side.query("KILL QUERY \(connectionID)")
    await side.close()
  }

  private static let moreResultsExist: UInt16 = 0x0008

  /// Reads one statement's response. Returns whether more results follow.
  private func readResult() async throws -> (DBResult, Bool) {
    let first = try await readPacket()
    guard let head = first.first else { throw WireError.truncated }
    if head == 0xFF { throw Self.serverError(first) }
    if head == 0x00 {
      var r = ByteReader(first, offset: 1)
      let affected = try Self.readLengthEncoded(&r)
      _ = try Self.readLengthEncoded(&r)  // last insert id
      let status = try r.readLE(UInt16.self)
      let warnings = try r.readLE(UInt16.self)
      let info = String(decoding: r.readRest(), as: UTF8.self)
      var messages: [String] = []
      if !info.isEmpty { messages.append(info) }
      if warnings > 0 { messages.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
      return (
        DBResult(affectedRows: Int(affected ?? 0), messages: messages),
        status & Self.moreResultsExist != 0
      )
    }
    if head == 0xFB { throw WireError.unsupported("LOAD DATA LOCAL INFILE") }

    var r = ByteReader(first)
    let columnCount = Int(try Self.readLengthEncoded(&r) ?? 0)
    var columns: [MySQLColumn] = []
    for _ in 0..<columnCount {
      columns.append(try MySQLColumn(packet: try await readPacket()))
    }
    var eof = try await readPacket()
    if eof.first != 0xFE { throw WireError.protocolViolation("expected EOF after columns") }

    var result = DBResult(columns: columns.map { DBColumn(name: $0.name, typeName: $0.typeName, table: $0.table) })
    while true {
      let packet = try await readPacket()
      if packet.first == 0xFE && packet.count < 9 {
        eof = packet
        break
      }
      if packet.first == 0xFF { throw Self.serverError(packet) }
      var row: [DBValue] = []
      row.reserveCapacity(columnCount)
      var rr = ByteReader(packet)
      for column in columns {
        if try rr.peek() == 0xFB {
          try rr.skip(1)
          row.append(.null)
        } else {
          let length = Int(try Self.readLengthEncoded(&rr) ?? 0)
          row.append(column.decode(try rr.readBytes(length)))
        }
      }
      result.rows.append(row)
    }
    var er = ByteReader(eof, offset: 1)
    _ = try? er.readLE(UInt16.self)  // warnings
    let status = (try? er.readLE(UInt16.self)) ?? 0
    return (result, status & Self.moreResultsExist != 0)
  }

  // MARK: - Encoding helpers

  static func readLengthEncoded(_ r: inout ByteReader) throws -> UInt64? {
    let first = try r.readByte()
    switch first {
    case 0xFB: return nil
    case 0xFC: return UInt64(try r.readLE(UInt16.self))
    case 0xFD:
      let bytes = try r.readBytes(3)
      return UInt64(bytes[0]) | UInt64(bytes[1]) << 8 | UInt64(bytes[2]) << 16
    case 0xFE: return try r.readLE(UInt64.self)
    default: return UInt64(first)
    }
  }

  static func writeLengthEncoded(_ w: inout ByteWriter, _ value: Int) {
    switch value {
    case ..<251: w.write(UInt8(value))
    case ..<65536:
      w.write(0xFC)
      w.writeLE(UInt16(value))
    case ..<16_777_216:
      w.write(0xFD)
      w.write(UInt8(value & 0xFF))
      w.write(UInt8((value >> 8) & 0xFF))
      w.write(UInt8((value >> 16) & 0xFF))
    default:
      w.write(0xFE)
      w.writeLE(UInt64(value))
    }
  }

  static func serverError(_ packet: [UInt8]) -> DBServerError {
    var r = ByteReader(packet, offset: 1)
    let code = (try? r.readLE(UInt16.self)) ?? 0
    var state: String?
    if (try? r.peek()) == UInt8(ascii: "#") {
      try? r.skip(1)
      state = try? r.readUTF8(5)
    }
    let message = String(decoding: r.readRest(), as: UTF8.self)
    return DBServerError(engine: "MySQL", code: state.map { "\(code) (\($0))" } ?? String(code), message: message)
  }
}

/// A result-set column definition.
struct MySQLColumn {
  var table: String
  var name: String
  var type: UInt8
  var flags: UInt16
  var charset: UInt16
  var decimals: UInt8

  init(packet: [UInt8]) throws {
    var r = ByteReader(packet)
    func lenString() throws -> String {
      let length = Int(try MySQLClient.readLengthEncoded(&r) ?? 0)
      return try r.readUTF8(length)
    }
    _ = try lenString()  // catalog
    _ = try lenString()  // schema
    table = try lenString()
    _ = try lenString()  // original table
    name = try lenString()
    _ = try lenString()  // original name
    _ = try MySQLClient.readLengthEncoded(&r)
    charset = try r.readLE(UInt16.self)
    _ = try r.readLE(UInt32.self)  // display length
    type = try r.readByte()
    flags = try r.readLE(UInt16.self)
    decimals = try r.readByte()
  }

  var isUnsigned: Bool { flags & 0x20 != 0 }
  var isBinary: Bool { charset == 63 }

  var typeName: String {
    let base: String =
      switch type {
      case 0x00, 0xF6: "decimal"
      case 0x01: "tinyint"
      case 0x02: "smallint"
      case 0x03: "int"
      case 0x04: "float"
      case 0x05: "double"
      case 0x06: "null"
      case 0x07: "timestamp"
      case 0x08: "bigint"
      case 0x09: "mediumint"
      case 0x0A: "date"
      case 0x0B: "time"
      case 0x0C: "datetime"
      case 0x0D: "year"
      case 0x0F, 0xFD: isBinary ? "varbinary" : "varchar"
      case 0x10: "bit"
      case 0xF5: "json"
      case 0xF7: "enum"
      case 0xF8: "set"
      case 0xF9, 0xFA, 0xFB, 0xFC: isBinary ? "blob" : "text"
      case 0xFE: isBinary ? "binary" : "char"
      case 0xFF: "geometry"
      default: "type \(type)"
      }
    return isUnsigned ? base + " unsigned" : base
  }

  func decode(_ bytes: [UInt8]) -> DBValue {
    let text = String(decoding: bytes, as: UTF8.self)
    switch type {
    case 0x01, 0x02, 0x03, 0x08, 0x09, 0x0D:
      if let i = Int64(text) { return .int(i) }
      return .decimal(text)
    case 0x04, 0x05: return Double(text).map(DBValue.double) ?? .text(text)
    case 0x00, 0xF6: return .decimal(text)
    case 0x10:
      var value: Int64 = 0
      for b in bytes { value = value << 8 | Int64(b) }
      return .int(value)
    case 0xF5: return .json(text)
    case 0xFF: return .bytes(bytes)
    case 0x0F, 0xFD, 0xFE, 0xF9, 0xFA, 0xFB, 0xFC:
      return isBinary ? .bytes(bytes) : .text(text)
    default: return .text(text)
    }
  }
}

/// RSA-OAEP with a PEM public key (caching_sha2_password full authentication).
enum RSAPublicKey {
  static func encryptOAEP(_ plain: [UInt8], pem: String) throws -> [UInt8] {
    let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
    guard let der = Data(base64Encoded: base64) else { throw WireError.protocolViolation("bad RSA key") }
    let pkcs1 = try stripSubjectPublicKeyInfo([UInt8](der))
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
      throw WireError.protocolViolation("the server's RSA key couldn't be read")
    }
    guard
      let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(plain) as CFData, &error)
    else { throw WireError.authenticationFailed("couldn't encrypt the password") }
    return [UInt8](encrypted as Data)
  }

  /// SubjectPublicKeyInfo → the inner PKCS#1 RSAPublicKey. Returns the input if it's already PKCS#1.
  static func stripSubjectPublicKeyInfo(_ der: [UInt8]) throws -> [UInt8] {
    var r = ByteReader(der)
    func readLength() throws -> Int {
      let first = try r.readByte()
      if first & 0x80 == 0 { return Int(first) }
      var length = 0
      for _ in 0..<Int(first & 0x7F) { length = length << 8 | Int(try r.readByte()) }
      return length
    }
    guard try r.readByte() == 0x30 else { return der }
    _ = try readLength()
    // PKCS#1 starts with INTEGER (modulus); SPKI with SEQUENCE (algorithm).
    guard try r.peek() == 0x30 else { return der }
    try r.skip(1)
    try r.skip(try readLength())
    guard try r.readByte() == 0x03 else { return der }
    let bitLength = try readLength()
    try r.skip(1)  // unused-bits byte
    return try r.readBytes(bitLength - 1)
  }
}
