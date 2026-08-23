import Foundation
import MongoDB
import PostgreSQL
import Redis
import SwiftData

/// Which database engine a connection talks to. Raw-value enum persisted in
/// ConnectionRecord; new engines join CaseIterable + the switches in
/// DatabaseModel/ConnectionFormView.
enum DatabaseEngine: String, Codable, CaseIterable, Identifiable {
  case mongodb
  case postgresql
  case redis

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .mongodb: "MongoDB"
    case .postgresql: "PostgreSQL"
    case .redis: "Redis"
    }
  }

  /// Default TCP port, used to prefill the form when the engine changes.
  var defaultPort: UInt16 {
    switch self {
    case .mongodb: 27017
    case .postgresql: 5432
    case .redis: 6379
    }
  }

  /// System image used in sidebar rows and pickers.
  var systemImage: String {
    switch self {
    case .mongodb: "leaf.fill"
    case .postgresql: "elephant"  // falls back gracefully if unavailable
    case .redis: "bolt.horizontal.fill"
    }
  }
}

/// Engine-tagged connection settings produced by the save form / saved
/// records and consumed by DatabaseModel.connect(_:). One associated value
/// per engine keeps every engine's config shape intact.
enum EngineSettings {
  case mongodb(ConnectionConfig)
  case postgresql(PostgresConnectionConfig)
  case redis(RedisConnectionConfig)

  var engine: DatabaseEngine {
    switch self {
    case .mongodb: .mongodb
    case .postgresql: .postgresql
    case .redis: .redis
    }
  }

  var name: String {
    switch self {
    case .mongodb(let c): c.name
    case .postgresql(let c): c.name
    case .redis(let c): c.name
    }
  }

  var host: String {
    switch self {
    case .mongodb(let c): c.host
    case .postgresql(let c): c.host
    case .redis(let c): c.host
    }
  }

  var port: UInt16 {
    switch self {
    case .mongodb(let c): c.port
    case .postgresql(let c): c.port
    case .redis(let c): c.port
    }
  }
}

/// A saved connection, persisted with SwiftData. Password is stored in plain
/// text for now; Keychain integration is a noted future step.
@Model final class ConnectionRecord {
  var name: String
  var host: String
  var port: Int
  // Lightweight-migration note: new stored properties MUST carry defaults.
  var engine: String = DatabaseEngine.mongodb.rawValue
  var username: String?
  var password: String?
  var authSource: String?
  var defaultDatabase: String?
  var directConnection: Bool = false

  init(
    name: String, host: String, port: Int, username: String? = nil, password: String? = nil,
    authSource: String? = nil, defaultDatabase: String? = nil, directConnection: Bool = false,
    engine: DatabaseEngine = .mongodb
  ) {
    self.name = name
    self.host = host
    self.port = port
    self.username = username
    self.password = password
    self.authSource = authSource
    self.defaultDatabase = defaultDatabase
    self.directConnection = directConnection
    self.engine = engine.rawValue
  }

  var engineKind: DatabaseEngine {
    get { DatabaseEngine(rawValue: engine) ?? .mongodb }
    set { engine = newValue.rawValue }
  }

  /// Maps the persisted record to engine-tagged connection settings.
  func toSettings() -> EngineSettings {
    switch engineKind {
    case .mongodb:
      return .mongodb(
        ConnectionConfig(
          name: name, host: host, port: UInt16(port), username: username, password: password,
          authSource: authSource, defaultDatabase: defaultDatabase,
          directConnection: directConnection))
    case .postgresql:
      return .postgresql(
        PostgresConnectionConfig(
          name: name, host: host, port: UInt16(port), username: username, password: password,
          defaultDatabase: defaultDatabase))
    case .redis:
      let index = defaultDatabase.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
      return .redis(
        RedisConnectionConfig(
          name: name, host: host, port: UInt16(port), username: username, password: password,
          databaseIndex: index))
    }
  }

  /// Legacy shim for call sites that still want the MongoDB config.
  func toConfig() -> ConnectionConfig {
    switch toSettings() {
    case .mongodb(let c): return c
    default:
      return ConnectionConfig(name: name, host: host, port: UInt16(port))
    }
  }
}
