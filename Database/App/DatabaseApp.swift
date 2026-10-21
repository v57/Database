import ComponentKit
import DatabaseKit
import DatabaseUI
import SwiftUI

#if os(macOS)
  import UpdateKit
#endif

@main
struct DatabaseApp: App {
  @State private var app: DatabaseModel

  #if os(macOS)
    /// Updates for the Mac app from GitHub Releases (Database.zip): checked daily once the user
    /// turns on automatic checks (never before), installed in place with a relaunch. The iOS
    /// app updates through the App Store.
    private let updater = AppUpdater(github: "v57/Database", assetName: "Database.zip")
  #endif

  init() {
    let app = DatabaseModel.live()
    _app = State(initialValue: app)
    #if DEBUG && os(macOS)
      DebugPresenter.prepare { ContentView().environment(app).kitToasts().componentKit(accent: .databaseAccent) }
    #endif
    #if os(macOS)
      updater.start()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(app)
        .kitToasts()
        .componentKit(accent: .databaseAccent)
    }
    .defaultSize(width: 1440, height: 900)
    .commands {
      DatabaseCommands()
      #if os(macOS)
        UpdaterCommands(updater: updater)
      #endif
    }
    #if os(macOS)
      Settings {
        SettingsView()
          .environment(app)
          .componentKit(accent: .databaseAccent)
      }
    #endif
  }
}
