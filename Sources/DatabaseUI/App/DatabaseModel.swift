import CryptoKit
import DatabaseKit
import Foundation
import Observation
import SSHTunnel
import SwiftUI
import VaultKit

/// A query kept for later, per connection.
struct SavedQuery: Codable, Hashable, Identifiable {
  var id = UUID()
  var profileID: UUID
  var title: String
  var text: String
  var database: String?
  var schema: String?
}

/// Everything the app keeps: saved connections, SSH keys, saved queries, and the live connections. Shell keeps one
/// too, for its sidebar's database connections, and carries their SSH tunnels itself (`opener`).
///
/// Saved connections are the ones the v57 apps share (`SharedConnections`, through the vault): Database
/// and Shell list them, an SSH server is one of Shell's saved hosts, accepted host keys are trusted by
/// every app, and changes from the other apps and devices appear as they happen.
@Observable @MainActor
public final class DatabaseModel {
  public private(set) var profiles: [ConnectionProfile] = []
  private(set) var savedQueries: [SavedQuery] = []
  public private(set) var live: [UUID: LiveConnection] = [:]
  let secrets: SecretStore
  let keys: SSHKeyStore
  /// The shared store of the window's account: connections and SSH hosts.
  public let vault: Vault
  /// Where accepted SSH host keys are kept: Personal's vault, so a server trusted in one account is trusted in every
  /// account on the device (a host key belongs to the server, not to who works on it).
  public let hostKeys: Vault
  /// How a connection opens, when the app opens them itself (Shell logs in to SSH on its own connections); nil uses
  /// DatabaseKit's `Connector`.
  @ObservationIgnored public var opener: DatabaseOpener?
  /// Called after a connection closed (Disconnect, a changed or deleted connection), for apps that show it open.
  @ObservationIgnored public var onDisconnect: ((UUID) -> Void)?
  /// The vault id of each profile (a UUID string, except for records another app made).
  @ObservationIgnored private var vaultIDs: [UUID: String] = [:]
  @ObservationIgnored private var observer: VaultChangeObserver?
  /// The optional DuckDB library: downloaded on request, next to the app's data.
  let duckDB: DuckDBInstaller
  private let folder: URL?
  /// Bumped when SSH keys change, so views listing them refresh.
  var keysVersion = 0
  /// The models of the other accounts' vaults (`model(for:)`), on Personal's model.
  @ObservationIgnored private var accountModels: [String: DatabaseModel] = [:]

  public convenience init(folder: URL?, secrets: SecretStore, vault: Vault) {
    self.init(folder: folder, secrets: secrets, vault: vault, hostKeys: vault, keys: nil)
  }

  private init(folder: URL?, secrets: SecretStore, vault: Vault, hostKeys: Vault, keys: SSHKeyStore?) {
    self.folder = folder
    self.secrets = secrets
    self.vault = vault
    self.hostKeys = hostKeys
    self.keys = keys ?? SSHKeyStore(secrets: secrets, listURL: folder?.appendingPathComponent("ssh-keys.json"))
    if let folder { DuckDBLibrary.directory = folder.appendingPathComponent("DuckDB", isDirectory: true) }
    duckDB = DuckDBInstaller()
    load()
    observer = VaultChangeObserver { [weak self] in
      Task { @MainActor in
        self?.vault.reload()
        self?.reloadProfiles()
      }
    }
  }

  /// The model of an app that keeps its connections in the shared vault, its passwords in the shared keychain group
  /// and its saved queries (and DuckDB) in `folder`.
  public convenience init(folder: URL?, vault: Vault) {
    self.init(folder: folder, secrets: VaultSecretStore(), vault: vault)
  }

  public static func live() -> DatabaseModel {
    #if DEBUG
      // Development runs can point at a scratch folder and keep secrets in a file there,
      // so testing never touches the real connections or the Keychain.
      if let path = LaunchOptions.value("--data-dir") {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let secrets = FileSecretStore(url: folder.appendingPathComponent("secrets-dev.json"))
        return DatabaseModel(folder: folder, secrets: secrets, vault: scratchVault(in: folder, secrets: secrets))
      }
    #endif
    let folder = URL.applicationSupportDirectory.appendingPathComponent("dev.v57.db", isDirectory: true)
    let vault = Vault.shared
    vault.startSync()
    return DatabaseModel(folder: folder, secrets: VaultSecretStore(), vault: vault)
  }

  /// The model of a window's account (`VaultAccountScope`'s vault): this model for its own vault, else one per
  /// account, kept so every window of an account shares its live connections. An account's model shares this one's
  /// folder, secrets, imported SSH keys and host keys (device-wide), and keeps its saved queries in a file of its own.
  /// An app with hooks (`opener`, `onDisconnect`) sets them on each model.
  public func model(for vault: Vault) -> DatabaseModel {
    if vault === self.vault || vault.accountID == self.vault.accountID { return self }
    if let model = accountModels[vault.accountID], model.vault === vault { return model }
    let model = DatabaseModel(folder: folder, secrets: secrets, vault: vault, hostKeys: hostKeys, keys: keys)
    accountModels[vault.accountID] = model
    return model
  }

  #if DEBUG
    /// A vault of its own for `--data-dir` runs, with its key in the scratch secrets file.
    private static func scratchVault(in folder: URL, secrets: SecretStore) -> Vault {
      let keyData = secrets.read("vault-key") ?? {
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try? secrets.write("vault-key", data)
        return data
      }()
      let store = try? VaultStore(
        directory: folder.appendingPathComponent("Vault", isDirectory: true),
        keys: MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(data: keyData)]), deviceID: "scratch",
        notifier: nil, owner: "scratch")
      return Vault(store: store)
    }
  #endif

  // MARK: Persistence

  private var profilesURL: URL? { folder?.appendingPathComponent("connections.json") }
  private var queriesURL: URL? {
    folder?.appendingPathComponent(vault.isPersonal ? "saved-queries.json" : "saved-queries.\(vault.accountID).json")
  }

  private func load() {
    reloadProfiles()
    importLegacyConnections()
    if let url = queriesURL, let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode([SavedQuery].self, from: data)
    {
      savedQueries = decoded
    }
  }

  private func persist() {
    guard let folder else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let url = queriesURL, let data = try? encoder.encode(savedQueries) { try? data.write(to: url, options: .atomic) }
  }

  /// The profiles of the shared connections, in their sidebar order.
  private func reloadProfiles() {
    let store = hostKeys.store
    var ids: [UUID: String] = [:]
    profiles = vault.databases.compactMap { record in
      let profile = SharedConnections.profile(from: record, hosts: vault.hosts) { host, port in
        try? store?.knownFingerprint(host: host, port: port)
      }
      if let profile { ids[profile.id] = record.id }
      return profile
    }
    vaultIDs = ids
  }

  public func vaultID(for id: UUID) -> String { vaultIDs[id] ?? id.uuidString }

  /// The shared host a profile tunnels through.
  public func hostID(for id: UUID) -> String? {
    vault.databases.first { $0.id == vaultID(for: id) }?.sshHostID
  }

  /// Connections saved by builds before the vault (connections.json and the app's own Keychain items)
  /// are copied into it once. The file stays, for those builds.
  private func importLegacyConnections() {
    guard vault.isPersonal else { return }
    #if DEBUG
      // A `--data-dir` run (Scripts/seed-demo.py) adds its folder's connections.json with the passwords from its
      // secrets file, every launch, and leaves the real Keychain and the once-only flag alone.
      if LaunchOptions.value("--data-dir") != nil {
        guard let url = profilesURL, let data = try? Data(contentsOf: url),
          let seeded = try? JSONDecoder().decode([ConnectionProfile].self, from: data)
        else { return }
        for profile in seeded where !profiles.contains(where: { $0.id == profile.id }) {
          save(profile, password: secrets.databasePassword(for: profile.id), sshPassword: secrets.sshPassword(for: profile.id))
        }
        return
      }
    #endif
    let imported = "ImportedLegacyConnections"
    guard !UserDefaults.standard.bool(forKey: imported), let url = profilesURL, let data = try? Data(contentsOf: url),
      let legacy = try? JSONDecoder().decode([ConnectionProfile].self, from: data)
    else { return }
    UserDefaults.standard.set(true, forKey: imported)
    let old = KeychainStore()
    for profile in legacy where !profiles.contains(where: { $0.id == profile.id }) {
      save(profile, password: old.databasePassword(for: profile.id), sshPassword: old.sshPassword(for: profile.id))
    }
  }

  // MARK: Connections

  public func profile(_ id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }

  /// Adds or replaces a profile in the shared store; passwords go to the shared Keychain group (or are
  /// forgotten). An SSH server becomes (or updates) a shared host.
  public func save(_ profile: ConnectionProfile, password: String?, sshPassword: String?) {
    var hostID: String?
    if profile.ssh.enabled, !profile.ssh.host.isEmpty, !profile.engine.isFileBased {
      let host = SharedConnections.host(for: profile.ssh, among: vault.hosts)
      vault.save(host)
      hostID = host.id
      if let fingerprint = profile.ssh.hostKeyFingerprint {
        hostKeys.perform { try $0.trust(fingerprint: fingerprint, host: host.hostname, port: host.port) }
      }
    }
    let id = vaultID(for: profile.id)
    let existing = vault.databases.first { $0.id == id }
    var record = SharedConnections.record(from: profile, id: id, hostID: hostID, existing: existing)
    if existing == nil { record.order = (vault.databases.map(\.order).max() ?? -1) + 1 }
    vault.save(record)
    vaultIDs[profile.id] = id
    if profile.savePassword {
      try? secrets.setString("db.\(id)", password?.isEmpty == false ? password : nil)
      if let hostID, profile.ssh.auth == .password {
        try? secrets.setHostPassword(sshPassword?.isEmpty == false ? sshPassword : nil, for: hostID)
      }
    } else {
      try? secrets.setString("db.\(id)", nil)
    }
    reloadProfiles()
    // A changed profile reconnects with its new settings, keeping its query tabs.
    if let connection = live[profile.id], let saved = self.profile(profile.id), connection.profile != saved {
      if connection.status == .idle { connection.profile = saved } else { Task { await connection.reconnect() } }
    }
  }

  public func delete(_ id: UUID) {
    Task { await disconnect(id) }
    let vaultID = vaultID(for: id)
    vault.perform { try $0.delete(id: vaultID) }
    savedQueries.removeAll { $0.profileID == id }
    try? secrets.setString("db.\(vaultID)", nil)
    persist()
    reloadProfiles()
  }

  /// Renames a connection in the shared store (an empty name falls back to the engine and server). An open
  /// connection keeps its session and takes the new name.
  public func rename(_ id: UUID, to name: String) {
    guard var record = vault.databases.first(where: { $0.id == vaultID(for: id) }) else { return }
    record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    vault.save(record)
    reloadProfiles()
    if let connection = live[id], let renamed = profile(id) { connection.profile.name = renamed.name }
  }

  public func duplicate(_ id: UUID) {
    guard var copy = profile(id) else { return }
    let password = databasePassword(for: id)
    let sshPassword = sshPassword(for: id)
    copy.id = UUID()
    copy.name = copy.displayName + " Copy"
    copy.lastUsed = nil
    save(copy, password: password, sshPassword: sshPassword)
  }

  public func move(from source: IndexSet, to destination: Int) {
    var ordered = profiles
    ordered.move(fromOffsets: source, toOffset: destination)
    vault.perform { store in
      for (index, profile) in ordered.enumerated() {
        guard var record = vault.databases.first(where: { $0.id == vaultID(for: profile.id) }), record.order != index
        else { continue }
        record.order = index
        try store.save(record)
      }
    }
    reloadProfiles()
  }

  /// Remembers an SSH host key after the first successful login, for every v57 app.
  func rememberHostKey(_ fingerprint: String?, for id: UUID) {
    guard let fingerprint, let profile = profile(id), profile.ssh.enabled,
      profile.ssh.hostKeyFingerprint != fingerprint
    else { return }
    hostKeys.perform { try $0.trust(fingerprint: fingerprint, host: profile.ssh.host, port: profile.ssh.port) }
    reloadProfiles()
  }

  public func databasePassword(for id: UUID) -> String? { secrets.string("db.\(vaultID(for: id))") }

  /// The SSH password saved for the profile's host.
  public func sshPassword(for id: UUID) -> String? { hostID(for: id).flatMap { secrets.hostPassword(for: $0) } }

  public func credentials(for profile: ConnectionProfile, password: String? = nil, sshPassword: String? = nil) -> Credentials {
    // A key login with no imported key uses this device's Secure Enclave key, the one every v57 app shares.
    let key: SSHKey? =
      profile.ssh.auth == .key
      ? (profile.ssh.keyID.flatMap { keys.key($0) } ?? (try? SharedConnections.deviceKey())) : nil
    return Credentials(
      password: password ?? databasePassword(for: profile.id),
      sshPassword: sshPassword ?? self.sshPassword(for: profile.id),
      sshKey: key)
  }

  // MARK: Live connections

  public func connection(for id: UUID) -> LiveConnection {
    if let existing = live[id] { return existing }
    let connection = LiveConnection(profile: profile(id) ?? ConnectionProfile(engine: .postgres), app: self)
    live[id] = connection
    return connection
  }

  public func disconnect(_ id: UUID) async {
    guard let connection = live[id] else { return }
    live[id] = nil
    await connection.close()
    onDisconnect?(id)
  }

  /// Closes every connection, so the next use starts from scratch: its tree, tables and query tabs.
  public func disconnectAll() async {
    for id in live.keys { await disconnect(id) }
  }

  func markUsed(_ id: UUID) {
    guard var record = vault.databases.first(where: { $0.id == vaultID(for: id) }) else { return }
    record.lastUsed = Date()
    vault.save(record)
    reloadProfiles()
  }

  /// Opens a session for a profile: through `opener` when the app has one, else DatabaseKit's `Connector`.
  func open(_ profile: ConnectionProfile, credentials: Credentials, tunnelClosed: @escaping @MainActor (String?) -> Void)
    async throws -> OpenedSession
  {
    if let opener { return try await opener(profile, credentials, tunnelClosed) }
    let (session, report) = try await Connector.connect(profile, credentials: credentials)
    session.onTunnelClosed { reason in Task { @MainActor in tunnelClosed(reason) } }
    return OpenedSession(session: session, report: report)
  }

  /// Tries a profile without saving it.
  func test(_ profile: ConnectionProfile, password: String?, sshPassword: String?) async throws -> ConnectionReport {
    let opened = try await open(
      profile, credentials: credentials(for: profile, password: password, sshPassword: sshPassword), tunnelClosed: { _ in })
    await opened.close()
    return opened.report
  }

  // MARK: Saved queries

  func queries(for profileID: UUID) -> [SavedQuery] { savedQueries.filter { $0.profileID == profileID } }

  func saveQuery(_ query: SavedQuery) {
    if let index = savedQueries.firstIndex(where: { $0.id == query.id }) {
      savedQueries[index] = query
    } else {
      savedQueries.append(query)
    }
    persist()
  }

  func deleteQuery(_ id: UUID) {
    savedQueries.removeAll { $0.id == id }
    persist()
  }

  /// Opens a database file dropped on the app or picked in the Finder.
  @discardableResult
  public func addFile(_ url: URL) -> ConnectionProfile? {
    let ext = url.pathExtension.lowercased()
    guard let engine = EngineKind.available.first(where: { $0.fileExtensions.contains(ext) }) else { return nil }
    if let existing = profiles.first(where: { $0.filePath == url.path }) { return existing }
    let profile = ConnectionProfile(name: url.deletingPathExtension().lastPathComponent, engine: engine, filePath: url.path)
    save(profile, password: nil, sshPassword: nil)
    return profile
  }
}

/// Opens a connection's session for an app that opens them itself (`DatabaseModel.opener`): Shell logs in to the SSH
/// server on its own connection and hands DatabaseKit a dialer for its channels. It calls `tunnelClosed` when that
/// SSH connection drops.
public typealias DatabaseOpener = @MainActor (
  _ profile: ConnectionProfile, _ credentials: Credentials, _ tunnelClosed: @escaping @MainActor (String?) -> Void
) async throws -> OpenedSession

/// A live session and what else to close with it (the app's own SSH connection).
public struct OpenedSession {
  public var session: any DatabaseSession
  public var report: ConnectionReport
  public var onClose: (@MainActor () -> Void)?

  public init(session: any DatabaseSession, report: ConnectionReport, onClose: (@MainActor () -> Void)? = nil) {
    self.session = session
    self.report = report
    self.onClose = onClose
  }

  func close() async {
    await session.close()
    onClose?()
  }
}

/// Command-line options for development runs.
public enum LaunchOptions {
  /// The launch's arguments, or the screenshot scene's that opened in this launch since.
  nonisolated(unsafe) public static var arguments = ProcessInfo.processInfo.arguments

  public static func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  public static func flag(_ name: String) -> Bool { arguments.contains(name) }
}

#if DEBUG
  /// Secrets in a plain JSON file: development runs only.
  final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    private func load() -> [String: String] {
      guard let data = try? Data(contentsOf: url) else { return [:] }
      return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func read(_ account: String) -> Data? {
      lock.withLock { load()[account].flatMap { Data(base64Encoded: $0) } }
    }

    func write(_ account: String, _ data: Data?) throws {
      try lock.withLock {
        var all = load()
        all[account] = data?.base64EncodedString()
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
      }
    }
  }
#endif
