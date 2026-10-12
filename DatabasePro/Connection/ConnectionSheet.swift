import DatabaseCore
import SwiftUI
import UniformTypeIdentifiers

/// New and Edit Connection: paste a link or pick an engine, fill in the server, decide how safe it is.
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
  @State private var showsAdvanced = false
  @State private var test: TestState = .idle
  @State private var pickingFile = false
  @State private var importingKey = false
  @State private var keyError: String?

  enum TestState: Equatable {
    case idle, testing
    case success(String)
    case failure(String)
  }

  init(profile: ConnectionProfile?, onSave: @escaping (ConnectionProfile) -> Void) {
    original = profile
    self.onSave = onSave
    _profile = State(initialValue: profile ?? ConnectionProfile(engine: .postgres))
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
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
              serverSection.frame(maxWidth: .infinity)
              safetySection.frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 16) {
              serverSection
              safetySection
            }
          }
          if !profile.engine.isFileBased {
            DisclosureGroup("SSH tunnel and encryption", isExpanded: $showsAdvanced) {
              advanced.padding(.top, 8)
            }
            .fontWeight(.medium)
          }
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
      #endif
    }
    .fileImporter(isPresented: $pickingFile, allowedContentTypes: fileTypes) { result in
      if case .success(let url) = result {
        _ = url.startAccessingSecurityScopedResource()
        profile.filePath = url.path
        if profile.name.isEmpty { profile.name = url.deletingPathExtension().lastPathComponent }
      }
    }
    .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data, .plainText, .item]) { result in
      if case .success(let url) = result { importKey(url) }
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
      recognized = text.isEmpty ? nil : nil
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
    recognized =
      next.engine.isFileBased
      ? "Recognized a \(next.engine.displayName) file."
      : "Recognized \(next.engine.displayName). Host, port, database and user are filled in below."
  }

  // MARK: Engines

  private var engineGrid: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Database").font(.callout.weight(.semibold))
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
        ForEach(EngineKind.allCases) { engine in
          let selected = profile.engine == engine
          Button {
            choose(engine)
          } label: {
            HStack(spacing: 8) {
              EngineTile(engine: engine, size: 28)
              VStack(alignment: .leading, spacing: 1) {
                Text(engine.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                Text(engine.kindLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer(minLength: 0)
            }
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
    }
  }

  private func choose(_ engine: EngineKind) {
    let old = profile.engine
    profile.engine = engine
    if profile.port == old.defaultPort || profile.port == 0 { profile.port = engine.defaultPort }
    if profile.user.isEmpty || profile.user == old.defaultUser { profile.user = engine.defaultUser }
    if !engine.supportsDirectTLS { profile.useTLS = false }
    test = .idle
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
      VStack(spacing: 0) {
        row("Name") { TextField("Name", text: $profile.name, prompt: Text(profile.displayName)) }
        if profile.engine.isFileBased {
          row("File") {
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
          }
        } else {
          row("Host") {
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
          row(databaseLabel) {
            TextField(databaseLabel, text: $profile.database, prompt: Text(profile.engine == .redis ? "0" : "optional"))
          }
          row("User") {
            TextField("User", text: $profile.user, prompt: Text(profile.engine == .redis || profile.engine == .mongodb ? "optional" : ""))
              #if os(iOS)
                .textInputAutocapitalization(.never)
              #endif
          }
          row("Password", last: profile.engine != .mongodb) {
            HStack {
              SecureField("Password", text: $password)
              if profile.savePassword {
                Label("Keychain", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          if profile.engine == .mongodb {
            row("Auth database", last: true) {
              TextField("Auth database", text: Binding(get: { profile.options["authSource"] ?? "" }, set: { profile.options["authSource"] = $0.isEmpty ? nil : $0 }), prompt: Text("admin"))
            }
          }
        }
      }
      .labelsHidden()
      .textFieldStyle(.plain)
      .groupBox()
      if !profile.engine.isFileBased {
        Toggle("Save password in the Keychain", isOn: $profile.savePassword).font(.callout)
      }
    }
  }

  private func row<Content: View>(_ label: String, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
        content()
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 38)
      if !last { Divider().padding(.leading, 12) }
    }
  }

  // MARK: Safety

  private var safetySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Safety").font(.callout.weight(.semibold))
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Text("Color").foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
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
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        Divider().padding(.leading, 12)
        SwitchRow("Production", caption: "Shows a red tag. Every change is reviewed before it's saved.", isOn: $profile.isProduction)
        .padding(12)
        Divider().padding(.leading, 12)
        SwitchRow("Read only", caption: "Look, but never change anything.", isOn: $profile.isReadOnly)
        .padding(12)
      }
      .groupBox()
    }
  }

  // MARK: SSH and TLS

  private var advanced: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(spacing: 0) {
        SwitchRow("Connect through SSH", caption: "Database Pro logs in to the SSH server and forwards the connection to \(profile.host.isEmpty ? "the database" : profile.host):\(profile.port.formatted(.number.grouping(.never))).", isOn: $profile.ssh.enabled)
        .padding(12)
        if profile.ssh.enabled {
          Divider().padding(.leading, 12)
          row("SSH server") {
            HStack {
              TextField("SSH server", text: $profile.ssh.host, prompt: Text("bastion.example.com"))
              Text("Port").foregroundStyle(.secondary)
              TextField("Port", value: $profile.ssh.port, format: .number.grouping(.never)).frame(width: 52).multilineTextAlignment(.trailing)
            }
          }
          row("SSH user") { TextField("SSH user", text: $profile.ssh.user) }
          row("Sign in with") {
            Picker("Sign in with", selection: $profile.ssh.auth) {
              Text("Key").tag(SSHAuthMethod.key)
              Text("Password").tag(SSHAuthMethod.password)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
          }
          if profile.ssh.auth == .key {
            keyPicker
          } else {
            row("SSH password", last: true) { SecureField("SSH password", text: $sshPassword) }
          }
          if let fingerprint = profile.ssh.hostKeyFingerprint {
            Divider().padding(.leading, 12)
            HStack {
              VStack(alignment: .leading, spacing: 1) {
                Text("Remembered host key").font(.caption).foregroundStyle(.secondary)
                Text(fingerprint).font(.codeSmall).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
              }
              Spacer()
              Button("Forget") { profile.ssh.hostKeyFingerprint = nil }
            }
            .padding(12)
          }
        }
      }
      .labelsHidden()
      .textFieldStyle(.plain)
      .groupBox()

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
          Label("\(profile.engine.displayName) encrypts after the connection starts. Use an SSH tunnel to encrypt it end to end.", systemImage: "lock.shield")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
        }
      }
      .groupBox()
    }
  }

  private var keyPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider().padding(.leading, 12)
      HStack {
        Picker("Key", selection: $profile.ssh.keyID) {
          Text("Choose a key").tag(UUID?.none)
          ForEach(app.keys.keys) { key in
            Text("\(key.name) (\(key.kind.label))").tag(UUID?.some(key.id))
          }
        }
        .labelsHidden()
        Spacer()
        Menu("Add Key") {
          Button("Create New Key") {
            if let key = try? app.keys.generate(name: "Database Pro on \(deviceName)") {
              app.keysVersion += 1
              profile.ssh.keyID = key.id
            }
          }
          Button("Import Private Key…") { importingKey = true }
        }
        .fixedSize()
      }
      .padding(.horizontal, 12)
      if let id = profile.ssh.keyID, let stored = app.keys.keys.first(where: { $0.id == id }) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Add this line to ~/.ssh/authorized_keys on the SSH server:").font(.caption).foregroundStyle(.secondary)
          HStack(alignment: .top) {
            Text(stored.publicKeyLine)
              .font(.codeSmall)
              .textSelection(.enabled)
              .lineLimit(3)
            Spacer()
            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(stored.publicKeyLine) }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help("Copy public key")
          }
          .padding(8)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 12)
      }
      if let keyError {
        Text(keyError).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
      }
    }
    .padding(.bottom, 12)
    .id(app.keysVersion)
  }

  private var deviceName: String {
    #if os(macOS)
      Host.current().localizedName ?? "Mac"
    #else
      UIDevice.current.name
    #endif
  }

  private func importKey(_ url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      let text = try String(contentsOf: url, encoding: .utf8)
      let key = try SSHKey(importing: text)
      let stored = try app.keys.add(key, name: key.comment.isEmpty ? url.lastPathComponent : key.comment)
      app.keysVersion += 1
      profile.ssh.keyID = stored.id
      keyError = nil
    } catch {
      keyError = FriendlyError.message(error)
    }
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
    password = app.secrets.databasePassword(for: original.id) ?? ""
    sshPassword = app.secrets.sshPassword(for: original.id) ?? ""
    showsAdvanced = original.ssh.enabled || original.useTLS
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
