import ComponentKit
import DatabaseKit
import SwiftUI
import UniformTypeIdentifiers
import VaultUI

/// Settings: how much the browser loads, the DuckDB download, SSH keys, and the v57 accounts.
public struct SettingsView: View {
  @AppStorage("settings.pane") private var pane = "General"

  public init() {}

  public var body: some View {
    KitSettings(selection: $pane) {
      SettingsPane("General", systemImage: "gearshape") { GeneralSettings() }
      SettingsPane("SSH Keys", systemImage: "key", hue: .brown) { SSHKeysView() }
      if showsAccounts {
        SettingsPane("Accounts", systemImage: "person.2", hue: .indigo, section: "v57") { VaultAccountsSettings() }
      }
    }
    .frame(width: 640, height: 460)
  }

  /// A `--data-dir` run keeps to its scratch vault, so it shows no accounts (they live in the real one).
  private var showsAccounts: Bool {
    #if DEBUG
      LaunchOptions.value("--data-dir") == nil
    #else
      true
    #endif
  }
}

struct GeneralSettings: View {
  @AppStorage("pageSize") private var pageSize = 50

  var body: some View {
    FormCard(footer: "Production connections always show their changes for review before saving.") {
      FormRow("Items per page", help: "How many rows, documents or keys a page loads", systemImage: "list.number", hue: .gray) {
        KitPicker("Items per page", selection: $pageSize, options: [25, 50, 100, 200, 500].map { ("\($0)", $0) })
      }
    }
    FormCard("DuckDB") {
      DuckDBInstallRow(showsRemove: true)
        .padding(10)
    }
  }
}

/// The SSH keys Database keeps in the Keychain.
struct SSHKeysView: View {
  @Environment(DatabaseModel.self) private var app
  @State private var importing = false
  @State private var error: String?
  @State private var deleting: StoredSSHKey?

  var body: some View {
    FormCard(footer: "Keys are stored in your Keychain. Give the public key to the SSH server's administrator, or add it to ~/.ssh/authorized_keys yourself.") {
      ForEach(app.keys.keys) { key in
        FormRow(key.name, help: "\(key.kind.label) · \(key.fingerprint)", systemImage: "key", hue: .brown) {
          HStack(spacing: 2) {
            Button("Copy Public Key", systemImage: "doc.on.doc") { KitPasteboard.copy(key.publicKeyLine) }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = key }
          }
          .buttonStyle(.kitIcon)
        }
      }
      if app.keys.keys.isEmpty {
        FormRow("No keys yet", help: "Create one, or import a private key you have", systemImage: "key", hue: .gray)
      }
    }
    .id(app.keysVersion)
    if let error { Banner(error, systemImage: "exclamationmark.triangle", hue: .red) }
    HStack {
      Button("Create New Key") {
        do {
          _ = try app.keys.generate(name: "Database key \(app.keys.keys.count + 1)")
          app.keysVersion += 1
        } catch {
          self.error = FriendlyError.message(error)
        }
      }
      .buttonStyle(.kit)
      Button("Import Private Key…") { importing = true }
        .buttonStyle(.kit)
    }
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
    .kitConfirmation(
      "Delete \(deleting?.name ?? "")?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      message: "Connections using this key won't be able to log in until you choose another.", systemImage: "trash",
      confirm: "Delete Key"
    ) {
      if let deleting { try? app.keys.remove(deleting.id) }
      app.keysVersion += 1
      deleting = nil
    }
  }
}
