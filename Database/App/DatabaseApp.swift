import ComponentKit
import DatabaseKit
import SwiftUI

#if os(macOS)
  import UpdateKit
#endif

@main
struct DatabaseApp: App {
  @State private var app: AppModel

  #if os(macOS)
    /// Updates for the Mac app from GitHub Releases (Database.zip): checked daily once the user
    /// turns on automatic checks (never before), installed in place with a relaunch. The iOS
    /// app updates through the App Store.
    private let updater = AppUpdater(github: "v57/Database", assetName: "Database.zip")
  #endif

  init() {
    let app = AppModel.live()
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
      AppCommands()
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

/// Menu commands; each acts on the key window's model.
struct AppCommands: Commands {
  @FocusedValue(\.window) private var window

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Connection…") { window?.showsNewConnection = true }
        .keyboardShortcut("n")
        .disabled(window == nil)
      Button("New Query") { window?.newQuery() }
        .keyboardShortcut("t")
        .disabled(window?.currentConnectionID == nil)
    }
    CommandGroup(after: .undoRedo) {
      Button("Undo Last Save") { Task { await window?.browser?.undo() } }
        .keyboardShortcut("z", modifiers: [.command, .shift, .option])
        .disabled(window?.browser?.canUndo != true)
    }
    CommandMenu("Data") {
      Button("Refresh") { Task { await window?.refresh() } }
        .keyboardShortcut("r")
      Button("Run") { Task { await window?.run() } }
        .keyboardShortcut(.return)
      Divider()
      Button(window?.browser?.showsQueryEditor == true ? "Hide Query Editor" : "Show Query Editor") {
        window?.browser?.showsQueryEditor.toggle()
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(window?.browser == nil)
      Button("Review Changes…") { window?.browser?.showsReview = true }
        .keyboardShortcut("s")
        .disabled(window?.browser?.pending.isEmpty != false)
      Divider()
      Button("Show Inspector") { window?.showsInspector.toggle() }
        .keyboardShortcut("i", modifiers: [.command, .option])
    }
  }
}

extension Color {
  /// Database's accent (#0066cc), set once on each scene's root.
  static let databaseAccent = Color(.sRGB, red: 0, green: 0.4, blue: 0.8)
}

extension FocusedValues {
  @Entry var window: WindowModel?
}
