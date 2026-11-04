import ComponentKit
import DatabaseKit
import SwiftUI

/// A private key file that needs its passphrase before it can be imported.
struct LockedKeyFile: Identifiable {
  let id = UUID()
  let text: String
  let fileName: String
}

/// Asks for a key file's passphrase, and stays until it opens the key or is cancelled. The sheet says what happens to
/// the key: it's kept in the Keychain without the passphrase, like every key here.
struct KeyPassphraseSheet: View {
  let file: LockedKeyFile
  let onOpen: (SSHKey) -> Void
  @Environment(\.kitDismiss) private var dismiss
  @State private var passphrase = ""
  @State private var error: String?
  @State private var isOpening = false

  var body: some View {
    KitSheet(
      title: "Enter the Key's Passphrase",
      meta: "\(file.fileName) is protected by a passphrase. Once it's open, the key is kept in your Keychain without the passphrase, so you won't be asked again.",
      systemImage: "key", hue: .brown, status: isOpening ? .working : .idle, width: 440
    ) {
      VStack(alignment: .leading, spacing: 8) {
        SecureField("Passphrase", text: $passphrase)
          .kitField()
          .onSubmit(open)
        if let error { Banner(error, systemImage: "exclamationmark.triangle", hue: .red) }
      }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Import") { open() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(passphrase.isEmpty || isOpening)
    }
  }

  private func open() {
    guard !passphrase.isEmpty, !isOpening else { return }
    isOpening = true
    error = nil
    let text = file.text
    let passphrase = passphrase
    Task {
      // bcrypt_pbkdf is slow on purpose.
      let result = await Task.detached { Result { try SSHKey(importing: text, passphrase: passphrase) } }.value
      isOpening = false
      switch result {
      case .success(let key):
        onOpen(key)
        dismiss()
      case .failure(let failure):
        error = FriendlyError.message(failure)
      }
    }
  }
}
