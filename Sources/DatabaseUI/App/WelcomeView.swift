import ComponentKit
import DatabaseKit
import SwiftUI
import UniformTypeIdentifiers

/// The main screen while no connection is selected: the kit's welcome, with New Connection, Open File and the recent
/// connections. Files dropped on it open as connections.
struct WelcomeView: View {
  @Bindable var window: WindowModel
  @Environment(DatabaseModel.self) private var app
  @State private var openingFile = false

  /// The connections opened last, or the first saved ones before any was opened.
  private var recent: [ConnectionProfile] {
    let used = app.profiles.filter { $0.lastUsed != nil }
      .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    return Array((used.isEmpty ? app.profiles : used).prefix(8))
  }

  var body: some View {
    KitWelcome(
      appName: "Database",
      emptyTitle: "No Connections Yet", emptyMessage: "Connections you add appear here.",
      onDrop: open
    ) {
      WelcomeAction(
        "New Connection…", detail: "PostgreSQL, MySQL, SQL Server, MongoDB, Redis, Cassandra and more",
        systemImage: "plus"
      ) {
        window.showsNewConnection = true
      }
      WelcomeAction("Open a File…", detail: "SQLite, DuckDB, Parquet or CSV", systemImage: "doc") {
        openingFile = true
      }
    } recents: {
      ForEach(recent) { profile in
        RecentItem(
          profile.displayName, subtitle: profile.subtitle,
          date: profile.lastUsed?.formatted(.relative(presentation: .named)),
          status: profile.isProduction ? "Production" : nil, statusHue: .red, id: profile.id.uuidString
        ) {
          window.connect(profile.id)
        }
      }
    }
    .listTitle(app.profiles.contains { $0.lastUsed != nil } ? "Recent" : "Connections")
    .kitPane(.content)
    .fileImporter(isPresented: $openingFile, allowedContentTypes: fileTypes, allowsMultipleSelection: true) { result in
      if case .success(let urls) = result {
        for url in urls { _ = url.startAccessingSecurityScopedResource() }
        _ = open(urls)
      }
    }
    .kitToolbar("Database") {
      Text("Database").kitFont(.headline)
    } tools: {
    }
  }

  private func open(_ urls: [URL]) -> Bool {
    var opened = false
    for url in urls { if let profile = app.addFile(url) { window.connect(profile.id); opened = true } }
    return opened
  }

  private var fileTypes: [UTType] {
    let extensions = EngineKind.available.flatMap(\.fileExtensions)
    return [.data] + extensions.compactMap { UTType(filenameExtension: $0) }
  }
}
