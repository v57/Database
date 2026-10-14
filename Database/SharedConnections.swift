import Foundation
import SSHTunnel
import SwiftData
import VaultKit

/// The connections the v57 apps share, through the vault (`../Vault`): Database Pro and Shell list the same
/// ones, and Shell's saved SSH hosts carry connections to servers you SSH into.
///
/// The sidebar keeps showing `ConnectionRecord`s; this keeps them and the shared `VaultDatabase`s the same
/// both ways, live. Engines Database doesn't have (MySQL, SQL Server, Cassandra…) stay in Database Pro, and
/// fields it doesn't know (a replica set) stay in the shared record.
@MainActor final class SharedConnections {
  static let shared = SharedConnections()

  let vault = Vault.shared
  private var observer: VaultChangeObserver?
  private var context: ModelContext?

  /// Starts following the shared connections (once, when the sidebar first appears).
  func start(context: ModelContext) {
    guard observer == nil else { return }
    self.context = context
    observer = VaultChangeObserver { [weak self] in
      Task { @MainActor in
        self?.vault.reload()
        self?.pull()
      }
    }
    pull()
  }

  // MARK: Engines

  static func vaultEngine(_ engine: DatabaseEngine) -> String {
    switch engine {
    case .mongodb: VaultDatabase.Engine.mongodb
    case .postgresql: VaultDatabase.Engine.postgres
    case .redis: VaultDatabase.Engine.redis
    case .sqlite: VaultDatabase.Engine.sqlite
    }
  }

  static func engine(_ name: String) -> DatabaseEngine? {
    switch name {
    case VaultDatabase.Engine.mongodb: .mongodb
    case VaultDatabase.Engine.postgres: .postgresql
    case VaultDatabase.Engine.redis: .redis
    case VaultDatabase.Engine.sqlite: .sqlite
    default: nil
    }
  }

  // MARK: Records ↔ shared

  /// Writes the shared connections into the sidebar's records: new ones are added, changed ones updated,
  /// removed ones deleted, and local records never shared yet are published.
  func pull() {
    guard let context, vault.store != nil else { return }
    let records = (try? context.fetch(FetchDescriptor<ConnectionRecord>())) ?? []
    // A store migrated from before the vault gave every record the same default id: give the copies their own.
    var seen = Set<String>()
    for record in records.sorted(by: { $0.isShared && !$1.isShared }) {
      if !seen.insert(record.vaultID).inserted {
        record.vaultID = UUID().uuidString
        record.isShared = false
        seen.insert(record.vaultID)
      }
    }
    for record in records where record.legacyPassword != nil {
      if record.password == nil { record.password = record.legacyPassword }
      record.legacyPassword = nil
    }
    var byID = Dictionary(records.map { ($0.vaultID, $0) }) { first, _ in first }
    var changed = false
    for shared in vault.databases {
      guard let engine = Self.engine(shared.engine) else { continue }
      if let record = byID.removeValue(forKey: shared.id) {
        changed = apply(shared, engine: engine, to: record) || changed
      } else {
        let record = ConnectionRecord(name: shared.name, host: "", port: shared.port, engine: engine)
        record.vaultID = shared.id
        record.isShared = true
        _ = apply(shared, engine: engine, to: record)
        context.insert(record)
        changed = true
      }
    }
    for record in byID.values {
      if record.isShared {
        // Removed in another app or on another device.
        context.delete(record)
        changed = true
      } else {
        publish(record)
      }
    }
    if changed { try? context.save() }
  }

  /// Publishes a record (after it was saved here).
  func publish(_ record: ConnectionRecord) {
    let existing = vault.databases.first { $0.id == record.vaultID }
    var shared = existing ?? VaultDatabase(id: record.vaultID, engine: Self.vaultEngine(record.engineKind), port: record.port)
    shared.name = record.name
    shared.engine = Self.vaultEngine(record.engineKind)
    if record.engineKind == .sqlite {
      shared.filePath = record.host
      shared.host = ""
    } else {
      shared.host = record.host
    }
    shared.port = record.port
    shared.user = record.username ?? ""
    shared.database = record.defaultDatabase ?? ""
    shared.options["authSource"] = record.authSource
    shared.options["directConnection"] = record.directConnection ? "true" : nil
    shared.sshHostID = record.sshHostID
    if existing == nil { shared.order = (vault.databases.map(\.order).max() ?? -1) + 1 }
    vault.save(shared)
    record.isShared = true
    try? context?.save()
  }

  /// Removes a record's shared connection (it was deleted here) and its password.
  func unpublish(_ record: ConnectionRecord) {
    let id = record.vaultID
    vault.perform { try $0.delete(id: id) }
    try? VaultSecrets.setPassword(nil, for: id)
  }

  /// Copies a shared connection's fields into a record; returns whether anything changed.
  private func apply(_ shared: VaultDatabase, engine: DatabaseEngine, to record: ConnectionRecord) -> Bool {
    var changed = false
    func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<ConnectionRecord, T>, _ value: T) {
      if record[keyPath: keyPath] != value {
        record[keyPath: keyPath] = value
        changed = true
      }
    }
    set(\.engine, engine.rawValue)
    set(\.name, shared.name)
    set(\.host, engine == .sqlite ? shared.filePath : shared.host)
    set(\.port, shared.port)
    set(\.username, shared.user.isEmpty ? nil : shared.user)
    set(\.defaultDatabase, shared.database.isEmpty ? nil : shared.database)
    set(\.authSource, shared.options["authSource"])
    set(\.directConnection, shared.options["directConnection"] == "true")
    set(\.sshHostID, shared.sshHostID)
    return changed
  }

  // MARK: SSH

  /// The shared record for a record (or a form's values): what `VaultDatabase` needs to pick a tunnel.
  func route(engine: DatabaseEngine, host: String, sshHostID: String?) -> (host: VaultHost, target: String)? {
    guard engine != .sqlite else { return nil }
    var probe = VaultDatabase(engine: Self.vaultEngine(engine), host: host, port: 0)
    probe.sshHostID = sshHostID
    guard let sshHost = probe.tunnelHost(in: vault.hosts) else { return nil }
    return (sshHost, probe.tunnelTarget(through: sshHost))
  }

  /// The SSH server for a shared host: this device's Secure Enclave key (shared by the v57 apps) or the
  /// host's saved password, and the host key every app trusts.
  func server(for host: VaultHost) throws -> SSHServer {
    let known = try? vault.store?.knownFingerprint(host: host.hostname, port: host.port)
    switch host.auth {
    case .deviceKey:
      return SSHServer(
        host: host.hostname, port: host.port, user: host.user, key: try Self.deviceKey(), knownFingerprint: known)
    case .password:
      guard let password = host.password else { throw TunnelError.noPassword(host.displayName) }
      return SSHServer(host: host.hostname, port: host.port, user: host.user, password: password, knownFingerprint: known)
    case .importedKey:
      throw TunnelError.importedKey(host.displayName)
    }
  }

  /// Trusts the host key a first login saw, for every v57 app.
  func trust(_ tunnel: SSHTunnel, host: VaultHost) {
    guard !tunnel.hostKeyFingerprint.isEmpty else { return }
    vault.perform {
      try $0.trust(fingerprint: tunnel.hostKeyFingerprint, host: host.hostname, port: host.port, keyType: tunnel.hostKeyType)
    }
  }

  static func deviceKey() throws -> SSHKey {
    let key = try VaultIdentity.key()
    return SSHKey(kind: .ecdsaP256, publicKeyBlob: Array(VaultIdentity.publicKeyBlob(key))) { data in
      Array(try VaultIdentity.sshSignature(Data(data), key: key))
    }
  }

  enum TunnelError: LocalizedError {
    case noPassword(String)
    case importedKey(String)

    var errorDescription: String? {
      switch self {
      case .noPassword(let host): "\(host) signs in with a password, and none is saved. Save it in Shell."
      case .importedKey(let host): "\(host) signs in with a key imported into Database Pro. Connect from there."
      }
    }
  }
}
