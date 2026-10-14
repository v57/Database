import BSON
import Foundation
import WireKit

public struct MongoError: Error, LocalizedError, Sendable {
  public var code: Int?
  public var codeName: String?
  public var message: String
  public var errorDescription: String? { message }
}

/// A MongoDB client speaking OP_MSG to a single server (or the primary it's pointed at).
public actor MongoClient {
  public struct Config: Sendable {
    public var host: String
    public var port: Int
    public var user: String?
    public var password: String?
    public var authSource: String
    public var database: String?
    public var tls: TLSSettings
    public var applicationName: String
    public var connectTimeout: TimeInterval
    /// How to reach the server: TCP from this device, or a channel of an SSH connection.
    public var dialer: WireDialer

    public init(
      host: String = "127.0.0.1", port: Int = 27017, user: String? = nil, password: String? = nil,
      authSource: String = "admin", database: String? = nil, tls: TLSSettings = .off,
      applicationName: String = "Database", connectTimeout: TimeInterval = 15,
      dialer: WireDialer = .direct
    ) {
      self.host = host
      self.port = port
      self.user = user
      self.password = password
      self.authSource = authSource
      self.database = database
      self.tls = tls
      self.applicationName = applicationName
      self.connectTimeout = connectTimeout
      self.dialer = dialer
    }
  }

  public let config: Config
  private let wire: WireConnection
  private let exchange = AsyncMutex()
  private var requestID: Int32 = 0
  public private(set) var hello = BSONDocument()

  private init(config: Config, wire: WireConnection) {
    self.config = config
    self.wire = wire
  }

  public static func connect(_ config: Config) async throws -> MongoClient {
    let wire = try await config.dialer.connect(
      host: config.host, port: config.port, tls: config.tls, timeout: config.connectTimeout)
    let client = MongoClient(config: config, wire: wire)
    do {
      try await client.handshake()
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

  public var serverVersion: String? { hello["version"]?.stringValue }
  public var maxWireVersion: Int { hello["maxWireVersion"]?.intValue ?? 0 }
  public var isWritablePrimary: Bool { hello["isWritablePrimary"]?.boolValue ?? hello["ismaster"]?.boolValue ?? true }
  public var replicaSetName: String? { hello["setName"]?.stringValue }

  // MARK: - OP_MSG

  /// Runs a command against `database` and returns the reply, throwing when `ok` is 0.
  @discardableResult
  public func command(_ command: BSONDocument, database: String) async throws -> BSONDocument {
    try await exchange.run { try await self.runCommand(command, database: database) }
  }

  private func runCommand(_ command: BSONDocument, database: String) async throws -> BSONDocument {
    var body = command
    body["$db"] = .string(database)
    requestID &+= 1
    var message: [UInt8] = []
    func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { message.append(contentsOf: $0) } }
    le(Int32(0))  // length, patched
    le(requestID)
    le(Int32(0))
    le(Int32(2013))  // OP_MSG
    le(UInt32(0))  // flags
    message.append(0)  // section kind 0: body
    message.append(contentsOf: body.encoded())
    let length = Int32(message.count).littleEndian
    withUnsafeBytes(of: length) { raw in for i in 0..<4 { message[i] = raw[i] } }
    try await wire.send(message)

    let reply = try await readReply()
    if let ok = reply["ok"]?.doubleValue, ok != 1 {
      throw MongoError(
        code: reply["code"]?.intValue, codeName: reply["codeName"]?.stringValue,
        message: reply["errmsg"]?.stringValue ?? "Command failed")
    }
    if let writeErrors = reply["writeErrors"]?.arrayValue, let first = writeErrors.first?.documentValue {
      throw MongoError(
        code: first["code"]?.intValue, codeName: nil, message: first["errmsg"]?.stringValue ?? "Write failed")
    }
    if let concern = reply["writeConcernError"]?.documentValue {
      throw MongoError(
        code: concern["code"]?.intValue, codeName: nil, message: concern["errmsg"]?.stringValue ?? "Write concern failed")
    }
    return reply
  }

  private func readReply() async throws -> BSONDocument {
    let header = try await wire.read(exactly: 16)
    var r = ByteReader(header)
    let length = Int(try r.readLE(Int32.self))
    _ = try r.readLE(Int32.self)
    _ = try r.readLE(Int32.self)
    let opcode = try r.readLE(Int32.self)
    let body = try await wire.read(exactly: length - 16)
    guard opcode == 2013 else { throw WireError.protocolViolation("unexpected MongoDB opcode \(opcode)") }
    var br = ByteReader(body)
    let flags = try br.readLE(UInt32.self)
    var end = body.count
    if flags & 1 != 0 { end -= 4 }  // checksum
    var result: BSONDocument?
    while br.offset < end {
      let kind = try br.readByte()
      if kind == 0 {
        var peek = ByteReader(body, offset: br.offset)
        let docLength = Int(try peek.readLE(Int32.self))
        result = try BSONDocument(bytes: try br.readBytes(docLength))
      } else {
        let sectionLength = Int(try br.readLE(Int32.self))
        try br.skip(sectionLength - 4)
      }
    }
    guard let result else { throw WireError.protocolViolation("empty MongoDB reply") }
    return result
  }

  // MARK: - Handshake and authentication

  private func handshake() async throws {
    var cmd: BSONDocument = [
      "hello": .int32(1), "helloOk": .bool(true),
      "client": .document([
        "driver": .document(["name": .string("Database"), "version": .string("1.0")]),
        "os": .document(["type": .string("Darwin")]),
        "application": .document(["name": .string(config.applicationName)]),
      ]),
    ]
    if let user = config.user, !user.isEmpty {
      cmd["saslSupportedMechs"] = .string("\(config.authSource).\(user)")
    }
    hello = try await command(cmd, database: "admin")
    guard let user = config.user, !user.isEmpty else { return }
    let mechanisms = hello["saslSupportedMechs"]?.arrayValue?.compactMap(\.stringValue) ?? ["SCRAM-SHA-256"]
    let useSHA256 = mechanisms.contains("SCRAM-SHA-256") || !mechanisms.contains("SCRAM-SHA-1")
    try await authenticate(user: user, password: config.password ?? "", sha256: useSHA256)
  }

  private func authenticate(user: String, password: String, sha256: Bool) async throws {
    let secret = sha256 ? password : Digest.md5Hex(Array("\(user):mongo:\(password)".utf8))
    var scram = SCRAMClient(hash: sha256 ? .sha256 : .sha1, username: user, password: secret)
    let first = scram.clientFirstMessage()
    let mechanism = sha256 ? "SCRAM-SHA-256" : "SCRAM-SHA-1"
    var reply: BSONDocument
    do {
      reply = try await command(
        [
          "saslStart": .int32(1), "mechanism": .string(mechanism),
          "payload": .binary(subtype: 0, data: Array(first.utf8)), "autoAuthorize": .int32(1),
          "options": .document(["skipEmptyExchange": .bool(true)]),
        ], database: config.authSource)
    } catch let error as MongoError {
      throw WireError.authenticationFailed(error.message)
    }
    guard case .binary(_, let serverFirstBytes)? = reply["payload"], let conversation = reply["conversationId"] else {
      throw WireError.protocolViolation("bad saslStart reply")
    }
    let final = try scram.clientFinalMessage(serverFirst: String(decoding: serverFirstBytes, as: UTF8.self))
    do {
      reply = try await command(
        [
          "saslContinue": .int32(1), "conversationId": conversation,
          "payload": .binary(subtype: 0, data: Array(final.utf8)),
        ], database: config.authSource)
    } catch let error as MongoError {
      throw WireError.authenticationFailed(error.message)
    }
    if case .binary(_, let serverFinal)? = reply["payload"] {
      try scram.verify(serverFinal: String(decoding: serverFinal, as: UTF8.self))
    }
    var done = reply["done"]?.boolValue ?? false
    while !done {
      reply = try await command(
        ["saslContinue": .int32(1), "conversationId": conversation, "payload": .binary(subtype: 0, data: [])],
        database: config.authSource)
      done = reply["done"]?.boolValue ?? true
    }
  }

  // MARK: - Cursors

  /// Collects a cursor's batches until `limit` documents or the cursor is exhausted (then kills it).
  public func drain(cursorReply reply: BSONDocument, database: String, limit: Int) async throws -> [BSONDocument] {
    guard let cursor = reply["cursor"]?.documentValue else { return [] }
    var documents = (cursor["firstBatch"]?.arrayValue ?? []).compactMap(\.documentValue)
    var cursorID = cursor["id"] ?? .int64(0)
    let namespace = cursor["ns"]?.stringValue ?? ""
    let collection = String(namespace.split(separator: ".", maxSplits: 1).last ?? "")
    while documents.count < limit, cursorID.intValue != 0 {
      let more = try await command(
        ["getMore": cursorID, "collection": .string(collection), "batchSize": .int32(Int32(min(limit - documents.count, 1000)))],
        database: database)
      let next = more["cursor"]?.documentValue
      documents += (next?["nextBatch"]?.arrayValue ?? []).compactMap(\.documentValue)
      cursorID = next?["id"] ?? .int64(0)
    }
    if cursorID.intValue != 0 {
      _ = try? await command(["killCursors": .string(collection), "cursors": .array([cursorID])], database: database)
    }
    return Array(documents.prefix(limit))
  }

  // MARK: - Convenience commands

  public func listDatabases() async throws -> [(name: String, sizeOnDisk: Int64)] {
    let reply = try await command(["listDatabases": .int32(1)], database: "admin")
    return (reply["databases"]?.arrayValue ?? []).compactMap { item in
      guard let doc = item.documentValue, let name = doc["name"]?.stringValue else { return nil }
      return (name, Int64(doc["sizeOnDisk"]?.doubleValue ?? 0))
    }
  }

  public struct CollectionInfo: Sendable, Hashable {
    public var name: String
    public var type: String
  }

  public func listCollections(database: String) async throws -> [CollectionInfo] {
    let reply = try await command(
      ["listCollections": .int32(1), "nameOnly": .bool(true), "authorizedCollections": .bool(true)], database: database)
    return try await drain(cursorReply: reply, database: database, limit: 100_000).compactMap { doc in
      guard let name = doc["name"]?.stringValue else { return nil }
      return CollectionInfo(name: name, type: doc["type"]?.stringValue ?? "collection")
    }
  }

  public func find(
    database: String, collection: String, filter: BSONDocument = [:], sort: BSONDocument? = nil,
    projection: BSONDocument? = nil, skip: Int = 0, limit: Int = 50
  ) async throws -> [BSONDocument] {
    var cmd: BSONDocument = ["find": .string(collection), "filter": .document(filter)]
    if let sort, !sort.isEmpty { cmd["sort"] = .document(sort) }
    if let projection, !projection.isEmpty { cmd["projection"] = .document(projection) }
    if skip > 0 { cmd["skip"] = .int64(Int64(skip)) }
    cmd["limit"] = .int64(Int64(limit))
    cmd["batchSize"] = .int32(Int32(min(limit, 1000)))
    let reply = try await command(cmd, database: database)
    return try await drain(cursorReply: reply, database: database, limit: limit)
  }

  public func aggregate(
    database: String, collection: String, pipeline: [BSONDocument], limit: Int = 1000, allowDiskUse: Bool = false,
    options: BSONDocument = [:]
  ) async throws -> [BSONDocument] {
    var cmd: BSONDocument = [
      "aggregate": .string(collection), "pipeline": .array(pipeline.map(BSON.document)),
      "cursor": .document(["batchSize": .int32(Int32(min(limit, 1000)))]),
    ]
    if allowDiskUse { cmd["allowDiskUse"] = .bool(true) }
    for (key, value) in options { cmd[key] = value }
    let reply = try await command(cmd, database: database)
    return try await drain(cursorReply: reply, database: database, limit: limit)
  }

  public func count(database: String, collection: String, filter: BSONDocument = [:]) async throws -> Int {
    let result = try await aggregate(
      database: database, collection: collection,
      pipeline: [["$match": .document(filter)], ["$count": .string("n")]], limit: 1)
    return result.first?["n"]?.intValue ?? 0
  }

  /// The fast estimate from collection metadata (no filter).
  public func estimatedCount(database: String, collection: String) async throws -> Int {
    let reply = try await command(["count": .string(collection)], database: database)
    return reply["n"]?.intValue ?? 0
  }

  @discardableResult
  public func insert(database: String, collection: String, documents: [BSONDocument]) async throws -> Int {
    let reply = try await command(
      ["insert": .string(collection), "documents": .array(documents.map(BSON.document)), "ordered": .bool(true)],
      database: database)
    return reply["n"]?.intValue ?? 0
  }

  /// Returns (matched, modified).
  @discardableResult
  public func update(
    database: String, collection: String, filter: BSONDocument, update: BSONDocument, many: Bool = false,
    upsert: Bool = false
  ) async throws -> (Int, Int) {
    let statement: BSONDocument = [
      "q": .document(filter), "u": .document(update), "multi": .bool(many), "upsert": .bool(upsert),
    ]
    let reply = try await command(
      ["update": .string(collection), "updates": .array([.document(statement)])], database: database)
    return (reply["n"]?.intValue ?? 0, reply["nModified"]?.intValue ?? 0)
  }

  @discardableResult
  public func delete(database: String, collection: String, filter: BSONDocument, many: Bool = false) async throws
    -> Int
  {
    let statement: BSONDocument = ["q": .document(filter), "limit": .int32(many ? 0 : 1)]
    let reply = try await command(
      ["delete": .string(collection), "deletes": .array([.document(statement)])], database: database)
    return reply["n"]?.intValue ?? 0
  }

  public func explain(database: String, command inner: BSONDocument, verbosity: String = "queryPlanner") async throws
    -> BSONDocument
  {
    try await command(["explain": .document(inner), "verbosity": .string(verbosity)], database: database)
  }

  public func listIndexes(database: String, collection: String) async throws -> [BSONDocument] {
    let reply = try await command(["listIndexes": .string(collection)], database: database)
    return try await drain(cursorReply: reply, database: database, limit: 10_000)
  }

  public func dropCollection(database: String, collection: String) async throws {
    try await command(["drop": .string(collection)], database: database)
  }

  /// Runs `{ ping: 1 }`.
  public func ping() async throws {
    try await command(["ping": .int32(1)], database: "admin")
  }
}
