import CQLWire
import DuckDBKit
import Foundation
import MongoWire
import MySQLWire
import PostgresWire
import RedisWire
import SQLiteKit
import SSHTunnel
import TDSWire
import WireKit

/// What a successful connection learned.
public struct ConnectionReport: Sendable {
  public var serverDescription: String
  public var elapsed: TimeInterval
  /// The SSH server's host key, to remember for next time.
  public var sshHostKeyFingerprint: String?
  public var sshHostKeyType: String?
}

/// Credentials for one connection attempt.
public struct Credentials: Sendable {
  public var password: String?
  public var sshPassword: String?
  public var sshKey: SSHKey?

  public init(password: String? = nil, sshPassword: String? = nil, sshKey: SSHKey? = nil) {
    self.password = password
    self.sshPassword = sshPassword
    self.sshKey = sshKey
  }
}

public enum Connector {
  /// Opens the SSH tunnel (if any), connects, and returns a live session.
  public static func connect(_ profile: ConnectionProfile, credentials: Credentials) async throws -> (
    DatabaseSession, ConnectionReport
  ) {
    let start = Date()
    var tunnel: SSHTunnel?
    var host = profile.host
    var port = profile.port
    if profile.ssh.enabled && !profile.engine.isFileBased {
      let server = SSHServer(
        host: profile.ssh.host, port: profile.ssh.port, user: profile.ssh.user,
        password: profile.ssh.auth == .password ? credentials.sshPassword : nil,
        key: profile.ssh.auth == .key ? credentials.sshKey : nil,
        knownFingerprint: profile.ssh.hostKeyFingerprint)
      let target = profile.host.isEmpty ? "127.0.0.1" : profile.host
      tunnel = try await SSHTunnel.open(server: server, targetHost: target, targetPort: profile.port)
      host = "127.0.0.1"
      port = tunnel!.localPort
    }
    do {
      let session = try await open(profile, host: host, port: port, credentials: credentials, tunnel: tunnel)
      let description = await session.serverDescription
      return (
        session,
        ConnectionReport(
          serverDescription: description, elapsed: Date().timeIntervalSince(start),
          sshHostKeyFingerprint: tunnel?.hostKeyFingerprint, sshHostKeyType: tunnel?.hostKeyType)
      )
    } catch {
      tunnel?.close()
      throw error
    }
  }

  static func tls(_ profile: ConnectionProfile) -> TLSSettings {
    // Through an SSH tunnel the TLS host name would be 127.0.0.1, so certificate checks can't pass.
    TLSSettings(enabled: profile.useTLS, allowUntrusted: profile.allowUntrustedCertificate || profile.ssh.enabled)
  }

  static func open(
    _ profile: ConnectionProfile, host: String, port: Int, credentials: Credentials, tunnel: SSHTunnel?
  ) async throws -> DatabaseSession {
    let password = credentials.password ?? ""
    switch profile.engine {
    case .postgres:
      let config = PostgresClient.Config(
        host: host, port: port, user: profile.user, password: password,
        database: profile.database.isEmpty ? "postgres" : profile.database, tls: tls(profile))
      let client = try await PostgresClient.connect(config)
      return SQLSession(
        profile: profile, dialect: PostgresDialect(), executor: PostgresExecutor(base: config, first: client),
        tunnel: tunnel)
    case .mysql, .mariadb:
      if profile.useTLS {
        throw WireError.unsupported(
          "\(profile.engine.displayName) encrypts after the connection starts, which Database does through an SSH tunnel. Turn on SSH, or turn off encryption.")
      }
      let client = try await MySQLClient.connect(
        .init(host: host, port: port, user: profile.user, password: password,
              database: profile.database.isEmpty ? nil : profile.database))
      // A server answering as MariaDB gets MariaDB's dialect, whatever was picked.
      let engine: EngineKind = await client.isMariaDB ? .mariadb : .mysql
      return SQLSession(
        profile: profile, dialect: MySQLDialect(engine: engine), executor: MySQLExecutor(client: client), tunnel: tunnel)
    case .sqlserver:
      let client = try await TDSClient.connect(
        .init(host: host, port: port, user: profile.user, password: password,
              database: profile.database.isEmpty ? nil : profile.database))
      return SQLSession(
        profile: profile, dialect: SQLServerDialect(), executor: TDSExecutor(client: client), tunnel: tunnel)
    case .sqlite:
      let file = try SQLiteFile(path: profile.filePath, readOnly: profile.isReadOnly, create: false)
      return SQLSession(profile: profile, dialect: SQLiteDialect(), executor: SQLiteExecutor(file: file), tunnel: nil)
    case .duckdb:
      let ext = (profile.filePath as NSString).pathExtension.lowercased()
      let isDatabaseFile = ["duckdb", "ddb", "db"].contains(ext)
      let file = try DuckDBFile(path: isDatabaseFile ? profile.filePath : nil, readOnly: profile.isReadOnly)
      return SQLSession(profile: profile, dialect: DuckDBDialect(), executor: DuckDBExecutor(file: file), tunnel: nil)
    case .mongodb:
      let client = try await MongoClient.connect(
        .init(host: host, port: port, user: profile.user.isEmpty ? nil : profile.user,
              password: password.isEmpty ? nil : password, authSource: profile.options["authSource"] ?? "admin",
              database: profile.database.isEmpty ? nil : profile.database, tls: tls(profile)))
      return MongoSession(profile: profile, client: client, tunnel: tunnel)
    case .redis:
      let client = try await RedisClient.connect(
        .init(host: host, port: port, username: profile.user.isEmpty ? nil : profile.user,
              password: password.isEmpty ? nil : password, database: Int(profile.database) ?? 0, tls: tls(profile)))
      return RedisSession(profile: profile, client: client, tunnel: tunnel)
    case .cassandra, .scylla:
      let client = try await CQLClient.connect(
        .init(host: host, port: port, user: profile.user.isEmpty ? nil : profile.user,
              password: password.isEmpty ? nil : password,
              keyspace: profile.database.isEmpty ? nil : profile.database, tls: tls(profile)))
      if let consistency = profile.options["consistency"], let level = CQLClient.Consistency.allCases.first(where: { $0.label == consistency }) {
        await client.setConsistency(level)
      }
      return CQLSession(profile: profile, client: client, tunnel: tunnel)
    }
  }
}

extension CQLClient {
  public func setConsistency(_ level: Consistency) { consistency = level }
}
