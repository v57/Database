import ComponentKit
import DatabaseKit
import SwiftUI

/// The main pane: whatever the sidebar selection opens.
public struct DetailView: View {
  @Bindable var window: WindowModel
  @Environment(DatabaseModel.self) private var app

  public init(window: WindowModel) { self.window = window }

  public var body: some View {
    switch window.route {
    case .welcome:
      WelcomeView(window: window)
    case .connection(let id):
      ConnectionOverview(connection: app.connection(for: id), window: window)
    case .browse(let id, let ref):
      let connection = app.connection(for: id)
      let browser = connection.browser(for: ref)
      Group {
        if connection.profile.engine == .redis {
          KeysBrowserView(browser: browser, window: window)
        } else {
          BrowserView(browser: browser, window: window)
        }
      }
      .id(ref.id + id.uuidString)
    case .query(let id):
      QueryEditorView(workspace: app.connection(for: id).queries, window: window)
        .id(id)
    }
  }
}

/// Shown while a connection is selected but no table is: status, server, and what's inside.
struct ConnectionOverview: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  @Environment(DatabaseModel.self) private var app

  var body: some View {
    VStack(spacing: 14) {
      connection.liveTile(size: 56)
      Text(connection.profile.displayName).kitFont(.title1)
      Text(connection.profile.subtitle).foregroundStyle(.kitSecondary)
      HStack(spacing: 6) { connection.profile.safetyChips }
      switch connection.status {
      case .idle, .connecting:
        Text("Connecting…").foregroundStyle(.kitSecondary)
      case .connected:
        if let report = connection.report {
          Label("Connected to \(report.serverDescription) in \(formatDuration(report.elapsed))", systemImage: "checkmark.circle.fill")
            .foregroundStyle(Hue.green.text)
          if let fingerprint = report.sshHostKeyFingerprint {
            Text("Through SSH · host key \(fingerprint)").kitFont(.caption).textSelection(.enabled)
          }
        }
        Text("Pick a \(connection.profile.engine.collectionNoun.singular) in the sidebar to see its \(connection.profile.engine.itemNoun.plural).")
          .foregroundStyle(.kitSecondary)
        Button("New Query", systemImage: "terminal") { window.newQuery() }
          .buttonStyle(.kit)
      case .failed(let message):
        // A DuckDB file without the library shows the download instead of the error that says so.
        if connection.profile.engine == .duckdb, !app.duckDB.isInstalled {
          DuckDBInstallRow()
            .kitCard(padding: 12)
            .frame(maxWidth: 460)
            .onChange(of: app.duckDB.isInstalled) { _, installed in
              if installed { Task { await connection.reconnect() } }
            }
        } else {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Hue.red.text)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
        }
        HStack {
          Button("Try Again") { Task { await connection.reconnect() } }.buttonStyle(.kitPrimary)
          Button("Edit Connection…") { window.editingProfileID = connection.id }.buttonStyle(.kit)
        }
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .kitPane(.content)
    .kitToolbar(connection.profile.displayName) {
      Text(connection.profile.displayName).kitFont(.title2)
    } tools: {
      if connection.isConnected {
        ToolGroup(iconOnly: true) {
          Button("Refresh", systemImage: "arrow.clockwise") { Task { await connection.refreshTree() } }
        }
      }
    }
  }
}
