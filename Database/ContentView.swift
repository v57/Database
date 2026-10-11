import MongoDB
import PostgreSQL
import Redis
import SQLite
import SwiftData
import SwiftUI

@main struct DatabaseApp: App {
#if canImport(AppKit)
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif
  private let container: ModelContainer
  private let model: DatabaseModel

  init() {
    do {
      // Explicit per-app store: unsandboxed SwiftData apps that omit a URL
      // ALL default to the same shared ~/Library/Application Support/
      // default.store — Player uses that file too, so the two apps clashed
      // ("The file default.store couldn't be opened", dropped tables, lost
      // records). Keep this app's store in its own dev.v57.db folder.
      let appSupport = URL.applicationSupportDirectory.appendingPathComponent(
        "dev.v57.db", isDirectory: true)
      try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
      let storeURL = appSupport.appendingPathComponent("Database.store")
      let config = ModelConfiguration("Database", url: storeURL)
      container = try ModelContainer(
        for: ConnectionRecord.self, DatabaseOpenRecord.self, CollectionOpenRecord.self,
        configurations: config)
    } catch { fatalError("Failed to create SwiftData container: \(error)") }
    // The model shares the container's main context so last-opened
    // history persists and stays in sync with the views' @Query fetches.
    let appModel = DatabaseModel(modelContext: container.mainContext)
    model = appModel
#if canImport(AppKit)
    // Finder "Open With…" / dock drops route through the app delegate.
    appDelegate.model = appModel
#endif
  }

  var body: some Scene {
    WindowGroup { ContentView(model: model, container: container) }.commands {
      NewConnectionCommands()
    }
  }
}

/// File menu: "New Connection…" (⌘N) replaces New Window. Every window shares
/// the one DatabaseModel, so an extra window would only mirror the same state;
/// adding a connection is the useful "new" action.
private struct NewConnectionCommands: Commands {
  /// Published by the key window's sidebar; nil when no window can take it.
  @FocusedBinding(\.isAddingConnection) private var isAddingConnection

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Connection…") { isAddingConnection = true }.keyboardShortcut("n").disabled(
        isAddingConnection == nil)
    }
  }
}

extension FocusedValues {
  /// The key window's "Add Connection" sheet flag, so the menu command opens
  /// the same sheet as the sidebar's + button (without routing through the
  /// shared DatabaseModel, which would open it in every window).
  @Entry var isAddingConnection: Binding<Bool>?
}

struct ContentView: View {
  private let container: ModelContainer
  private let model: DatabaseModel

  init(model: DatabaseModel, container: ModelContainer) {
    self.container = container
    self.model = model
  }

  /// Sidebar title: the active connection name, or the app name when idle.
  private var title: String { model.connectionName ?? "Database" }

  /// Detail title: the open collection/table/key, so the pane says what it
  /// shows; the connection moves into the subtitle.
  private var detailTitle: String { model.selectedCollection ?? title }

  /// Which column a compact (iPhone) split view shows. Selecting a connection
  /// or database in the sidebar List would otherwise push the empty
  /// "No Collection Selected" pane; only a collection opens the detail.
  @State private var compactColumn = NavigationSplitViewColumn.sidebar

  var body: some View {
    // Two-pane layout: sidebar (connections) + merged item-list/preview.
    // `detail:` is the main pane in a 2-column NavigationSplitView.
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      ConnectionsSidebarView().navigationTitle(title)
    } detail: {
      DocumentsView().navigationTitle(detailTitle)
    }.environment(model).modelContainer(container)
      .onChange(of: compactColumn) { _, column in
        if column == .detail && model.selectedCollection == nil { compactColumn = .sidebar }
      }
      .onChange(of: model.selectedCollection) { _, collection in
        compactColumn = collection == nil ? .sidebar : .detail
      }
  }
}
