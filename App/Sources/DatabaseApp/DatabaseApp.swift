import ComponentKit
import DatabaseKit
import DatabaseUI
import SwiftUI
import VaultKit
import VaultUI

#if os(macOS) || os(Linux)
  import UpdateKit
#endif

public struct DatabaseApp: App {
  @State private var app: DatabaseModel

  #if os(macOS) || os(Linux)
    /// Updates for the Mac app from GitHub Releases (Database.zip; Database-Linux-<arch>.tar.gz on Linux):
    /// checked daily once the user turns on automatic checks (never before), installed in place with a
    /// relaunch. The iOS app updates through the App Store.
    private let updater = AppUpdater(github: "v57/Database", assetName: "Database.zip", accent: .databaseAccent)
  #endif

  public init() {
    let app = DatabaseModel.live()
    _app = State(initialValue: app)
    #if DEBUG && os(macOS)
      DebugPresenter.prepare { ContentView().environment(app).kitToasts().componentKit(accent: .databaseAccent) }
    #endif
    #if os(macOS) || os(Linux)
      updater.start()
    #endif
  }

  public var body: some Scene {
    // A window's value is the account Open in a New Window asked for; the window keeps it in its scene storage.
    WindowGroup(for: String.self) { $account in
      MainWindow(openedAccount: $account)
        .environment(app)
        .kitToasts()
        .componentKit(accent: .databaseAccent)
    }
    .defaultSize(width: 1440, height: 900)
    .commands {
      DatabaseCommands()
      #if os(macOS) || os(Linux)
        UpdaterCommands(updater: updater)
      #endif
    }
    #if os(macOS) || os(Linux)
      Settings {
        SettingsView()
          .environment(app)
          .componentKit(accent: .databaseAccent)
      }
      #if os(macOS)
        // The kit's settings run up under the window's buttons; Linux keeps its title bar.
        .windowStyle(.hiddenTitleBar)
      #endif
    #endif
  }
}

/// A window on one account (`VaultAccountScope`, ../Ideas/Accounts.md): Personal's model, or the account's
/// (`DatabaseModel.model(for:)`, shared by the account's windows). The picker heads the sidebar.
private struct MainWindow: View {
  /// The account a new window was opened on, until the window takes it.
  @Binding var openedAccount: String?
  @Environment(DatabaseModel.self) private var app
  @SceneStorage("vault.account") private var accountID = VaultAccount.personal.id
  #if os(macOS) || os(Linux)
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
  #endif

  var body: some View {
    #if DEBUG
      // A `--data-dir` run keeps to its scratch vault: no accounts, so the real vault isn't opened.
      Group {
        if LaunchOptions.value("--data-dir") != nil { ContentView() } else { scoped }
      }
      #if os(macOS) || os(Linux)
        // `--settings`: the Settings window too, for screenshots.
        .onAppear { if LaunchOptions.flag("--settings") { openSettings() } }
      #endif
    #else
      scoped
    #endif
  }

  private var scoped: some View {
    VaultAccountScope(
      selection: Binding(get: { openedAccount ?? accountID }, set: { accountID = $0; openedAccount = nil }),
      manage: manage, openInNewWindow: openInNewWindow
    ) { vault in
      ContentView().environment(app.model(for: vault))
    }
    .onAppear {
      if let openedAccount {
        accountID = openedAccount
        self.openedAccount = nil
      }
    }
  }

  /// Settings ▸ Accounts (the Settings window on the Mac and Linux; iPhone and iPad have none).
  private var manage: (@MainActor @Sendable () -> Void)? {
    #if os(macOS) || os(Linux)
      return { [openSettings] in
        UserDefaults.standard.set("Accounts", forKey: "settings.pane")
        openSettings()
      }
    #else
      return nil
    #endif
  }

  private var openInNewWindow: (@MainActor @Sendable (String) -> Void)? {
    #if os(macOS) || os(Linux)
      return { [openWindow] id in openWindow(value: id) }
    #else
      return nil
    #endif
  }
}
