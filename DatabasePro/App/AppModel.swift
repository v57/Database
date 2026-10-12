import DatabaseCore
import Foundation
import Observation
import SwiftUI

/// A query kept for later, per connection.
struct SavedQuery: Codable, Hashable, Identifiable {
  var id = UUID()
  var profileID: UUID
  var title: String
  var text: String
  var database: String?
  var schema: String?
}

/// Everything the app keeps: saved connections, SSH keys, saved queries, and the live connections.
@Observable @MainActor
final class AppModel {
  private(set) var profiles: [ConnectionProfile] = []
  private(set) var savedQueries: [SavedQuery] = []
  private(set) var live: [UUID: LiveConnection] = [:]
  let secrets: SecretStore
  let keys: SSHKeyStore
  private let folder: URL?
  /// Bumped when SSH keys change, so views listing them refresh.
  var keysVersion = 0

  init(folder: URL?, secrets: SecretStore) {
    self.folder = folder
    self.secrets = secrets
    keys = SSHKeyStore(secrets: secrets, listURL: folder?.appendingPathComponent("ssh-keys.json"))
    load()
  }

  static func live() -> AppModel {
    #if DEBUG
      // Development runs can point at a scratch folder and keep secrets in a file there,
      // so testing never touches the real connections or the Keychain.
      if let path = LaunchOptions.value("--data-dir") {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        return AppModel(folder: folder, secrets: FileSecretStore(url: folder.appendingPathComponent("secrets-dev.json")))
      }
    #endif
    let folder = URL.applicationSupportDirectory.appendingPathComponent("dev.v57.dbpro", isDirectory: true)
    return AppModel(folder: folder, secrets: KeychainStore())
  }

  // MARK: Persistence

  private var profilesURL: URL? { folder?.appendingPathComponent("connections.json") }
  private var queriesURL: URL? { folder?.appendingPathComponent("saved-queries.json") }

  private func load() {
    if let url = profilesURL, let data = try? Data(contentsOf: url) {
      do {
        profiles = try JSONDecoder().decode([ConnectionProfile].self, from: data)
      } catch {
        print("Couldn't read connections: \(error)")
      }
    }
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
    if let url = profilesURL, let data = try? encoder.encode(profiles) { try? data.write(to: url, options: .atomic) }
    if let url = queriesURL, let data = try? encoder.encode(savedQueries) { try? data.write(to: url, options: .atomic) }
  }

  // MARK: Connections

  func profile(_ id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }

  /// Adds or replaces a profile; passwords go to the Keychain (or are forgotten).
  func save(_ profile: ConnectionProfile, password: String?, sshPassword: String?) {
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    if profile.savePassword {
      try? secrets.setDatabasePassword(password?.isEmpty == false ? password : nil, for: profile.id)
      try? secrets.setSSHPassword(sshPassword?.isEmpty == false ? sshPassword : nil, for: profile.id)
    } else {
      try? secrets.setDatabasePassword(nil, for: profile.id)
      try? secrets.setSSHPassword(nil, for: profile.id)
    }
    persist()
    // A changed profile reconnects next time it's used.
    if let connection = live[profile.id], connection.profile != profile {
      Task { await disconnect(profile.id) }
    }
  }

  func delete(_ id: UUID) {
    Task { await disconnect(id) }
    profiles.removeAll { $0.id == id }
    savedQueries.removeAll { $0.profileID == id }
    try? secrets.setDatabasePassword(nil, for: id)
    try? secrets.setSSHPassword(nil, for: id)
    persist()
  }

  func duplicate(_ id: UUID) {
    guard var copy = profile(id) else { return }
    let password = secrets.databasePassword(for: id)
    let sshPassword = secrets.sshPassword(for: id)
    copy.id = UUID()
    copy.name = copy.displayName + " Copy"
    copy.lastUsed = nil
    save(copy, password: password, sshPassword: sshPassword)
  }

  func move(from source: IndexSet, to destination: Int) {
    profiles.move(fromOffsets: source, toOffset: destination)
    persist()
  }

  /// Remembers an SSH host key after the first successful login.
  func rememberHostKey(_ fingerprint: String?, for id: UUID) {
    guard let fingerprint, let index = profiles.firstIndex(where: { $0.id == id }),
      profiles[index].ssh.hostKeyFingerprint != fingerprint
    else { return }
    profiles[index].ssh.hostKeyFingerprint = fingerprint
    persist()
  }

  func credentials(for profile: ConnectionProfile, password: String? = nil, sshPassword: String? = nil) -> Credentials {
    Credentials(
      password: password ?? secrets.databasePassword(for: profile.id),
      sshPassword: sshPassword ?? secrets.sshPassword(for: profile.id),
      sshKey: profile.ssh.keyID.flatMap { keys.key($0) })
  }

  // MARK: Live connections

  func connection(for id: UUID) -> LiveConnection {
    if let existing = live[id] { return existing }
    let connection = LiveConnection(profile: profile(id) ?? ConnectionProfile(engine: .postgres), app: self)
    live[id] = connection
    return connection
  }

  func disconnect(_ id: UUID) async {
    guard let connection = live[id] else { return }
    live[id] = nil
    await connection.close()
  }

  func markUsed(_ id: UUID) {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
    profiles[index].lastUsed = Date()
    persist()
  }

  /// Tries a profile without saving it.
  func test(_ profile: ConnectionProfile, password: String?, sshPassword: String?) async throws -> ConnectionReport {
    let (session, report) = try await Connector.connect(
      profile, credentials: credentials(for: profile, password: password, sshPassword: sshPassword))
    await session.close()
    return report
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
  func addFile(_ url: URL) -> ConnectionProfile? {
    let ext = url.pathExtension.lowercased()
    guard let engine = EngineKind.allCases.first(where: { $0.fileExtensions.contains(ext) }) else { return nil }
    if let existing = profiles.first(where: { $0.filePath == url.path }) { return existing }
    let profile = ConnectionProfile(name: url.deletingPathExtension().lastPathComponent, engine: engine, filePath: url.path)
    save(profile, password: nil, sshPassword: nil)
    return profile
  }
}

/// Command-line options for development runs.
enum LaunchOptions {
  static func value(_ name: String) -> String? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
  }

  static func flag(_ name: String) -> Bool { ProcessInfo.processInfo.arguments.contains(name) }
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
