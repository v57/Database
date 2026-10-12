import DatabaseCore
import SwiftUI

/// First screen: recent connections and a way to add one.
struct WelcomeView: View {
  @Bindable var window: WindowModel
  @Environment(AppModel.self) private var app

  private var recent: [ConnectionProfile] {
    app.profiles.filter { $0.lastUsed != nil }.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
      .prefix(6).map { $0 }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        VStack(spacing: 10) {
          Image(systemName: "cylinder.split.1x2.fill")
            .font(.system(size: 52))
            .foregroundStyle(.tint)
          Text("Database Pro").font(.largeTitle.bold())
          Text("PostgreSQL, MySQL, MariaDB, SQL Server, SQLite, DuckDB, MongoDB, Redis, Cassandra and ScyllaDB — in one window.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 480)
        }
        Button {
          window.showsNewConnection = true
        } label: {
          Label("New Connection", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        if !recent.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Recent").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
              ForEach(recent) { profile in
                Button {
                  window.connect(profile.id)
                } label: {
                  HStack(spacing: 10) {
                    EngineTile(engine: profile.engine, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(profile.displayName).fontWeight(.semibold).lineLimit(1)
                      Text(profile.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if profile.isProduction { TagLabel(text: "Production", color: .red) }
                  }
                  .padding(12)
                  .groupBox()
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }
            }
          }
          .frame(maxWidth: 760)
        }
        Text("Tip: drop a .sqlite, .duckdb, .parquet or .csv file on the window to open it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(40)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Database Pro")
  }
}
