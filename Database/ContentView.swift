import SwiftUI
import SwiftData
import MongoDB

@main struct DatabaseApp: App {
    private let container: ModelContainer
    @State private var model: DatabaseModel

    init() {
        do {
            container = try ModelContainer(
                for: ConnectionRecord.self, DatabaseOpenRecord.self, CollectionOpenRecord.self
            )
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        // The model shares the container's main context so last-opened
        // history persists and stays in sync with the views' @Query fetches.
        _model = State(initialValue: DatabaseModel(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .modelContainer(container)
        }
    }
}

struct ContentView: View {
    @Environment(DatabaseModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ConnectionsSidebarView()
        } content: {
            DocumentsView()
        } detail: {
            DocumentDetailView()
        }
        .navigationTitle(model.session?.config.name ?? "Database Client")
    }
}
