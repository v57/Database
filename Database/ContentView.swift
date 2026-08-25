import MongoDB
import PostgreSQL
import Redis
import SQLite
import SwiftData
import SwiftUI

@main struct DatabaseApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    // Finder "Open With…" / dock drops route through the app delegate.
    appDelegate.model = appModel
  }

  var body: some Scene { WindowGroup { ContentView(model: model, container: container) } }
}

struct ContentView: View {
  private let container: ModelContainer
  private let model: DatabaseModel

  init(model: DatabaseModel, container: ModelContainer) {
    self.container = container
    self.model = model
  }

  /// Title shows the active connection name, or the engine hint when idle.
  private var title: String {
    if let alternateSession = model.alternateSession {
      switch alternateSession {
      case .postgresql(let c): return c.config.name
      case .redis(let c): return c.config.name
      case .sqlite(let c): return c.config.name
      }
    }
    return model.session?.config.name ?? "Database Client"
  }

  var body: some View {
    // Two-pane layout: sidebar (connections) + merged item-list/preview.
    // `detail:` is the main pane in a 2-column NavigationSplitView.
    NavigationSplitView {
      ConnectionsSidebarView()
    } detail: {
      DocumentsView()
    }.navigationTitle(title).environment(model).modelContainer(container)
  }
}
