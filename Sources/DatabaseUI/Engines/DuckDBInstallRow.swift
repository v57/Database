import ComponentKit
import DatabaseKit
import SwiftUI

/// Where DuckDB stands (not installed, downloading, installed) with the button that changes it. The app ships without
/// DuckDB; it's downloaded from GitHub only when the person asks here.
struct DuckDBInstallRow: View {
  @Environment(DatabaseModel.self) private var app
  /// Whether "Remove" is offered (Settings) or only Download (the connection sheet, a failed connection).
  var showsRemove = false

  var body: some View {
    let installer = app.duckDB
    HStack(alignment: .center, spacing: 12) {
      LiveIcon(letters: EngineKind.duckdb.monogram, hue: EngineKind.duckdb.hue, status: status, size: 28)
      VStack(alignment: .leading, spacing: 2) {
        switch installer.state {
        case .unavailable:
          Text("DuckDB isn't available on this device.").foregroundStyle(.kitSecondary)
        case .notInstalled:
          Text("DuckDB isn't installed.").kitFont(.headline)
          Text("Database downloads it from GitHub (\(formatBytes(installer.release.size))) only when you choose Download.")
            .kitFont(.caption)
        case .downloading(let fraction):
          Text("Downloading DuckDB \(installer.release.version)…").kitFont(.headline)
          Text("\(Int(fraction * 100))% of \(formatBytes(installer.release.size))").kitFont(.caption)
        case .installing:
          Text("Installing DuckDB…").kitFont(.headline)
        case .installed(let version):
          Text("DuckDB \(version) is installed.").kitFont(.headline)
          if installer.hasUpdate {
            Text("Version \(installer.release.version) is available (\(formatBytes(installer.release.size))).")
              .kitFont(.caption)
          } else if showsRemove, DuckDBLibrary.isLoaded {
            Text("Removing it takes effect after Database restarts.").kitFont(.caption)
          }
        case .failed(let message):
          Text(message).foregroundStyle(Hue.red.text).lineLimit(3)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      switch installer.state {
      case .unavailable:
        EmptyView()
      case .notInstalled, .failed:
        Button("Download") { installer.install() }.buttonStyle(.kitPrimary)
      case .downloading, .installing:
        Button("Cancel") { installer.cancel() }
          .buttonStyle(.kit)
          .disabled({ if case .installing = installer.state { true } else { false } }())
      case .installed:
        if installer.hasUpdate {
          Button("Update") { installer.install() }.buttonStyle(.kit)
        }
        if showsRemove {
          Button("Remove", role: .destructive) { installer.remove() }.buttonStyle(.kit)
        }
      }
    }
    .controlSize(.small)
    .onAppear { installer.refresh() }
  }

  private var status: WorkStatus {
    switch app.duckDB.state {
    case .downloading(let fraction): .working(progress: fraction)
    case .installing: .working
    case .installed: .done
    case .failed(let message): .failed(message)
    case .unavailable, .notInstalled: .idle
    }
  }
}
