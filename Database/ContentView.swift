import MongoDB
import PostgreSQL
import Redis
import SwiftData
import SwiftUI

@main struct DatabaseApp: App {

  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

struct ContentView: View {
  private let container: ModelContainer
  @State private var model: DatabaseModel

  init() {
    do {
      container = try ModelContainer(
        for: ConnectionRecord.self, DatabaseOpenRecord.self, CollectionOpenRecord.self)
    } catch { fatalError("Failed to create SwiftData container: \(error)") }
    // The model shares the container's main context so last-opened
    // history persists and stays in sync with the views' @Query fetches.
    _model = State(initialValue: DatabaseModel(modelContext: container.mainContext))
  }

  /// Title shows the active connection name, or the engine hint when idle.
  private var title: String {
    if let alternateSession = model.alternateSession {
      switch alternateSession {
      case .postgresql(let c): return c.config.name
      case .redis(let c): return c.config.name
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
