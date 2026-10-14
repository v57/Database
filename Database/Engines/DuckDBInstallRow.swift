import DatabaseKit
import SwiftUI

/// Where DuckDB stands (not installed, downloading, installed) with the button that changes it. The app ships without
/// DuckDB; it's downloaded from GitHub only when the person asks here.
struct DuckDBInstallRow: View {
  @Environment(AppModel.self) private var app
  /// Whether "Remove" is offered (Settings) or only Download (the connection sheet, a failed connection).
  var showsRemove = false

  var body: some View {
    let installer = app.duckDB
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        switch installer.state {
        case .unavailable:
          Text("DuckDB isn't available on this device.").foregroundStyle(.secondary)
        case .notInstalled:
          Text("DuckDB isn't installed.").fontWeight(.medium)
          Text("Database downloads it from GitHub (\(formatBytes(installer.release.size))) only when you choose Download.")
            .foregroundStyle(.secondary)
        case .downloading(let fraction):
          Text("Downloading DuckDB \(installer.release.version)…").fontWeight(.medium)
          ProgressView(value: fraction).frame(maxWidth: 240)
        case .installing:
          Text("Installing DuckDB…").fontWeight(.medium)
          ProgressView().controlSize(.small)
        case .installed(let version):
          Label("DuckDB \(version) is installed.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          if installer.hasUpdate {
            Text("Version \(installer.release.version) is available (\(formatBytes(installer.release.size))).")
              .foregroundStyle(.secondary)
          } else if showsRemove, DuckDBLibrary.isLoaded {
            Text("Removing it takes effect after Database restarts.").foregroundStyle(.secondary)
          }
        case .failed(let message):
          Text(message).foregroundStyle(.red).lineLimit(3)
        }
      }
      .font(.callout)
      Spacer(minLength: 0)
      switch installer.state {
      case .unavailable:
        EmptyView()
      case .notInstalled, .failed:
        Button("Download") { installer.install() }.buttonStyle(.borderedProminent)
      case .downloading, .installing:
        Button("Cancel") { installer.cancel() }.disabled({ if case .installing = installer.state { true } else { false } }())
      case .installed:
        if installer.hasUpdate {
          Button("Update") { installer.install() }
        }
        if showsRemove {
          Button("Remove", role: .destructive) { installer.remove() }
        }
      }
    }
    .controlSize(.regular)
    .onAppear { installer.refresh() }
  }
}
