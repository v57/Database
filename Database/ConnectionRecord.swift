import Foundation
import MongoDB
import PostgreSQL
import Redis
import SQLite
import SwiftData

/// Which database engine a connection talks to. Raw-value enum persisted in
/// ConnectionRecord; new engines join CaseIterable + the switches in
/// DatabaseModel/ConnectionFormView.
enum DatabaseEngine: String, Codable, CaseIterable, Identifiable {
  case mongodb
  case postgresql
  case redis
  case sqlite

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .mongodb: "MongoDB"
    case .postgresql: "PostgreSQL"
    case .redis: "Redis"
    case .sqlite: "SQLite"
    }
  }

  /// Default TCP port, used to prefill the form when the engine changes.
  /// SQLite is file-based and has no port (the form hides the field).
  var defaultPort: UInt16 {
    switch self {
    case .mongodb: 27017
    case .postgresql: 5432
    case .redis: 6379
    case .sqlite: 0
    }
  }

  /// System image used in sidebar rows and pickers. Every name must be a
  /// real SF Symbol: a missing one renders as a blank gap, not a fallback.
  var systemImage: String {
    switch self {
    case .mongodb: "leaf.fill"
    case .postgresql: "server.rack"
    case .redis: "bolt.horizontal.fill"
    case .sqlite: "internaldrive"
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
  case sqlite(SQLiteConnectionConfig)

  var engine: DatabaseEngine {
    switch self {
    case .mongodb: .mongodb
    case .postgresql: .postgresql
    case .redis: .redis
    case .sqlite: .sqlite
    }
  }

  var name: String {
    switch self {
    case .mongodb(let c): c.name
    case .postgresql(let c): c.name
    case .redis(let c): c.name
    case .sqlite(let c): c.name
    }
  }

  /// Host for server engines; the FILE PATH for SQLite (the record
  /// reuses the host column as the path — a file database has no server).
  var host: String {
    switch self {
    case .mongodb(let c): c.host
    case .postgresql(let c): c.host
    case .redis(let c): c.host
    case .sqlite(let c): c.filePath
    }
  }

  var port: UInt16 {
    switch self {
    case .mongodb(let c): c.port
    case .postgresql(let c): c.port
    case .redis(let c): c.port
    case .sqlite: 0
    }
  }
}

/// Security-scoped file access, opened at most once per URL per launch (each
/// `startAccessingSecurityScopedResource` call must be balanced, so repeated
/// opens of the same file would otherwise pile up).
@MainActor enum FileAccess {
  private static var opened: Set<URL> = []

  static func open(_ url: URL) {
    guard !opened.contains(url), url.startAccessingSecurityScopedResource() else { return }
    opened.insert(url)
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
  /// iOS: security-scoped bookmark of a picked SQLite file. The picker's
  /// access grant only lasts for one launch; the bookmark re-opens it later.
  var fileBookmark: Data?

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
  @MainActor func toSettings() -> EngineSettings {
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
    case .sqlite: return .sqlite(SQLiteConnectionConfig(name: name, filePath: filePath))
    }
  }

  /// SQLite file path to open. With a bookmark (iOS picker), the bookmark is
  /// resolved and its security scope opened, so the file stays readable after
  /// a relaunch; the resolved path wins because the app container can move.
  @MainActor var filePath: String {
    guard let fileBookmark else { return host }
    var isStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: fileBookmark, bookmarkDataIsStale: &isStale)
    else { return host }
    FileAccess.open(url)
    return url.path
  }

  /// True when the live session in `model` was started from this record.
  /// Engine configs regenerate their UUID on every toSettings() call, so ids
  /// can't be compared — match by engine + name + host/port (file path for
  /// SQLite) instead. Shared by the sidebar (status dot) and the form (which
  /// must decide whether an edit needs a reconnect BEFORE mutating the record).
  @MainActor func matchesLiveSession(of model: DatabaseModel) -> Bool {
    guard model.isSessionActive, model.activeEngine == engineKind else { return false }
    switch model.activeEngine {
    case .mongodb:
      guard let session = model.session, session.isConnected else { return false }
      let c = session.config
      return c.name == name && c.host == host && c.port == UInt16(port)
    case .postgresql:
      guard case .postgresql(let session) = model.alternateSession, session.isConnected else {
        return false
      }
      let c = session.config
      return c.name == name && c.host == host && c.port == UInt16(port)
    case .redis:
      guard case .redis(let session) = model.alternateSession, session.isConnected else {
        return false
      }
      let c = session.config
      return c.name == name && c.host == host && c.port == UInt16(port)
    case .sqlite:
      guard case .sqlite(let session) = model.alternateSession, session.isConnected else {
        return false
      }
      let c = session.config
      return c.name == name && (c.filePath == host || c.filePath == filePath)
    case nil: return false
    }
  }

  /// Legacy shim for call sites that still want the MongoDB config.
  @MainActor func toConfig() -> ConnectionConfig {
    switch toSettings() {
    case .mongodb(let c): return c
    default: return ConnectionConfig(name: name, host: host, port: UInt16(port))
    }
  }
}
