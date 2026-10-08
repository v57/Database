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
/// field starts empty on edit and the stored secret is kept unless retyped
/// (or explicitly removed). A new connection is saved and connected; an edit
/// only reconnects when it changed the live connection.
struct ConnectionFormView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(DatabaseModel.self) private var model

  private let config: EngineSettings?
  private let record: ConnectionRecord?
  /// Connects a saved record. The sidebar passes its own connect so the row
  /// shows progress and failures name the connection; nil falls back to the
  /// model directly.
  private let onConnect: ((ConnectionRecord) -> Void)?

  @State private var engine: DatabaseEngine
  @State private var name: String
  @State private var host: String
  @State private var port: Int
  @State private var username: String
  @State private var password: String
  /// Edit only: drop the stored secret instead of keeping it.
  @State private var removeSavedPassword = false
  @State private var authSource: String
  @State private var defaultDatabase: String
  @State private var directConnection: Bool
  @State private var errorMessage: String?
  @State private var isDropTargeted = false
  @State private var isFileImporterPresented = false
  @State private var testState: TestState = .idle
  @State private var testTask: Task<Void, Never>?

  /// Outcome of the "Test Connection" button, shown inline under the buttons.
  private enum TestState: Equatable {
    case idle
    case running
    case succeeded
    case failed(String)
  }

  init(
    config: EngineSettings? = nil, record: ConnectionRecord? = nil,
    onConnect: ((ConnectionRecord) -> Void)? = nil
  ) {
    self.config = config
    self.record = record
    self.onConnect = onConnect
    let settings = config ?? record?.toSettings()
    _engine = State(initialValue: settings?.engine ?? .mongodb)
    _name = State(initialValue: settings?.name ?? "")
    _host = State(initialValue: settings?.host ?? "localhost")
    _port = State(initialValue: settings.map { Int($0.port) } ?? 27017)
    // Per-engine optional fields (kept simple: empty when not applicable).
    let mongo: ConnectionConfig? = if case .mongodb(let c) = settings { c } else { nil }
    let pg: PostgresConnectionConfig? = if case .postgresql(let c) = settings { c } else { nil }
    let redis: RedisConnectionConfig? = if case .redis(let c) = settings { c } else { nil }
    _username = State(initialValue: mongo?.username ?? pg?.username ?? redis?.username ?? "")
    // Secrets rule: prefill EMPTY so the stored secret is never read back.
    _password = State(initialValue: "")
    _authSource = State(initialValue: mongo?.authSource ?? "")
    switch settings {
    case .mongodb(let c): _defaultDatabase = State(initialValue: c.defaultDatabase ?? "")
    case .postgresql(let c): _defaultDatabase = State(initialValue: c.defaultDatabase ?? "")
    // Empty means "server default" (index 0); the field shows "0" as its prompt.
    case .redis(let c): _defaultDatabase = State(initialValue: c.databaseIndex.map(String.init) ?? "")
    case .sqlite: _defaultDatabase = State(initialValue: "")
    case nil: _defaultDatabase = State(initialValue: "")
    }
    _directConnection = State(initialValue: mongo?.directConnection ?? false)
  }

  private var isEditing: Bool { record != nil }

  /// SQLite is file-based: no host/port/auth — a path + a name.
  private var isFileBased: Bool { engine == .sqlite }

  /// Edit of a record that has a secret: offer "keep" (empty field) or "remove".
  private var hasStoredPassword: Bool { record?.password?.isEmpty == false }

  /// The password a connection built from this form uses: a retyped value
  /// wins; an empty field keeps the stored secret unless removal was chosen.
  private var effectivePassword: String? {
    if !password.isEmpty { return password }
    if removeSavedPassword { return nil }
    return record?.password
  }

  // MARK: - Validation

  /// Redis logical database index: empty = server default (0). The Redis
  /// engine only selects/lists indexes 0–15, so anything else is rejected
  /// here instead of silently becoming "default".
  private enum RedisIndex: Equatable {
    case serverDefault
    case index(Int)
    case invalid
  }

  private var redisIndex: RedisIndex {
    let text = defaultDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return .serverDefault }
    guard let value = Int(text), (0...15).contains(value) else { return .invalid }
    return .index(value)
  }

  /// The first problem blocking Save/Test, shown as an inline footnote so a
  /// greyed-out button is never unexplained. `isError` marks bad input (red)
  /// as opposed to a field that simply isn't filled in yet.
  private var validationIssue: (message: String, isError: Bool)? {
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ("Enter a name for this connection.", false)
    }
    if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return (isFileBased ? "Choose a database file." : "Enter a host.", false)
    }
    // A SQLite connection is a file path — no port to validate.
    if isFileBased { return nil }
    if !(1...65535).contains(port) { return ("Port must be between 1 and 65535.", true) }
    if engine == .redis, redisIndex == .invalid {
      return ("Database index must be a whole number from 0 to 15 (empty = 0).", true)
    }
    return nil
  }

  private var isValid: Bool { validationIssue == nil }

  /// Everything a connection test depends on; a change makes an earlier
  /// test result stale.
  private var testFingerprint: [String] {
    [
      engine.rawValue, host, String(port), username, password, String(removeSavedPassword),
      authSource, defaultDatabase, String(directConnection),
    ]
  }

  var body: some View {
    Form {
      Text(isEditing ? "Edit Connection" : "Add Connection").font(.headline)
      Section("Connection") {
        Picker("Engine", selection: $engine) {
          ForEach(DatabaseEngine.allCases) { e in Text(e.displayName).tag(e) }
        }.onChange(of: engine) { _, newValue in
          // Prefill the port of the newly selected engine; keep user edits
          // otherwise untouched. SQLite's \"host\" field is a file
          // path, so switching to either clears a stale hostname and leaving
          // it with an empty path restores the localhost default.
          port = Int(newValue.defaultPort)
          if newValue == .sqlite {
            host = ""
          } else if host.isEmpty {
            host = "localhost"
          }
        }
        TextField("Name", text: $name)
        if isFileBased {
          fileSection
        } else {
          TextField("Host", text: $host)
          TextField("Port", value: $port, format: .number.grouping(.never))
        }
      }
      if !isFileBased {
        Section("Authentication (optional)") {
          TextField("Username", text: $username, prompt: usernamePrompt).help(
            engine == .redis
              ? "Redis 6+ ACL username. Leave empty to authenticate as the default user." : "")
          SecureField("Password", text: $password, prompt: passwordPrompt).disabled(
            removeSavedPassword)
          if hasStoredPassword {
            Toggle("Remove saved password", isOn: $removeSavedPassword).onChange(
              of: removeSavedPassword
            ) { _, remove in if remove { password = "" } }
          }
          if engine == .mongodb { TextField("Auth Source", text: $authSource) }
        }
        Section("Startup") {
          if engine == .redis {
            TextField("Database Index (0–15)", text: $defaultDatabase, prompt: Text("0"))
          } else {
            TextField("Default Database", text: $defaultDatabase)
          }
          if engine == .mongodb {
            Toggle("Direct connect", isOn: $directConnection).help(
              "Connect directly to this server, bypassing topology discovery.")
          }
        }
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
      Section {
        if let issue = validationIssue {
          Label(issue.message, systemImage: "exclamationmark.circle").font(.footnote)
            .foregroundStyle(issue.isError ? Color.red : Color.secondary)
        }
        HStack {
          Button("Test Connection") { testConnection() }.disabled(
            !isValid || testState == .running)
          if testState == .running { ProgressView().controlSize(.small) }
          Spacer()
          Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
          Button(isEditing ? "Save" : "Save & Connect") { save() }.keyboardShortcut(
            .defaultAction
          ).disabled(!isValid)
        }
        testResult
      }
    }.formStyle(.grouped).frame(minWidth: 420, minHeight: 480).padding().onChange(
      of: testFingerprint
    ) {
      // A result for different settings would be misleading.
      testTask?.cancel()
      testState = .idle
    }.onDisappear { testTask?.cancel() }
#if os(iOS)
    .fileImporter(
      isPresented: $isFileImporterPresented, allowedContentTypes: databaseContentTypes
    ) { result in
      guard case .success(let url) = result else { return }
      // Picked files outside the app container are security-scoped: access
      // must be opened before SQLite can read the path. The grant lasts for
      // this launch only — reopening the stored path after a relaunch would
      // need a security-scoped bookmark (not persisted yet).
      _ = url.startAccessingSecurityScopedResource()
      host = url.path
    }
#endif
  }

  private var usernamePrompt: Text? {
    engine == .redis ? Text("ACL user (optional)") : nil
  }

  /// "Password" when adding; on edit with a stored secret, explain that an
  /// empty field keeps it.
  private var passwordPrompt: Text? {
    hasStoredPassword && !removeSavedPassword ? Text("Saved — leave empty to keep") : nil
  }

  @ViewBuilder private var testResult: some View {
    switch testState {
    case .idle, .running: EmptyView()
    case .succeeded:
      Label("Connection succeeded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        .font(.callout)
    case .failed(let message):
      Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
        .textSelection(.enabled)
    }
  }

  // MARK: - File selection (SQLite)

  /// File-based connections are a path, not a server: a path field with a
  /// Browse… file picker and a drag-and-drop zone (either fills the path).
  private var fileSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Database File").font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        TextField(filePathPlaceholder, text: $host).textFieldStyle(.roundedBorder)
        Button("Browse…") { browseForFile() }
      }
      Text(fileDragHint).font(.caption).foregroundStyle(.secondary)
    }.padding(8).background(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear).overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(
        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5]))
    ).dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first, url.isFileURL else { return false }
      host = url.path
      return true
    } isTargeted: {
      isDropTargeted = $0
    }
  }

  private var filePathPlaceholder: String {
    switch engine {
    case .sqlite: "Path to .sqlite or .db file"
    default: "Path to database file"
    }
  }

  private var fileDragHint: String {
    switch engine {
    case .sqlite: "Drag a SQLite file here, or browse."
    default: "Drag a database file here, or browse."
    }
  }

  private var filePanelTitle: String {
    switch engine {
    default: "Choose a Database"
    }
  }

  /// macOS: NSOpenPanel (unsandboxed app, plain paths stay readable).
  /// iOS: the system document picker via `.fileImporter`.
  private func browseForFile() {
#if os(macOS)
    let panel = NSOpenPanel()
    panel.title = filePanelTitle
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = databaseContentTypes
    panel.begin { response in if response == .OK, let url = panel.url { host = url.path } }
#else
    isFileImporterPresented = true
#endif
  }

  /// Dynamic UTIs resolve for any extension; per-engine union of extensions.
  private var databaseContentTypes: [UTType] {
    switch engine {
    case .sqlite: return ["sqlite", "sqlite3", "db", "db3"].compactMap { UTType(filenameExtension: $0) }
    default: return ["db"].compactMap { UTType(filenameExtension: $0) }
    }
  }

  // MARK: - Test / save

  /// Opens and closes a throwaway connection with the current fields (and the
  /// effective password), reporting the outcome inline; never dismisses.
  private func testConnection() {
    let settings = buildSettings(passwordOverride: effectivePassword)
    testTask?.cancel()
    testState = .running
    testTask = Task {
      do {
        try await model.testConnection(settings)
        guard !Task.isCancelled else { return }
        testState = .succeeded
      } catch {
        guard !Task.isCancelled else { return }
        testState = .failed(error.localizedDescription)
      }
    }
  }

  /// Builds the tagged settings from the current fields with the given
  /// password (callers pass `effectivePassword`).
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
          name: trimmedName, host: trimmedHost, port: UInt16(port), username: user, password: pass,
          authSource: emptyToNil(authSource), defaultDatabase: db,
          directConnection: directConnection))
    case .postgresql:
      return .postgresql(
        PostgresConnectionConfig(
          name: trimmedName, host: trimmedHost, port: UInt16(port), username: user, password: pass,
          defaultDatabase: db))
    case .redis:
      // Validation blocks Save/Test on `.invalid`, so only valid indexes reach here.
      let index: Int? = if case .index(let value) = redisIndex { value } else { nil }
      return .redis(
        RedisConnectionConfig(
          name: trimmedName, host: trimmedHost, port: UInt16(port), username: user, password: pass,
          databaseIndex: index))
    case .sqlite: return .sqlite(SQLiteConnectionConfig(name: trimmedName, filePath: trimmedHost))
    }
  }

  private func save() {
    guard isValid else { return }
    let settings = buildSettings(passwordOverride: effectivePassword)
    // Decide BEFORE mutating: matching the live session uses the record's
    // saved name/host/port, which the edit may be about to change.
    let editedLiveConnection = record?.matchesLiveSession(of: model) ?? false
    do {
      let saved: ConnectionRecord
      if let record {
        // Edit: mutate the existing record in place so the sidebar row
        // keeps its identity.
        saved = record
      } else {
        // Create: new @Model objects are NOT registered by init —
        // insert is required or save() silently persists nothing.
        saved = ConnectionRecord(name: "", host: "", port: 0)
        modelContext.insert(saved)
      }
      apply(settings, to: saved)
      try modelContext.save()
      // New connections connect right away ("Save & Connect"); an edit only
      // reconnects when it changed the connection that is currently open.
      if !isEditing || editedLiveConnection {
        if let onConnect {
          onConnect(saved)
        } else {
          Task { await model.connect(settings) }
        }
      }
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }

  /// Writes settings into a record (create and edit). An engine change
  /// resets engine-specific fields that no longer apply.
  private func apply(_ settings: EngineSettings, to target: ConnectionRecord) {
    target.engineKind = settings.engine
    target.name = settings.name
    target.host = settings.host
    target.port = Int(settings.port)
    switch settings {
    case .mongodb(let c):
      target.username = c.username
      target.password = c.password
      target.authSource = c.authSource
      target.defaultDatabase = c.defaultDatabase
      target.directConnection = c.directConnection
    case .postgresql(let c):
      target.username = c.username
      target.password = c.password
      target.authSource = nil
      target.defaultDatabase = c.defaultDatabase
      target.directConnection = false
    case .redis(let c):
      target.username = c.username
      target.password = c.password
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
