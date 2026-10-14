import DatabaseProKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings: SSH keys, the DuckDB download, and how much the browser loads.
struct SettingsView: View {
  var body: some View {
    TabView {
      SSHKeysView()
        .tabItem { Label("SSH Keys", systemImage: "key") }
      GeneralSettings()
        .tabItem { Label("General", systemImage: "gearshape") }
    }
    .frame(width: 560, height: 420)
  }
}

struct GeneralSettings: View {
  @AppStorage("pageSize") private var pageSize = 50

  var body: some View {
    Form {
      Picker("Items per page", selection: $pageSize) {
        ForEach([25, 50, 100, 200, 500], id: \.self) { Text("\($0)").tag($0) }
      }
      Text("Production connections always show their changes for review before saving.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Section("DuckDB") {
        DuckDBInstallRow(showsRemove: true)
      }
    }
    .formStyle(.grouped)
  }
}

/// The SSH keys Database Pro keeps in the Keychain.
struct SSHKeysView: View {
  @Environment(AppModel.self) private var app
  @State private var importing = false
  @State private var error: String?
  @State private var deleting: StoredSSHKey?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Keys are stored in your Keychain. Give the public key to the SSH server's administrator, or add it to ~/.ssh/authorized_keys yourself.")
        .font(.callout)
        .foregroundStyle(.secondary)
      List {
        ForEach(app.keys.keys) { key in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Image(systemName: "key.fill").foregroundStyle(.secondary)
              Text(key.name).fontWeight(.medium)
              Text(key.kind.label).font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button("Copy Public Key", systemImage: "doc.on.doc") { Clipboard.copy(key.publicKeyLine) }
                .buttonStyle(.borderless)
              Button("Delete", systemImage: "trash", role: .destructive) { deleting = key }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            Text(key.fingerprint).font(.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
          }
          .padding(.vertical, 4)
        }
        if app.keys.keys.isEmpty {
          Text("No keys yet.").foregroundStyle(.secondary)
        }
      }
      .id(app.keysVersion)
      if let error { Text(error).foregroundStyle(.red).font(.caption) }
      HStack {
        Button("Create New Key") {
          do {
            _ = try app.keys.generate(name: "Database Pro key \(app.keys.keys.count + 1)")
            app.keysVersion += 1
          } catch {
            self.error = FriendlyError.message(error)
          }
        }
        Button("Import Private Key…") { importing = true }
      }
    }
    .padding()
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText, .item]) { result in
      guard case .success(let url) = result else { return }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        let key = try SSHKey(importing: try String(contentsOf: url, encoding: .utf8))
        _ = try app.keys.add(key, name: key.comment.isEmpty ? url.lastPathComponent : key.comment)
        app.keysVersion += 1
        error = nil
      } catch {
        self.error = FriendlyError.message(error)
      }
    }
    .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
      Button("Delete Key", role: .destructive) {
        if let deleting { try? app.keys.remove(deleting.id) }
        app.keysVersion += 1
        deleting = nil
      }
    } message: {
      Text("Connections using this key won't be able to log in until you choose another.")
    }
  }
}
