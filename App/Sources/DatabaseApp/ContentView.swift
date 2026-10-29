import ComponentKit
import DatabaseKit
import DatabaseUI
import SwiftUI

// Screenshot captures (Dev's DevScreenshots); not on Linux, where Dev's package depends on this one.
#if DEBUG && canImport(DevScreenshots)
  import DevScreenshots
#endif

struct ContentView: View {
  @Environment(DatabaseModel.self) private var app
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
          #if canImport(DevScreenshots)
            Screenshots.prepare(waitsForReady: true) { scene in
              LaunchOptions.arguments = scene.arguments
              let model = WindowModel(app: app)
              window = model
              await app.disconnectAll()
              await DebugDriver.run(model)
            }
          #endif
          Task {
            await DebugDriver.run(model)
            #if canImport(DevScreenshots)
              Screenshots.ready()
            #endif
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
  @Environment(DatabaseModel.self) private var app
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
      SidebarView(window: window, columnVisibility: $columnVisibility)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
    } detail: {
      DetailView(window: window)
        .kitSidebarToggle(columnVisibility: $columnVisibility)
    }
    .focusedSceneValue(\.databaseWindow, window)
    .databaseSheets(window)
    .onChange(of: window.route) { _, route in
      if case .welcome = route { compactColumn = .sidebar } else { compactColumn = .detail }
    }
    .onOpenURL { url in
      if let profile = app.addFile(url) { window.connect(profile.id) }
    }
    #if os(macOS)
      // The kit's: a file dropped over a connection row (a reorderable row) comes here too.
      .kitFileDrop { urls in
        for url in urls { if let profile = app.addFile(url) { window.connect(profile.id) } }
      }
    #endif
  }
}
