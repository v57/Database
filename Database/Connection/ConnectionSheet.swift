import DatabaseKit
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// New and Edit Connection: paste a link or pick an engine, pick where it connects from (this device or an
/// SSH configuration), fill in the server, decide how safe it is.
struct ConnectionSheet: View {
  let original: ConnectionProfile?
  let onSave: (ConnectionProfile) -> Void
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss

  @State private var profile: ConnectionProfile
  @State private var link = ""
  @State private var recognized: String?
  @State private var password = ""
  @State private var sshPassword = ""
  /// The server shows as a summary (a pasted link, a saved connection) until Edit turns it back into a form.
  @State private var editsServer: Bool
  @State private var test: TestState = .idle
  @State private var pickingFile = false
  @State private var editingHost: HostDraft?
  @State private var deletingHost: VaultHost?

  enum TestState: Equatable {
    case idle, testing
    case success(String)
    case failure(String)
  }

  /// The SSH configuration being added or edited.
  struct HostDraft: Identifiable {
    var host: VaultHost
    var isNew: Bool
    var id: String { host.id }
  }

  init(profile: ConnectionProfile?, onSave: @escaping (ConnectionProfile) -> Void) {
    original = profile
    self.onSave = onSave
    _profile = State(initialValue: profile ?? ConnectionProfile(engine: .postgres))
    _editsServer = State(initialValue: profile == nil)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 4) {
            Text(original == nil ? "New Connection" : "Edit Connection").font(.title2.bold())
            Text("Paste a link from your host, or pick a database and fill in the details.")
              .foregroundStyle(.secondary)
          }
          linkField
          engineGrid
          if !profile.engine.isFileBased {
            locationGrid
          }
          serverSection
          if !profile.engine.isFileBased {
            ViewThatFits(in: .horizontal) {
              HStack(alignment: .top, spacing: 16) {
                passwordSection.frame(maxWidth: .infinity)
                encryptionSection.frame(maxWidth: .infinity)
              }
              VStack(alignment: .leading, spacing: 16) {
                passwordSection
                encryptionSection
              }
            }
          }
          safetySection
        }
        .padding(24)
      }
      #if DEBUG
        .defaultScrollAnchor(LaunchOptions.flag("--scroll-bottom") ? .bottom : .top)
      #endif
      Divider()
      footer
    }
    .frame(minWidth: 620, idealWidth: 780, minHeight: 560, idealHeight: 760)
    .onAppear {
      loadSecrets()
      #if DEBUG
        if let link = DebugDriver.pendingLink {
          self.link = link
          DebugDriver.pendingLink = nil
        }
        if let name = LaunchOptions.value("--ssh-configuration"), let host = app.vault.hosts.first(where: { $0.displayName == name }) {
          editingHost = HostDraft(host: host, isNew: false)
        }
      #endif
    }
    .fileImporter(isPresented: $pickingFile, allowedContentTypes: fileTypes) { result in
      if case .success(let url) = result {
        _ = url.startAccessingSecurityScopedResource()
        profile.filePath = url.path
        if profile.name.isEmpty { profile.name = url.deletingPathExtension().lastPathComponent }
      }
    }
    .sheet(item: $editingHost) { draft in
      SSHHostSheet(
        host: draft.host, isNew: draft.isNew,
        fingerprint: try? app.vault.store?.knownFingerprint(host: draft.host.hostname, port: draft.host.port)
      ) { host, password in
        save(host, password: password)
      }
    }
    .confirmationDialog(
      "Delete “\(deletingHost?.displayName ?? "")”?", isPresented: Binding(get: { deletingHost != nil }, set: { if !$0 { deletingHost = nil } }),
      presenting: deletingHost
    ) { host in
      Button("Delete", role: .destructive) { delete(host) }
    } message: { _ in
      Text("Shell and the other v57 apps won’t list it anymore.")
    }
  }

  // MARK: Link

  private var linkField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Connection link").font(.callout.weight(.semibold))
      HStack(spacing: 8) {
        Image(systemName: "link").foregroundStyle(.secondary)
        TextField("Connection link", text: $link, prompt: Text("postgres://user@host:5432/database"))
          .textFieldStyle(.plain)
          .font(.code)
          .labelsHidden()
          .onChange(of: link) { _, text in readLink(text) }
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          #endif
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(recognized != nil ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: recognized != nil ? 2 : 1))
      if let recognized {
        Label(recognized, systemImage: "checkmark").font(.callout).foregroundStyle(.green)
      }
    }
  }

  private func readLink(_ text: String) {
    guard let parsed = ConnectionLink.parse(text) else {
      recognized = nil
      return
    }
    var next = parsed.profile
    next.id = profile.id
    next.color = profile.color
    next.isProduction = profile.isProduction
    next.isReadOnly = profile.isReadOnly
    next.ssh = profile.ssh
    profile = next
    if let pw = parsed.password { password = pw }
    editsServer = false
    recognized =
      next.engine.isFileBased
      ? "Recognized a \(next.engine.displayName) file."
      : "Recognized \(next.engine.displayName) at \(next.host)."
  }

  // MARK: Engines

  private var engineGrid: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Database").font(.callout.weight(.semibold))
      LazyVGrid(columns: tileColumns, spacing: 8) {
        ForEach(EngineKind.available) { engine in
          ChoiceTile(title: engine.displayName, subtitle: engine.kindLabel, selected: profile.engine == engine) {
            choose(engine)
          } icon: {
            EngineTile(engine: engine, size: 28)
          }
        }
      }
    }
  }

  private var tileColumns: [GridItem] { [GridItem(.adaptive(minimum: 132), spacing: 8)] }

  private func choose(_ engine: EngineKind) {
    let old = profile.engine
    profile.engine = engine
    if profile.port == old.defaultPort || profile.port == 0 { profile.port = engine.defaultPort }
    if profile.user.isEmpty || profile.user == old.defaultUser { profile.user = engine.defaultUser }
    if !engine.supportsDirectTLS { profile.useTLS = false }
    test = .idle
  }

  // MARK: Location

  /// This device, then every shared SSH configuration (Shell's saved hosts), then a tile to add one.
  private var locationGrid: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Location").font(.callout.weight(.semibold))
      LazyVGrid(columns: tileColumns, spacing: 8) {
        ChoiceTile(title: Self.thisDevice, subtitle: "Localhost", selected: !profile.ssh.enabled) {
          profile.ssh.enabled = false
          test = .idle
        } icon: {
          SymbolTile(systemName: Self.thisDeviceSymbol, tint: .accentColor)
        }
        ForEach(app.vault.hosts) { host in
          ChoiceTile(title: host.name.isEmpty ? host.hostname : host.name, subtitle: address(of: host), selected: isSelected(host)) {
            use(host)
          } icon: {
            SymbolTile(systemName: "server.rack", tint: .teal)
          }
          .contextMenu { menu(for: host) }
        }
        // SSH settings no saved configuration matches (made before configurations were shared).
        if profile.ssh.enabled, !app.vault.hosts.contains(where: isSelected) {
          ChoiceTile(title: profile.ssh.host.isEmpty ? "SSH server" : profile.ssh.host, subtitle: "Not saved", selected: true) {
            editingHost = HostDraft(host: unsavedHost, isNew: true)
          } icon: {
            SymbolTile(systemName: "server.rack", tint: .teal)
          }
          .contextMenu {
            Button("Save as Configuration…") { editingHost = HostDraft(host: unsavedHost, isNew: true) }
          }
        }
        ChoiceTile(title: "New SSH", subtitle: "Configuration") {
          editingHost = HostDraft(host: VaultHost(hostname: "", source: "databasepro"), isNew: true)
        } icon: {
          SymbolTile(systemName: "plus", tint: .secondary)
        }
      }
      if let host = app.vault.hosts.first(where: isSelected) {
        Text("Connects through \(host.displayName) to \(profile.host.isEmpty ? "the database" : profile.host):\(profile.port.formatted(.number.grouping(.never))). Right-click a configuration to edit it.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private func menu(for host: VaultHost) -> some View {
    Button("Edit…") { editingHost = HostDraft(host: host, isNew: false) }
    if host.auth != .password,
      let line = SSHHostSheet.publicKeyLine(host.auth == .importedKey ? host.keyID.flatMap(UUID.init(uuidString:)) : nil, keys: app.keys)
    {
      Button("Copy Public Key") { Clipboard.copy(line) }
    }
    if isSelected(host), profile.ssh.hostKeyFingerprint != nil {
      Button("Forget Host Key") { profile.ssh.hostKeyFingerprint = nil }
    }
    Divider()
    Button("Delete…", role: .destructive) { deletingHost = host }
      .disabled(isInUse(host))
  }

  private static var thisDevice: String {
    #if os(macOS)
      "This Mac"
    #else
      UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
    #endif
  }

  private static var thisDeviceSymbol: String {
    #if os(macOS)
      "laptopcomputer"
    #else
      UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    #endif
  }

  /// "root@bastion.example.com", with the port when it isn't 22.
  private func address(of host: VaultHost) -> String {
    var text = host.user.isEmpty ? host.hostname : "\(host.user)@\(host.hostname)"
    if host.port != 22 { text += ":\(host.port.formatted(.number.grouping(.never)))" }
    return text
  }

  private func isSelected(_ host: VaultHost) -> Bool {
    profile.ssh.enabled && host.hostname.caseInsensitiveCompare(profile.ssh.host) == .orderedSame
      && host.port == profile.ssh.port && host.user == profile.ssh.user
  }

  /// Whether another saved connection tunnels through the host (deleting it would make that one connect directly).
  private func isInUse(_ host: VaultHost) -> Bool {
    let mine = original.map { app.vaultID(for: $0.id) }
    return app.vault.databases.contains { $0.sshHostID == host.id && $0.id != mine }
  }

  private var unsavedHost: VaultHost {
    let ssh = profile.ssh
    return VaultHost(
      hostname: ssh.host, port: ssh.port, user: ssh.user,
      auth: ssh.auth == .password ? .password : (ssh.keyID == nil ? .deviceKey : .importedKey),
      keyID: ssh.keyID?.uuidString, source: "databasepro")
  }

  /// Connects through a shared host.
  private func use(_ host: VaultHost) {
    profile.ssh.enabled = true
    profile.ssh.host = host.hostname
    profile.ssh.port = host.port
    profile.ssh.user = host.user
    profile.ssh.auth = host.auth == .password ? .password : .key
    profile.ssh.keyID = host.auth == .importedKey ? host.keyID.flatMap(UUID.init(uuidString:)) : nil
    profile.ssh.hostKeyFingerprint = try? app.vault.store?.knownFingerprint(host: host.hostname, port: host.port)
    sshPassword = host.auth == .password ? host.password ?? "" : ""
    test = .idle
  }

  /// Saves an added or edited SSH configuration for every v57 app, and connects through it.
  private func save(_ host: VaultHost, password: String) {
    app.vault.save(host)
    try? app.secrets.setHostPassword(host.auth == .password && host.savePassword && !password.isEmpty ? password : nil, for: host.id)
    use(host)
    if host.auth == .password { sshPassword = password }
  }

  private func delete(_ host: VaultHost) {
    if isSelected(host) { profile.ssh.enabled = false }
    try? app.secrets.setHostPassword(nil, for: host.id)
    app.vault.delete(host)
  }

  // MARK: Server

  private var databaseLabel: String {
    switch profile.engine {
    case .redis: "Index"
    case .cassandra, .scylla: "Keyspace"
    default: "Database"
    }
  }

  private var serverSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(profile.engine.isFileBased ? "File" : "Server").font(.callout.weight(.semibold))
      if profile.engine.isFileBased {
        fileForm
      } else if editsServer || hasServerProblem {
        serverForm
      } else {
        serverSummary
      }
    }
  }

  private var hasServerProblem: Bool {
    profile.host.trimmingCharacters(in: .whitespaces).isEmpty || !(1...65535).contains(profile.port)
  }

  /// The server in one line, with Edit to change it.
  private var serverSummary: some View {
    HStack(spacing: 10) {
      EngineTile(engine: profile.engine, size: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text("\(profile.host):\(profile.port.formatted(.number.grouping(.never)))")
          .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
        Text(serverDetails).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Button("Edit") { editsServer = true }
    }
    .padding(12)
    .groupBox()
  }

  /// "Database shop · User app".
  private var serverDetails: String {
    var parts: [String] = []
    if !profile.database.isEmpty { parts.append("\(databaseLabel) \(profile.database)") }
    if !profile.user.isEmpty { parts.append("User \(profile.user)") }
    if profile.engine == .mongodb, let source = profile.options["authSource"] { parts.append("Auth database \(source)") }
    return parts.isEmpty ? profile.engine.displayName : parts.joined(separator: " · ")
  }

  private var serverForm: some View {
    VStack(spacing: 0) {
      FormRow("Host") {
        HStack {
          TextField("Host", text: $profile.host, prompt: Text("db.example.com"))
            #if os(iOS)
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
            #endif
          Text("Port").foregroundStyle(.secondary)
          TextField("Port", value: $profile.port, format: .number.grouping(.never))
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
        }
      }
      FormRow(databaseLabel) {
        TextField(databaseLabel, text: $profile.database, prompt: Text(profile.engine == .redis ? "0" : "optional"))
      }
      FormRow("User", last: profile.engine != .mongodb) {
        TextField("User", text: $profile.user, prompt: Text(profile.engine == .redis || profile.engine == .mongodb ? "optional" : ""))
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
      }
      if profile.engine == .mongodb {
        FormRow("Auth database", last: true) {
          TextField("Auth database", text: Binding(get: { profile.options["authSource"] ?? "" }, set: { profile.options["authSource"] = $0.isEmpty ? nil : $0 }), prompt: Text("admin"))
        }
      }
    }
    .labelsHidden()
    .textFieldStyle(.plain)
    .groupBox()
  }

  private var fileForm: some View {
    VStack(spacing: 0) {
      FormRow("File", last: profile.engine != .duckdb) {
        HStack {
          Text(profile.filePath.isEmpty ? "No file chosen" : (profile.filePath as NSString).abbreviatingWithTildeInPath)
            .foregroundStyle(profile.filePath.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Button("Choose…") { pickingFile = true }
        }
      }
      if profile.engine == .duckdb {
        Text("A .duckdb file, or a Parquet, CSV or JSON file to query directly.")
          .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
        if !app.duckDB.isInstalled {
          Divider()
          DuckDBInstallRow().padding(.horizontal, 12).padding(.vertical, 8)
        }
      }
    }
    .groupBox()
  }

  // MARK: Password and encryption

  private var passwordSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Password").font(.callout.weight(.semibold))
      HStack {
        SecureField("Password", text: $password, prompt: Text(profile.user.isEmpty ? "Password" : "Password for \(profile.user)"))
          .textFieldStyle(.plain)
          .labelsHidden()
        if profile.savePassword {
          Label("Keychain", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 38)
      .groupBox()
      Toggle("Save password in the Keychain", isOn: $profile.savePassword).font(.callout)
    }
  }

  private var encryptionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Encryption").font(.callout.weight(.semibold))
      VStack(alignment: .leading, spacing: 0) {
        if profile.engine.supportsDirectTLS {
          SwitchRow("Encrypted connection (TLS)", caption: profile.engine == .postgres ? "Needs PostgreSQL 17 or later (direct TLS)." : "For servers that require it, like hosted databases.", isOn: $profile.useTLS)
            .padding(12)
          if profile.useTLS {
            Divider().padding(.leading, 12)
            SwitchRow("Accept self-signed certificates", isOn: $profile.allowUntrustedCertificate)
              .padding(12)
          }
        } else {
          Label("\(profile.engine.displayName) encrypts after the connection starts. Connect through SSH to encrypt it end to end.", systemImage: "lock.shield")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
        }
      }
      .groupBox()
    }
  }

  // MARK: Safety

  private var safetySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Name and safety").font(.callout.weight(.semibold))
      VStack(spacing: 0) {
        FormRow("Name") {
          TextField("Name", text: $profile.name, prompt: Text(profile.displayName))
            .textFieldStyle(.plain)
            .labelsHidden()
        }
        FormRow("Color") {
          ForEach(ColorTag.allCases) { tag in
            Button {
              profile.color = tag
            } label: {
              Circle()
                .fill(tag.color ?? .clear)
                .overlay(Circle().strokeBorder(tag == .none ? Color.secondary : .clear, style: StrokeStyle(lineWidth: 1, dash: [2])))
                .frame(width: 20, height: 20)
                .padding(2)
                .overlay(Circle().strokeBorder(profile.color == tag ? Color.primary : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tag == .none ? "No color" : tag.label)
            .accessibilityAddTraits(profile.color == tag ? .isSelected : [])
          }
          Spacer(minLength: 0)
        }
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 0) {
            productionRow
            Divider()
            readOnlyRow
          }
          VStack(spacing: 0) {
            productionRow
            Divider().padding(.leading, 12)
            readOnlyRow
          }
        }
      }
      .groupBox()
    }
  }

  private var productionRow: some View {
    SwitchRow("Production", caption: "Shows a red tag. Every change is reviewed before it's saved.", isOn: $profile.isProduction)
      .padding(12)
  }

  private var readOnlyRow: some View {
    SwitchRow("Read only", caption: "Look, but never change anything.", isOn: $profile.isReadOnly)
      .padding(12)
  }

  private var fileTypes: [UTType] {
    var types: [UTType] = [.data]
    for ext in profile.engine.fileExtensions { if let type = UTType(filenameExtension: ext) { types.append(type) } }
    return types
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 10) {
      Group {
        switch test {
        case .idle:
          if let problem = profile.problems.first {
            Text(problem).foregroundStyle(.secondary)
          }
        case .testing:
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Connecting…").foregroundStyle(.secondary)
          }
        case .success(let text):
          Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let text):
          Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
        }
      }
      .font(.callout)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(test == .idle ? "Test" : "Test Again") { runTest() }
        .disabled(!profile.problems.isEmpty || test == .testing)
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(original == nil ? "Connect" : "Save") {
        var saved = profile
        if saved.name.isEmpty { saved.name = saved.displayName }
        app.save(saved, password: password, sshPassword: sshPassword)
        onSave(saved)
        dismiss()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(!profile.problems.isEmpty)
    }
    .padding(16)
  }

  private func runTest() {
    test = .testing
    let snapshot = profile
    Task {
      do {
        let report = try await app.test(snapshot, password: password, sshPassword: sshPassword)
        var text = "Connected to \(report.serverDescription) in \(formatDuration(report.elapsed))"
        if let fingerprint = report.sshHostKeyFingerprint {
          if profile.ssh.hostKeyFingerprint == nil {
            profile.ssh.hostKeyFingerprint = fingerprint
            text += " · SSH host key \(report.sshHostKeyType ?? "") saved"
          }
        }
        test = .success(text)
      } catch {
        test = .failure(FriendlyError.message(error))
      }
    }
  }

  private func loadSecrets() {
    guard let original else { return }
    password = app.databasePassword(for: original.id) ?? ""
    sshPassword = app.sshPassword(for: original.id) ?? ""
  }
}

/// A title and caption on the left, a switch on the right: the settings-row layout.
struct SwitchRow: View {
  let title: String
  var caption: String?
  @Binding var isOn: Bool

  init(_ title: String, caption: String? = nil, isOn: Binding<Bool>) {
    self.title = title
    self.caption = caption
    _isOn = isOn
  }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
    }
  }
}
