import ComponentKit
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
  @Environment(DatabaseModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss

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
    KitSheet(
      title: isNew ? "New SSH Configuration" : "Edit SSH Configuration",
      meta: "Database logs in to this server and reaches the database from there. Shell and the other v57 apps list it too.",
      systemImage: "server.rack", hue: .teal, width: 540
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          FormCard {
            FormRow("Name", systemImage: "character.cursor.ibeam", hue: .gray,
              field: TextField("Name", text: $host.name, prompt: Text(host.hostname.isEmpty ? "optional" : host.hostname)))
            FormRow("Server", systemImage: "network", field: serverField)
            FormRow("Port", systemImage: "number", hue: .gray) {
              TextField("Port", value: $host.port, format: .number.grouping(.never))
                .kitField(mono: true)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            }
            FormRow("User", systemImage: "person", hue: .gray, field: userField)
            FormRow("Sign in with", systemImage: "key", hue: .brown) {
              KitSegmented(selection: $auth, options: [("Key", SSHAuthMethod.key), ("Password", SSHAuthMethod.password)])
            }
          }
          if auth == .key {
            keyPicker
          } else {
            VStack(alignment: .leading, spacing: 6) {
              SecureField("Password", text: $password).kitField()
              Toggle("Save password in the Keychain", isOn: $host.savePassword)
                .toggleStyle(.kitCheckbox)
                .padding(.horizontal, 4)
            }
          }
          if let fingerprint {
            FormCard {
              FormRow("Remembered host key", help: fingerprint, systemImage: "checkmark.shield", hue: .green)
            }
          }
        }
        .padding(.vertical, 4)
      }
      .frame(minHeight: 320, idealHeight: 420)
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(isNew ? "Add" : "Save") { save() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(host.hostname.trimmingCharacters(in: .whitespaces).isEmpty || host.user.isEmpty || !(1...65535).contains(host.port))
    }
    .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data, .plainText, .item]) { result in
      if case .success(let url) = result { importKey(url) }
    }
  }

  private var serverField: some View {
    TextField("Server", text: $host.hostname, prompt: Text("bastion.example.com"))
      #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
      #endif
  }

  private var userField: some View {
    TextField("User", text: $host.user, prompt: Text("root"))
      #if os(iOS)
        .textInputAutocapitalization(.never)
      #endif
  }

  private var keyPicker: some View {
    FormCard {
      FormRow("Key", help: keyID == nil ? "In this device's Secure Enclave" : nil, systemImage: "key", hue: .brown) {
        HStack(spacing: 6) {
          KitPicker(
            "Key", selection: $keyID,
            options: [("This device’s key", UUID?.none)] + app.keys.keys.map { ("\($0.name) (\($0.kind.label))", UUID?.some($0.id)) })
          KitMenuButton("Add Key") {
            Button("Create New Key", systemImage: "key") {
              if let key = try? app.keys.generate(name: "Database on \(SharedConnections.deviceName)") {
                app.keysVersion += 1
                keyID = key.id
              }
            }
            Button("Import Private Key…", systemImage: "square.and.arrow.down") { importingKey = true }
          }
          .controlSize(.small)
        }
      }
      if let line = SSHHostSheet.publicKeyLine(keyID, keys: app.keys) {
        FormRow("Public key", help: "Add this line to ~/.ssh/authorized_keys on the SSH server", systemImage: "doc.on.doc", hue: .gray) {
          Button("Copy") { KitPasteboard.copy(line) }.buttonStyle(.kit).controlSize(.small)
        }
      }
      if let keyError {
        FormRow("Couldn't import the key", systemImage: "exclamationmark.triangle", hue: .red, error: keyError)
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

