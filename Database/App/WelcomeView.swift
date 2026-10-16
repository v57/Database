import ComponentKit
import DatabaseKit
import SwiftUI

/// First screen: the kit's welcome, with New Connection and the recent connections.
struct WelcomeView: View {
  @Bindable var window: WindowModel
  @Environment(AppModel.self) private var app

  private var recent: [ConnectionProfile] {
    app.profiles.filter { $0.lastUsed != nil }.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
      .prefix(6).map { $0 }
  }

  var body: some View {
    ScrollView {
      KitWelcome(
        appName: "Database",
        emptyTitle: "No Recent Connections", emptyMessage: "Connections you open appear here.",
        onDrop: { urls in
          var opened = false
          for url in urls { if let profile = app.addFile(url) { window.connect(profile.id); opened = true } }
          return opened
        }
      ) {
        WelcomeAction(
          "New Connection…", detail: "PostgreSQL, MySQL, SQL Server, SQLite, MongoDB, Redis and more", systemImage: "plus"
        ) {
          window.showsNewConnection = true
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
      .clipShape(RoundedRectangle(cornerRadius: KitMetrics.radiusOverlay, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: KitMetrics.radiusOverlay, style: .continuous).strokeBorder(.kitSeparator)
      }
      .padding(40)
      .frame(maxWidth: .infinity)
    }
    .kitPane(.secondary)
    .navigationTitle("Database")
  }
}
