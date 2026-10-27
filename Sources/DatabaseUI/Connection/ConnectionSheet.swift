import ComponentKit
import DatabaseKit
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// New and Edit Connection: paste a link or pick an engine, pick where it connects from (this device or an
/// SSH configuration), fill in the server, decide how safe it is.
struct ConnectionSheet: View {
  let original: ConnectionProfile?
  let onSave: (ConnectionProfile) -> Void
  @Environment(DatabaseModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss

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
  /// The SSH configuration a new connection starts out going through.
  private let startHost: VaultHost?

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

  init(profile: ConnectionProfile?, through host: VaultHost? = nil, onSave: @escaping (ConnectionProfile) -> Void) {
    original = profile
    startHost = profile == nil ? host : nil
    self.onSave = onSave
    _profile = State(initialValue: profile ?? ConnectionProfile(engine: .postgres))
    _editsServer = State(initialValue: profile == nil)
  }

  var body: some View {
    KitSheet(
      title: original == nil ? "New Connection" : "Edit Connection",
      meta: "Paste a link from your host, or pick a database and fill in the details.", width: 680,
      icon: { profile.engine.tile(size: 32) }
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          linkField
          engineGrid
          if !profile.engine.isFileBased {
            locationGrid
          }
          serverSection
          if !profile.engine.isFileBased {
            ViewThatFits(in: .horizontal) {
              HStack(alignment: .top, spacing: KitMetrics.gutter) {
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
        .padding(.vertical, 4)
      }
      #if DEBUG
        .defaultScrollAnchor(LaunchOptions.flag("--scroll-bottom") ? .bottom : .top)
      #endif
      .frame(minHeight: 420, idealHeight: 620)
    } footer: {
      footerStatus
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
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(!profile.problems.isEmpty)
    }
    .onAppear {
      loadSecrets()
      if let startHost { use(startHost) }
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
    .kitSheet(item: $editingHost) { draft in
      SSHHostSheet(
        host: draft.host, isNew: draft.isNew,
        fingerprint: try? app.hostKeys.store?.knownFingerprint(host: draft.host.hostname, port: draft.host.port)
      ) { host, password in
        save(host, password: password)
      }
      .componentKit(accent: .databaseAccent)
    }
    .kitConfirmation(
      "Delete “\(deletingHost?.displayName ?? "")”?", isPresented: Binding(get: { deletingHost != nil }, set: { if !$0 { deletingHost = nil } }),
      message: "Shell and the other v57 apps won’t list it anymore.", systemImage: "trash", confirm: "Delete"
    ) {
      if let host = deletingHost { delete(host) }
      deletingHost = nil
    }
  }

  // MARK: Link

  private var linkField: some View {
    VStack(alignment: .leading, spacing: 6) {
      SheetHeading("Connection link")
      TextField("Connection link", text: $link, prompt: Text("postgres://user@host:5432/database"))
        .kitField(status: recognized != nil ? .valid : .none, mono: true)
        .onChange(of: link) { _, text in readLink(text) }
        #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        #endif
      if let recognized {
        Label(recognized, systemImage: "checkmark").kitFont(.caption).foregroundStyle(Hue.green.text).padding(.horizontal, 4)
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
    VStack(alignment: .leading, spacing: 6) {
      SheetHeading("Database")
      LazyVGrid(columns: tileColumns, spacing: KitMetrics.gutter) {
        ForEach(EngineKind.available) { engine in
          ChoiceCard(isOn: Binding(get: { profile.engine == engine }, set: { if $0 { choose(engine) } })) {
            ChoiceCardLabel(engine.displayName, subtitle: engine.kindLabel) { engine.tile(size: 26) }
          }
        }
      }
    }
  }

  private var tileColumns: [GridItem] { [GridItem(.adaptive(minimum: 140), spacing: KitMetrics.gutter)] }

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
    VStack(alignment: .leading, spacing: 6) {
      SheetHeading("Location")
      LazyVGrid(columns: tileColumns, spacing: KitMetrics.gutter) {
        ChoiceCard(
          Self.thisDevice, subtitle: "Localhost", systemImage: Self.thisDeviceSymbol,
          isOn: Binding(get: { !profile.ssh.enabled }, set: { if $0 { profile.ssh.enabled = false; test = .idle } }))
        // Devices on the user's Hub (kept by the Vault app) come with the rest, reached at their Hub Network address.
        ForEach(app.vault.hosts) { host in
          ChoiceCard(
            host.name.isEmpty ? host.hostname : host.name,
            subtitle: host.isViaHub ? "Via Hub · \(address(of: host))" : address(of: host),
            systemImage: host.isViaHub ? "point.3.connected.trianglepath.dotted" : "server.rack",
            hue: host.isViaHub ? .purple : .teal,
            isOn: Binding(get: { isSelected(host) }, set: { if $0 { use(host) } }))
          .kitContextMenu { menu(for: host) }
        }
        // SSH settings no saved configuration matches (made before configurations were shared).
        if profile.ssh.enabled, !app.vault.hosts.contains(where: isSelected) {
          ChoiceCard(
            profile.ssh.host.isEmpty ? "SSH server" : profile.ssh.host, subtitle: "Not saved", systemImage: "server.rack", hue: .teal,
            isOn: Binding(get: { true }, set: { _ in editingHost = HostDraft(host: unsavedHost, isNew: true) }))
          .kitContextMenu {
            Button("Save as Configuration…") { editingHost = HostDraft(host: unsavedHost, isNew: true) }
          }
        }
        ChoiceCard(
          "New SSH", subtitle: "Configuration", systemImage: "plus", hue: .gray,
          isOn: Binding(get: { false }, set: { _ in editingHost = HostDraft(host: VaultHost(hostname: "", source: "databasepro"), isNew: true) }))
      }
      if let host = app.vault.hosts.first(where: isSelected) {
        Text("Connects through \(host.displayName) to \(profile.host.isEmpty ? "the database" : profile.host):\(profile.port.formatted(.number.grouping(.never))). Right-click a configuration to edit it.")
          .kitFont(.caption).padding(.horizontal, 4)
      }
    }
  }

  @ViewBuilder private func menu(for host: VaultHost) -> some View {
    Button("Edit…") { editingHost = HostDraft(host: host, isNew: false) }
    if host.auth != .password,
      let line = SSHHostSheet.publicKeyLine(host.auth == .importedKey ? host.keyID.flatMap(UUID.init(uuidString:)) : nil, keys: app.keys)
    {
      Button("Copy Public Key") { KitPasteboard.copy(line) }
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
    #elseif os(Windows)
      "This PC"
    #elseif os(Linux)
      "This Computer"
    #else
      UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
    #endif
  }

  private static var thisDeviceSymbol: String {
    #if os(macOS) || os(Windows) || os(Linux)
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
    profile.ssh.hostKeyFingerprint = try? app.hostKeys.store?.knownFingerprint(host: host.hostname, port: host.port)
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
    VStack(alignment: .leading, spacing: 6) {
      SheetHeading(profile.engine.isFileBased ? "File" : "Server")
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
    RichHeader(
      Text("\(profile.host):\(profile.port.formatted(.number.grouping(.never)))"),
      icon: { profile.engine.tile(size: 24) }, meta: { Text(serverDetails) },
      accessory: { Button("Edit") { editsServer = true }.buttonStyle(.kit).controlSize(.small) })
    .kitCard()
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
    FormCard {
      FormRow("Host", systemImage: "network", field: hostField)
      FormRow("Port", help: "\(profile.engine.displayName) listens on \(profile.engine.defaultPort.formatted(.number.grouping(.never))) by default", systemImage: "number", hue: .gray) {
        TextField("Port", value: $profile.port, format: .number.grouping(.never))
          .kitField(mono: true)
          .multilineTextAlignment(.trailing)
          .frame(width: 80)
      }
      FormRow(databaseLabel, systemImage: "cylinder", hue: profile.engine.hue,
        field: TextField(databaseLabel, text: $profile.database, prompt: Text(profile.engine == .redis ? "0" : "optional")))
      FormRow("User", systemImage: "person", hue: .gray, field: userField)
      if profile.engine == .mongodb {
        FormRow("Auth database", systemImage: "person.badge.key", hue: .gray,
          field: TextField("Auth database", text: Binding(get: { profile.options["authSource"] ?? "" }, set: { profile.options["authSource"] = $0.isEmpty ? nil : $0 }), prompt: Text("admin")))
      }
    }
  }

  private var hostField: some View {
    TextField("Host", text: $profile.host, prompt: Text("db.example.com"))
      #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
      #endif
  }

  private var userField: some View {
    TextField("User", text: $profile.user, prompt: Text(profile.engine == .redis || profile.engine == .mongodb ? "optional" : ""))
      #if os(iOS)
        .textInputAutocapitalization(.never)
      #endif
  }

  private var fileForm: some View {
    VStack(alignment: .leading, spacing: KitMetrics.gutter) {
      FormCard(footer: profile.engine == .duckdb ? "A .duckdb file, or a Parquet, CSV or JSON file to query directly." : nil) {
        FormRow(
          profile.filePath.isEmpty ? "No file chosen" : (profile.filePath as NSString).lastPathComponent,
          help: profile.filePath.isEmpty ? nil : (profile.filePath as NSString).abbreviatingWithTildeInPath,
          systemImage: "doc", hue: profile.engine.hue
        ) {
          Button("Choose…") { pickingFile = true }.buttonStyle(.kit).controlSize(.small)
        }
      }
      if profile.engine == .duckdb, !app.duckDB.isInstalled {
        DuckDBInstallRow().kitCard(padding: 10)
      }
    }
  }

  // MARK: Password and encryption

  private var passwordSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      SheetHeading("Password")
      SecureField("Password", text: $password, prompt: Text(profile.user.isEmpty ? "Password" : "Password for \(profile.user)"))
        .kitField {
          if profile.savePassword {
            Label("Keychain", systemImage: "lock").kitFont(.caption)
          }
        }
      Toggle("Save password in the Keychain", isOn: $profile.savePassword)
        .toggleStyle(.kitCheckbox)
        .padding(.horizontal, 4)
    }
  }

  private var encryptionSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      SheetHeading("Encryption")
      FormCard {
        if profile.engine.supportsDirectTLS {
          FormRow(
            "Encrypted connection (TLS)",
            help: profile.engine == .postgres ? "Needs PostgreSQL 17 or later (direct TLS)." : "For servers that require it, like hosted databases.",
            systemImage: "lock", hue: .green
          ) {
            Toggle("Encrypted connection (TLS)", isOn: $profile.useTLS).toggleStyle(.kitSwitch).kitLabelsHidden()
          }
          if profile.useTLS {
            FormRow("Accept self-signed certificates", systemImage: "checkmark.seal", hue: .orange) {
              Toggle("Accept self-signed certificates", isOn: $profile.allowUntrustedCertificate).toggleStyle(.kitSwitch).kitLabelsHidden()
            }
          }
        } else {
          FormRow(
            "Encrypted after it starts",
            help: "\(profile.engine.displayName) encrypts after the connection starts. Connect through SSH to encrypt it end to end.",
            systemImage: "lock.shield", hue: .gray)
        }
      }
    }
  }

  // MARK: Safety

  private var safetySection: some View {
    FormCard("Name and safety") {
      FormRow("Name", systemImage: "character.cursor.ibeam", hue: .gray, field: TextField("Name", text: $profile.name, prompt: Text(profile.displayName)))
      FormRow("Color", help: "A dot beside its name in the sidebar", systemImage: "paintpalette", hue: profile.color.hue ?? .gray) {
        HStack(spacing: 2) {
          ForEach(ColorTag.allCases) { tag in
            Button {
              withKitAnimation { profile.color = tag }
            } label: {
              Circle()
                .fill(tag.hue.map { AnyShapeStyle($0.fill) } ?? AnyShapeStyle(Color.clear))
                .overlay {
                  if tag == .none { Circle().strokeBorder(.kitTertiary, style: StrokeStyle(lineWidth: 1, dash: [2])) }
                }
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(profile.color == tag ? AnyShapeStyle(.kitLabel) : AnyShapeStyle(Color.clear), lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tag == .none ? "No color" : tag.label)
            .accessibilityAddTraits(profile.color == tag ? .isSelected : [])
          }
        }
      }
      FormRow("Production", help: "Shows a red tag. Every change is reviewed before it's saved.", systemImage: "shield", hue: .red) {
        Toggle("Production", isOn: $profile.isProduction).toggleStyle(.kitSwitch).kitLabelsHidden()
      }
      FormRow("Read only", help: "Look, but never change anything.", systemImage: "lock", hue: .gray) {
        Toggle("Read only", isOn: $profile.isReadOnly).toggleStyle(.kitSwitch).kitLabelsHidden()
      }
    }
  }

  private var fileTypes: [UTType] {
    var types: [UTType] = [.data]
    for ext in profile.engine.fileExtensions { if let type = UTType(filenameExtension: ext) { types.append(type) } }
    return types
  }

  // MARK: Footer

  /// The footer's lead: what's missing, the test while it runs, then how it went.
  @ViewBuilder private var footerStatus: some View {
    switch test {
    case .idle:
      if let problem = profile.problems.first {
        SheetStatus(problem, systemImage: "exclamationmark", hue: .orange)
      } else {
        SheetStatus(readyText, systemImage: "checkmark", status: .done)
      }
    case .testing:
      SheetStatus("Connecting…", systemImage: "bolt", status: .working)
    case .success(let text):
      SheetStatus(text, systemImage: "bolt", status: .done)
    case .failure(let text):
      SheetStatus(text, systemImage: "bolt", status: .failed(text))
    }
  }

  private var readyText: String {
    profile.engine.isFileBased
      ? "\(profile.engine.displayName) file"
      : "\(profile.engine.displayName) at \(profile.host)"
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

/// A heading over a group in a sheet.
struct SheetHeading: View {
  let title: String

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title).kitFont(.headline).padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
  }
}
