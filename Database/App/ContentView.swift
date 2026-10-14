import DatabaseKit
import SwiftUI

#if DEBUG
  import DevScreenshots
#endif

struct ContentView: View {
  @Environment(AppModel.self) private var app
  @State private var window: WindowModel?

  var body: some View {
    Group {
      if let window {
        // A new model (a screenshot scene) starts the window's own state over too.
        WindowContent(window: window).id(ObjectIdentifier(window))
      } else {
        Color.clear
      }
    }
    .onAppear {
      if window == nil {
        let model = WindowModel(app: app)
        window = model
        #if DEBUG
          // Screenshots (.dev/screenshots.json): every scene of a locale in this launch. A scene starts from a new
          // window model and closed connections, as a fresh launch would, then opens from its own arguments.
          Screenshots.prepare(waitsForReady: true) { scene in
            LaunchOptions.arguments = scene.arguments
            let model = WindowModel(app: app)
            window = model
            await app.disconnectAll()
            await DebugDriver.run(model)
          }
          Task {
            await DebugDriver.run(model)
            Screenshots.ready()
          }
          #if os(macOS)
            if !Screenshots.isCapturing { Task { await DebugPresenter.runIfRequested() } }
          #endif
        #endif
      }
    }
  }
}

private struct WindowContent: View {
  @Bindable var window: WindowModel
  @Environment(AppModel.self) private var app
  #if DEBUG
    // `--hide-sidebar`: iPad portrait screenshots.
    @State private var columnVisibility: NavigationSplitViewVisibility =
      LaunchOptions.flag("--hide-sidebar") ? .detailOnly : .all
  #else
    @State private var columnVisibility = NavigationSplitViewVisibility.all
  #endif
  @State private var compactColumn = NavigationSplitViewColumn.sidebar

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
      SidebarView(window: window)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
    } detail: {
      DetailView(window: window)
    }
    .focusedSceneValue(\.window, window)
    .sheet(isPresented: $window.showsNewConnection) {
      ConnectionSheet(profile: nil) { saved in
        window.connect(saved.id)
      }
      .appButtonShape()
    }
    .sheet(item: $window.editingProfileID) { id in
      ConnectionSheet(profile: app.profile(id)) { saved in
        window.connect(saved.id)
      }
      .appButtonShape()
    }
    .onChange(of: window.route) { _, route in
      if case .welcome = route { compactColumn = .sidebar } else { compactColumn = .detail }
    }
    .onOpenURL { url in
      if let profile = app.addFile(url) { window.connect(profile.id) }
    }
    #if os(macOS)
      .dropDestination(for: URL.self) { urls, _ in
        var opened = false
        for url in urls { if let profile = app.addFile(url) { window.connect(profile.id); opened = true } }
        return opened
      }
    #endif
  }
}

extension UUID: @retroactive Identifiable {
  public var id: UUID { self }
}

/// The main pane: whatever the sidebar selection opens.
struct DetailView: View {
  @Bindable var window: WindowModel
  @Environment(AppModel.self) private var app

  var body: some View {
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
  @Environment(AppModel.self) private var app

  var body: some View {
    VStack(spacing: 14) {
      EngineTile(engine: connection.profile.engine, size: 56)
      Text(connection.profile.displayName).font(.title2.bold())
      Text(connection.profile.subtitle).foregroundStyle(.secondary)
      SafetyTags(profile: connection.profile)
      switch connection.status {
      case .idle, .connecting:
        ProgressView("Connecting…").controlSize(.small)
      case .connected:
        if let report = connection.report {
          Label("Connected to \(report.serverDescription) in \(formatDuration(report.elapsed))", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          if let fingerprint = report.sshHostKeyFingerprint {
            Text("Through SSH · host key \(fingerprint)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        Text("Pick a \(connection.profile.engine.collectionNoun.singular) in the sidebar to see its \(connection.profile.engine.itemNoun.plural).")
          .foregroundStyle(.secondary)
        Button("New Query", systemImage: "terminal") { window.newQuery() }
          .buttonStyle(.bordered)
      case .failed(let message):
        // A DuckDB file without the library shows the download instead of the error that says so.
        if connection.profile.engine == .duckdb, !app.duckDB.isInstalled {
          DuckDBInstallRow()
            .padding(12)
            .groupBox()
            .frame(maxWidth: 460)
            .onChange(of: app.duckDB.isInstalled) { _, installed in
              if installed { Task { await connection.reconnect() } }
            }
        } else {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
        }
        HStack {
          Button("Try Again") { Task { await connection.reconnect() } }.buttonStyle(.borderedProminent)
          Button("Edit Connection…") { window.editingProfileID = connection.id }.buttonStyle(.bordered)
        }
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(connection.profile.displayName)
  }
}
