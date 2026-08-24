import AppKit
import MongoDB
import PostgreSQL
import Redis
import SQLite
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// ONE form for creating AND editing a saved connection (house pattern):
/// optional prefill via a custom init using underscore property-wrapper state.
/// Secrets rule: the stored password is NEVER read back into the form — the
/// field starts empty on edit and the stored secret is kept unless retyped.
/// Saving persists (insert-or-mutate + save) and then connects.
struct ConnectionFormView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(DatabaseModel.self) private var model

  private let config: EngineSettings?
  private let record: ConnectionRecord?

  @State private var engine: DatabaseEngine
  @State private var name: String
  @State private var host: String
  @State private var port: Int
  @State private var username: String
  @State private var password: String
  @State private var authSource: String
  @State private var defaultDatabase: String
  @State private var directConnection: Bool
  @State private var errorMessage: String?
  @State private var isDropTargeted = false

  init(config: EngineSettings? = nil, record: ConnectionRecord? = nil) {
    self.config = config
    self.record = record
    let settings = config ?? record?.toSettings()
    _engine = State(initialValue: settings?.engine ?? .mongodb)
    _name = State(initialValue: settings?.name ?? "")
    _host = State(initialValue: settings?.host ?? "localhost")
    _port = State(initialValue: settings.map { Int($0.port) } ?? 27017)
    // Per-engine optional fields (kept simple: empty when not applicable).
    let mongo: ConnectionConfig? =
      if case .mongodb(let c) = settings { c } else { nil }
    let pg: PostgresConnectionConfig? =
      if case .postgresql(let c) = settings { c } else { nil }
    let redis: RedisConnectionConfig? =
      if case .redis(let c) = settings { c } else { nil }
    _username = State(
      initialValue: mongo?.username ?? pg?.username ?? redis?.username ?? "")
    // Secrets rule: prefill EMPTY so the stored secret is never read back.
    _password = State(initialValue: "")
    _authSource = State(initialValue: mongo?.authSource ?? "")
    switch settings {
    case .mongodb(let c):
      _defaultDatabase = State(initialValue: c.defaultDatabase ?? "")
    case .postgresql(let c):
      _defaultDatabase = State(initialValue: c.defaultDatabase ?? "")
    case .redis(let c):
      _defaultDatabase = State(initialValue: c.databaseIndex.map(String.init) ?? "0")
    case .sqlite:
      _defaultDatabase = State(initialValue: "")
    case nil:
      _defaultDatabase = State(initialValue: "")
    }
    _directConnection = State(initialValue: mongo?.directConnection ?? false)
  }

  private var isEditing: Bool { record != nil }

  private var isValid: Bool {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    // A SQLite connection is a file path — no port to validate.
    if engine == .sqlite { return true }
    return (1...65535).contains(port)
  }

  /// The label of the default-database field changes per engine.
  private var defaultDatabaseLabel: String {
    switch engine {
    case .mongodb: "Default Database"
    case .postgresql: "Default Database"
    case .redis: "Database Index (0-15)"
    case .sqlite: "Default Database"
    }
  }

  var body: some View {
    Form {
      Text(isEditing ? "Edit Connection" : "Add Connection").font(.headline)
      Section("Connection") {
        Picker("Engine", selection: $engine) {
          ForEach(DatabaseEngine.allCases) { e in Text(e.displayName).tag(e) }
        }.onChange(of: engine) { _, newValue in
          // Prefill the port of the newly selected engine; keep user edits
          // otherwise untouched. SQLite's "host" field is a file path, so
          // switching to it clears a stale hostname and leaving it with an
          // empty path restores the localhost default.
          port = Int(newValue.defaultPort)
          if newValue == .sqlite {
            host = ""
          } else if host.isEmpty {
            host = "localhost"
          }
        }
        TextField("Name", text: $name)
        if engine == .sqlite {
          sqliteFileSection
        } else {
          TextField("Host", text: $host)
          TextField("Port", value: $port, format: .number.grouping(.never))
        }
      }
      if engine != .sqlite {
        Section("Authentication (optional)") {
          TextField("Username", text: $username).disabled(engine == .redis)
            .help(engine == .redis ? "Redis ACL username (rarely used locally)" : "")
          SecureField("Password (kept on edit unless retyped)", text: $password)
          if engine == .mongodb {
            TextField("Auth Source", text: $authSource)
          }
        }
        Section("Startup") {
          TextField(defaultDatabaseLabel, text: $defaultDatabase)
          if engine == .mongodb {
            Toggle("Direct connect", isOn: $directConnection).help(
              "Connect directly to this server, bypassing topology discovery.")
          }
        }
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
      Section {
        HStack {
          Spacer()
          Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
          Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!isValid)
        }
      }
    }.formStyle(.grouped).frame(minWidth: 420, minHeight: 480).padding()
  }

  // MARK: - SQLite file selection

  /// The SQLite connection is a file, not a server: a path field with a
  /// Browse… file picker and a drag-and-drop zone (either fills the path).
  private var sqliteFileSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Database File").font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        TextField("Path to .sqlite or .db file", text: $host)
          .textFieldStyle(.roundedBorder)
        Button("Browse…") { browseForFile() }
      }
      Text("Drag a SQLite file here, or browse.").font(.caption).foregroundStyle(.secondary)
    }
    .padding(8)
    .background(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
          style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5]))
    )
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first, url.isFileURL else { return false }
      host = url.path
      return true
    } isTargeted: { isDropTargeted = $0 }
  }

  private func browseForFile() {
    let panel = NSOpenPanel()
    panel.title = "Choose a SQLite Database"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = sqliteContentTypes
    panel.begin { response in
      if response == .OK, let url = panel.url { host = url.path }
    }
  }

  /// sqlite/sqlite3/db/db3 — dynamic UTIs resolve for any extension.
  private var sqliteContentTypes: [UTType] {
    ["sqlite", "sqlite3", "db", "db3"].compactMap { UTType(filenameExtension: $0) }
  }

  /// Builds the tagged settings from the current fields. On edit, an empty
  /// password field means "keep the stored secret".
  private func buildSettings(passwordOverride: String?) -> EngineSettings {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let user = emptyToNil(username)
    let pass = passwordOverride
    let db = emptyToNil(defaultDatabase)
    switch engine {
    case .mongodb:
      return .mongodb(
        ConnectionConfig(
          name: trimmedName, host: trimmedHost, port: UInt16(port), username: user,
          password: pass, authSource: emptyToNil(authSource), defaultDatabase: db,
          directConnection: directConnection))
    case .postgresql:
      return .postgresql(
        PostgresConnectionConfig(
          name: trimmedName, host: trimmedHost, port: UInt16(port), username: user,
          password: pass, defaultDatabase: db))
    case .redis:
      let index = db.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
      return .redis(
        RedisConnectionConfig(
          name: trimmedName, host: trimmedHost, port: UInt16(port), username: user,
          password: pass, databaseIndex: index))
    case .sqlite:
      return .sqlite(SQLiteConnectionConfig(name: trimmedName, filePath: trimmedHost))
    }
  }

  private func save() {
    do {
      if let record {
        // Edit: mutate the existing record in place so the sidebar row
        // and any running session keep their identity. Engine change resets
        // engine-specific fields that no longer apply.
        let settings = buildSettings(passwordOverride: password.isEmpty ? nil : password)
        record.engineKind = settings.engine
        record.name = settings.name
        record.host = settings.host
        record.port = Int(settings.port)
        switch settings {
        case .mongodb(let c):
          record.username = c.username
          record.password = password.isEmpty ? record.password : password
          record.authSource = c.authSource
          record.defaultDatabase = c.defaultDatabase
          record.directConnection = c.directConnection
        case .postgresql(let c):
          record.username = c.username
          record.password = password.isEmpty ? record.password : password
          record.authSource = nil
          record.defaultDatabase = c.defaultDatabase
          record.directConnection = false
        case .redis(let c):
          record.username = c.username
          record.password = password.isEmpty ? record.password : password
          record.authSource = nil
          record.defaultDatabase = c.databaseIndex.map(String.init)
          record.directConnection = false
        case .sqlite:
          record.username = nil
          record.password = nil
          record.authSource = nil
          record.defaultDatabase = nil
          record.directConnection = false
        }
      } else {
        // Create: new @Model objects are NOT registered by init —
        // insert is required or save() silently persists nothing.
        let savedRecord = ConnectionRecord(name: "", host: "", port: 0)
        applyToNew(savedRecord)
        modelContext.insert(savedRecord)
      }
      try modelContext.save()
      // Connect with the record's final settings, which keeps the stored
      // password when it was not retyped.
      let finalSettings =
        record?.toSettings() ?? buildSettings(passwordOverride: password.isEmpty ? nil : password)
      Task { await model.connect(finalSettings) }
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }

  /// Writes the form fields into a brand-new record (create path).
  private func applyToNew(_ target: ConnectionRecord) {
    let settings = buildSettings(passwordOverride: password.isEmpty ? nil : password)
    target.engineKind = settings.engine
    target.name = settings.name
    target.host = settings.host
    target.port = Int(settings.port)
    switch settings {
    case .mongodb(let c):
      target.username = c.username
      target.password = password.isEmpty ? nil : password
      target.authSource = c.authSource
      target.defaultDatabase = c.defaultDatabase
      target.directConnection = c.directConnection
    case .postgresql(let c):
      target.username = c.username
      target.password = password.isEmpty ? nil : password
      target.authSource = nil
      target.defaultDatabase = c.defaultDatabase
      target.directConnection = false
    case .redis(let c):
      target.username = c.username
      target.password = password.isEmpty ? nil : password
      target.authSource = nil
      target.defaultDatabase = c.databaseIndex.map(String.init)
      target.directConnection = false
    case .sqlite:
      target.username = nil
      target.password = nil
      target.authSource = nil
      target.defaultDatabase = nil
      target.directConnection = false
    }
  }

  private func emptyToNil(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}
