import DatabaseKit
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// New and Edit SSH Configuration: a shared SSH host (Shell lists it too) that connections tunnel through.
struct SSHHostSheet: View {
  let original: VaultHost
  let isNew: Bool
  /// Remembered key of the server, if any app accepted one.
  let fingerprint: String?
  let onSave: (VaultHost, String) -> Void
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss

  @State private var host: VaultHost
  @State private var auth: SSHAuthMethod
  @State private var keyID: UUID?
  @State private var password: String
  @State private var importingKey = false
  @State private var keyError: String?

  init(host: VaultHost, isNew: Bool, fingerprint: String?, onSave: @escaping (VaultHost, String) -> Void) {
    original = host
    self.isNew = isNew
    self.fingerprint = fingerprint
    self.onSave = onSave
    _host = State(initialValue: host)
    _auth = State(initialValue: host.auth == .password ? .password : .key)
    _keyID = State(initialValue: host.auth == .importedKey ? host.keyID.flatMap(UUID.init(uuidString:)) : nil)
    _password = State(initialValue: isNew ? "" : host.password ?? "")
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text(isNew ? "New SSH Configuration" : "Edit SSH Configuration").font(.title2.bold())
            Text("Database logs in to this server and reaches the database from there. Shell and the other v57 apps list it too.")
              .foregroundStyle(.secondary)
          }
          VStack(spacing: 0) {
            FormRow("Name") { TextField("Name", text: $host.name, prompt: Text(host.hostname.isEmpty ? "optional" : host.hostname)) }
            FormRow("Server") {
              HStack {
                TextField("Server", text: $host.hostname, prompt: Text("bastion.example.com"))
                  #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                  #endif
                Text("Port").foregroundStyle(.secondary)
                TextField("Port", value: $host.port, format: .number.grouping(.never)).frame(width: 52).multilineTextAlignment(.trailing)
              }
            }
            FormRow("User") {
              TextField("User", text: $host.user, prompt: Text("root"))
                #if os(iOS)
                  .textInputAutocapitalization(.never)
                #endif
            }
            FormRow("Sign in with", last: true) {
              Picker("Sign in with", selection: $auth) {
                Text("Key").tag(SSHAuthMethod.key)
                Text("Password").tag(SSHAuthMethod.password)
              }
              .pickerStyle(.segmented)
              .fixedSize()
              Spacer()
            }
          }
          .labelsHidden()
          .textFieldStyle(.plain)
          .groupBox()

          if auth == .key {
            keyPicker
          } else {
            VStack(alignment: .leading, spacing: 8) {
              VStack(spacing: 0) {
                FormRow("Password", last: true) { SecureField("Password", text: $password) }
              }
              .labelsHidden()
              .textFieldStyle(.plain)
              .groupBox()
              Toggle("Save password in the Keychain", isOn: $host.savePassword).font(.callout)
            }
          }

          if let fingerprint {
            VStack(alignment: .leading, spacing: 1) {
              Text("Remembered host key").font(.caption).foregroundStyle(.secondary)
              Text(fingerprint).font(.codeSmall).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
          }
        }
        .padding(24)
      }
      Divider()
      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(isNew ? "Add" : "Save") { save() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(host.hostname.trimmingCharacters(in: .whitespaces).isEmpty || host.user.isEmpty || !(1...65535).contains(host.port))
      }
      .padding(16)
    }
    .frame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 500)
    .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data, .plainText, .item]) { result in
      if case .success(let url) = result { importKey(url) }
    }
  }

  private var keyPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Picker("Key", selection: $keyID) {
          Text("This device’s key (Secure Enclave)").tag(UUID?.none)
          ForEach(app.keys.keys) { key in
            Text("\(key.name) (\(key.kind.label))").tag(UUID?.some(key.id))
          }
        }
        .labelsHidden()
        Spacer()
        Menu("Add Key") {
          Button("Create New Key") {
            if let key = try? app.keys.generate(name: "Database on \(SharedConnections.deviceName)") {
              app.keysVersion += 1
              keyID = key.id
            }
          }
          Button("Import Private Key…") { importingKey = true }
        }
        .fixedSize()
      }
      if let line = SSHHostSheet.publicKeyLine(keyID, keys: app.keys) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Add this line to ~/.ssh/authorized_keys on the SSH server:").font(.caption).foregroundStyle(.secondary)
          HStack(alignment: .top) {
            Text(line)
              .font(.codeSmall)
              .textSelection(.enabled)
              .lineLimit(3)
            Spacer()
            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(line) }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help("Copy public key")
          }
          .padding(8)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      if let keyError {
        Text(keyError).font(.caption).foregroundStyle(.red)
      }
    }
    .id(app.keysVersion)
  }

  /// The public key line of a key: an imported one, or (nil) this device's Secure Enclave key, which Shell
  /// and Database use too (once in `authorized_keys` serves every v57 app).
  static func publicKeyLine(_ keyID: UUID?, keys: SSHKeyStore) -> String? {
    if let keyID { return keys.keys.first(where: { $0.id == keyID })?.publicKeyLine }
    return (try? SharedConnections.deviceKey())?.authorizedKeyLine
  }

  private func save() {
    var saved = host
    saved.hostname = saved.hostname.trimmingCharacters(in: .whitespaces)
    switch auth {
    case .password:
      saved.auth = .password
      saved.keyID = nil
    case .key:
      saved.auth = keyID == nil ? .deviceKey : .importedKey
      saved.keyID = keyID?.uuidString
    }
    onSave(saved, auth == .password ? password : "")
    dismiss()
  }

  private func importKey(_ url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      let text = try String(contentsOf: url, encoding: .utf8)
      let key = try SSHKey(importing: text)
      let stored = try app.keys.add(key, name: key.comment.isEmpty ? url.lastPathComponent : key.comment)
      app.keysVersion += 1
      keyID = stored.id
      keyError = nil
    } catch {
      keyError = FriendlyError.message(error)
    }
  }
}

/// A label on the left and a field on the right, with a divider below unless it's the last row of its group.
struct FormRow<Content: View>: View {
  let label: String
  var last = false
  @ViewBuilder var content: Content

  init(_ label: String, last: Bool = false, @ViewBuilder content: () -> Content) {
    self.label = label
    self.last = last
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
        content
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 38)
      if !last { Divider().padding(.leading, 12) }
    }
  }
}

/// A selectable tile with an icon, a title and a subtitle: the New Connection sheet's database and location pickers.
struct ChoiceTile<Icon: View>: View {
  let title: String
  let subtitle: String
  var selected = false
  let action: () -> Void
  @ViewBuilder var icon: Icon

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        icon
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.callout.weight(.semibold)).lineLimit(1)
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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

/// A symbol in the same rounded tile as `EngineTile`.
struct SymbolTile: View {
  let systemName: String
  var tint: Color = .secondary
  var size: CGFloat = 28

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: size * 0.48, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
      .accessibilityHidden(true)
  }
}
