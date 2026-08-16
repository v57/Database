import SwiftUI
import SwiftData
import MongoDB

@main struct DatabaseApp: App {
    @State private var model = DatabaseModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .modelContainer(for: ConnectionRecord.self)
    }
}

struct ContentView: View {
    @Environment(DatabaseModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ConnectionsSidebarView()
        } content: {
            CollectionsView()
        } detail: {
            DocumentsView()
        }
        .navigationTitle(model.session?.config.name ?? "Database Client")
    }
}
