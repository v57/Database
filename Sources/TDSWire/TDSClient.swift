import Foundation
import WireKit

/// A Microsoft SQL Server client speaking TDS 7.4 (SQL batches, SQL logins).
///
/// The login is sent unencrypted, which SQL Server allows unless "Force Encryption"
/// is on; servers that require encryption are reached through an SSH tunnel instead.
public actor TDSClient {
  public struct Config: Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var password: String
    public var database: String?
    public var applicationName: String
    public var connectTimeout: TimeInterval
    /// How to reach the server: TCP from this device, or a channel of an SSH connection.
    public var dialer: WireDialer

    public init(
      host: String = "127.0.0.1", port: Int = 1433, user: String, password: String,
      database: String? = nil, applicationName: String = "Database", connectTimeout: TimeInterval = 15,
      dialer: WireDialer = .direct
    ) {
      self.host = host
      self.port = port
      self.user = user
      self.password = password
      self.database = database
      self.applicationName = applicationName
      self.connectTimeout = connectTimeout
      self.dialer = dialer
    }
  }

  enum PacketType: UInt8 {
    case sqlBatch = 0x01
    case reply = 0x04
    case attention = 0x06
    case login7 = 0x10
    case prelogin = 0x12
  }

  public let config: Config
  private let wire: WireConnection
  private let exchange = AsyncMutex()
  private var packetSize = 4096
  private var transactionDescriptor: [UInt8] = Array(repeating: 0, count: 8)
  public private(set) var currentDatabase: String?
  public private(set) var serverVersion = ""
  public private(set) var serverName = ""

  private init(config: Config, wire: WireConnection) {
    self.config = config
    self.wire = wire
  }

  public static func connect(_ config: Config) async throws -> TDSClient {
    let wire = try await config.dialer.connect(host: config.host, port: config.port, timeout: config.connectTimeout)
    let client = TDSClient(config: config, wire: wire)
    do {
      try await client.prelogin()
      try await client.login()
    } catch {
      wire.close()
      throw error
    }
    return client
  }

  public var isOpen: Bool { wire.isOpen }
  public var inTransaction: Bool { transactionDescriptor.contains { $0 != 0 } }

  public func close() {
    wire.close()
  }

  // MARK: - Packets

  private func sendMessage(_ type: PacketType, _ payload: [UInt8]) async throws {
    let maxBody = packetSize - 8
    var offset = 0
    var packetID: UInt8 = 1
    var out = ByteWriter(capacity: payload.count + 8 * (payload.count / maxBody + 1))
    repeat {
      let chunk = min(maxBody, payload.count - offset)
      let last = offset + chunk >= payload.count
      out.write(type.rawValue)
      out.write(last ? 0x01 : 0x00)
      out.writeBE(UInt16(chunk + 8))
      out.writeBE(UInt16(0))
      out.write(packetID)
      out.write(0)
      out.write(payload[offset..<offset + chunk])
      offset += chunk
      packetID &+= 1
    } while offset < payload.count
    try await wire.send(out.bytes)
  }

  private func readMessage() async throws -> [UInt8] {
    var payload: [UInt8] = []
    while true {
      let header = try await wire.read(exactly: 8)
      let status = header[1]
      let length = Int(header[2]) << 8 | Int(header[3])
      guard length >= 8 else { throw WireError.protocolViolation("bad TDS packet length") }
      payload += try await wire.read(exactly: length - 8)
      if status & 0x01 != 0 { return payload }
    }
  }

  // MARK: - Login

  private func prelogin() async throws {
    // Options: VERSION, ENCRYPTION, INSTOPT, THREADID, MARS, terminator.
    let optionData: [(UInt8, [UInt8])] = [
      (0x00, [0x10, 0x00, 0x00, 0x00, 0x00, 0x00]),
      (0x01, [0x02]),  // ENCRYPT_NOT_SUP
      (0x02, [0x00]),
      (0x03, [0, 0, 0, 0]),
      (0x04, [0x00]),
    ]
    var header = ByteWriter()
    var data = ByteWriter()
    let headerLength = optionData.count * 5 + 1
    for (token, bytes) in optionData {
      header.write(token)
      header.writeBE(UInt16(headerLength + data.count))
      header.writeBE(UInt16(bytes.count))
      data.write(bytes)
    }
    header.write(0xFF)
    try await sendMessage(.prelogin, header.bytes + data.bytes)

    let reply = try await readMessage()
    var r = ByteReader(reply)
    while let token = try? r.readByte(), token != 0xFF {
      let offset = Int(try r.readBE(UInt16.self))
      let length = Int(try r.readBE(UInt16.self))
      if token == 0x01, length >= 1, offset < reply.count {
        let encryption = reply[offset]
        if encryption == 0x03 || encryption == 0x01 {
          throw WireError.unsupported(
            "this server requires encryption. Connect through an SSH tunnel, or turn off Force Encryption.")
        }
      }
    }
  }

  private func login() async throws {
    let hostName = ProcessInfo.processInfo.hostName
    let strings: [String] = [
      hostName, config.user, config.password, config.applicationName, config.host, "", "Database",
      "", config.database ?? "",
    ]
    var fixed = ByteWriter(capacity: 94)
    fixed.writeLE(UInt32(0))  // total length, patched below
    fixed.writeLE(UInt32(0x7400_0004))  // TDS 7.4
    fixed.writeLE(UInt32(packetSize))
    fixed.writeLE(UInt32(0x0100_0000))  // client program version
    fixed.writeLE(UInt32(ProcessInfo.processInfo.processIdentifier))
    fixed.writeLE(UInt32(0))  // connection id
    fixed.write(0xE0)  // USE_DB_ON | INIT_DB_FATAL | SET_LANG_ON
    fixed.write(0x03)  // INIT_LANG_FATAL | ODBC_ON
    fixed.write(0x00)
    fixed.write(0x00)
    fixed.writeLE(Int32(0))  // time zone
    fixed.writeLE(UInt32(0x0409))  // LCID en-US

    var variable = ByteWriter()
    var offset = 94
    for (index, string) in strings.enumerated() {
      var bytes = Self.ucs2(string)
      if index == 2 { bytes = bytes.map { (($0 << 4) | ($0 >> 4)) ^ 0xA5 } }  // password obfuscation
      fixed.writeLE(UInt16(offset))
      fixed.writeLE(UInt16(bytes.count / 2))
      variable.write(bytes)
      offset += bytes.count
    }
    fixed.write([0, 0, 0, 0, 0, 0])  // client MAC
    for _ in 0..<3 {  // SSPI, attach-db file, change password
      fixed.writeLE(UInt16(offset))
      fixed.writeLE(UInt16(0))
    }
    fixed.writeLE(UInt32(0))  // SSPI long
    var packet = fixed
    packet.write(variable.bytes)
    packet.patchLE(Int32(packet.count), at: 0)
    try await sendMessage(.login7, packet.bytes)

    let reply = try await readMessage()
    let outcome = try absorb(reply)
    if let error = outcome.errors.first { throw error }
    guard outcome.loggedIn else { throw WireError.authenticationFailed("SQL Server didn't accept the login") }
  }

  // MARK: - Queries

  /// Runs a batch; returns one result per statement that produced rows or a count.
  public func query(_ sql: String) async throws -> [DBResult] {
    try await exchange.run { try await self.sqlBatch(sql) }
  }

  private func sqlBatch(_ sql: String) async throws -> [DBResult] {
    var payload = ByteWriter()
    payload.writeLE(UInt32(22))  // ALL_HEADERS total length
    payload.writeLE(UInt32(18))  // header length
    payload.writeLE(UInt16(0x0002))  // transaction descriptor header
    payload.write(transactionDescriptor)
    payload.writeLE(UInt32(1))  // outstanding requests
    payload.write(Self.ucs2(sql))
    try await sendMessage(.sqlBatch, payload.bytes)
    let outcome = try absorb(try await readMessage())
    if let error = outcome.errors.first { throw error }
    return outcome.results
  }

  public func execute(_ sql: String) async throws -> DBResult {
    try await query(sql).last ?? DBResult()
  }

  public func use(database: String) async throws {
    _ = try await query("USE [\(database.replacingOccurrences(of: "]", with: "]]"))]")
  }

  // MARK: - Environment changes

  /// Parses a reply and applies its environment changes (database, packet size, transaction).
  private func absorb(_ reply: [UInt8]) throws -> TokenOutcome {
    var stream = TokenStream(bytes: reply)
    let outcome = try stream.parse()
    for (type, value) in outcome.envChanges { apply(envChange: type, newValue: value) }
    if outcome.loggedIn { setServer(name: outcome.serverName, version: outcome.serverVersion) }
    return outcome
  }

  func apply(envChange type: UInt8, newValue: [UInt8]) {
    switch type {
    case 1: currentDatabase = String(decoding: newValue, as: UTF16.self, littleEndian: true)
    case 4:
      if let size = Int(String(decoding: newValue, as: UTF16.self, littleEndian: true)) { packetSize = size }
    case 8: transactionDescriptor = newValue.count == 8 ? newValue : Array(repeating: 0, count: 8)
    case 9, 10: transactionDescriptor = Array(repeating: 0, count: 8)
    default: break
    }
  }

  func setServer(name: String, version: String) {
    serverName = name
    serverVersion = version
  }

  static func ucs2(_ string: String) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(string.utf16.count * 2)
    for unit in string.utf16 {
      out.append(UInt8(unit & 0xFF))
      out.append(UInt8(unit >> 8))
    }
    return out
  }
}

extension String {
  init(decoding bytes: [UInt8], as: UTF16.Type, littleEndian: Bool) {
    var units: [UInt16] = []
    units.reserveCapacity(bytes.count / 2)
    var i = 0
    while i + 1 < bytes.count {
      units.append(littleEndian ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
      i += 2
    }
    self = String(decoding: units, as: UTF16.self)
  }
}
