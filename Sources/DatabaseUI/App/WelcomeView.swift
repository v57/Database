import ComponentKit
import DatabaseKit
import SwiftUI

/// First screen: the app's icon and what it opens, New Connection, and the recent connections as cards. Files
/// dropped on it open as connections.
struct WelcomeView: View {
  @Bindable var window: WindowModel
  @Environment(DatabaseModel.self) private var app
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var isDropTargeted = false

  /// The connections opened last, or the first saved ones before any was opened.
  private var recent: [ConnectionProfile] {
    let used = app.profiles.filter { $0.lastUsed != nil }
      .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    return Array((used.isEmpty ? app.profiles : used).prefix(6))
  }

  private var hasRecents: Bool { app.profiles.contains { $0.lastUsed != nil } }

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        VStack(spacing: 10) {
          KitAppIcon(size: 72)
          Text("Database").kitFont(.largeTitle)
          Text(
            "PostgreSQL, MySQL, MariaDB, SQL Server, SQLite, DuckDB, MongoDB, Redis, Cassandra and ScyllaDB — in one window."
          )
          .foregroundStyle(.kitSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 480)
        }
        Button("New Connection", systemImage: "plus") { window.showsNewConnection = true }
          .buttonStyle(.kitPrimary)
          .controlSize(.large)
        if !recent.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(hasRecents ? "Recent" : "Connections").kitFont(.headline)
            LazyVGrid(columns: columns, spacing: 10) {
              ForEach(recent) { profile in
                RecentConnectionCard(profile: profile) { window.connect(profile.id) }
              }
            }
          }
          .frame(maxWidth: 760)
        }
        Text("Tip: drop a .sqlite, .duckdb, .parquet or .csv file on the window to open it.")
          .kitFont(.caption)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, sizeClass == .compact ? 16 : 40)
      .padding(.top, sizeClass == .compact ? 32 : 64)
      .padding(.bottom, 40)
      .frame(maxWidth: .infinity)
    }
    .kitPane(.content)
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous)
          .strokeBorder(Hue.accent.fill, lineWidth: 2)
          .padding(KitMetrics.gutter)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      var opened = false
      for url in urls { if let profile = app.addFile(url) { window.connect(profile.id); opened = true } }
      return opened
    } isTargeted: { isDropTargeted = $0 }
    .navigationTitle("Database")
  }

  private var columns: [GridItem] {
    sizeClass == .compact
      ? [GridItem(.flexible())]
      : Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
  }
}

/// A recent connection as a card that lights under the pointer: its engine tile, name and server, Production.
private struct RecentConnectionCard: View {
  let profile: ConnectionProfile
  let open: () -> Void

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous)
    Button(action: open) {
      HStack(spacing: 10) {
        profile.engine.tile(size: 32)
        VStack(alignment: .leading, spacing: 1) {
          Text(profile.displayName).kitFont(.headline).lineLimit(1)
          Text(profile.subtitle).kitFont(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if profile.isProduction { Chip.production.controlSize(.small) }
      }
      .padding(12)
      .kitSurface(.card)
      .kitHoverEffect(in: shape)
      .contentShape(shape)
    }
    .buttonStyle(.kitHoverEffect)
    .accessibilityLabel("Open \(profile.displayName), \(profile.subtitle)")
  }
}
