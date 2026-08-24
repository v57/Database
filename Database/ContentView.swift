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
      container = try ModelContainer(
        for: ConnectionRecord.self, DatabaseOpenRecord.self, CollectionOpenRecord.self)
    } catch { fatalError("Failed to create SwiftData container: \(error)") }
    // The model shares the container's main context so last-opened
    // history persists and stays in sync with the views' @Query fetches.
    let appModel = DatabaseModel(modelContext: container.mainContext)
    model = appModel
    // Finder "Open With…" / dock drops route through the app delegate.
    appDelegate.model = appModel
  }

  var body: some Scene {
    WindowGroup { ContentView(model: model, container: container) }
  }
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
    }.navigationTitle(title)
      .environment(model).modelContainer(container)
  }
}