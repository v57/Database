import ComponentKit
import DatabaseKit
import DatabaseUI
import SwiftUI
import VaultKit
import VaultUI

// Screenshot captures (Dev's DevScreenshots).
#if DEBUG
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
            DebugSelect.listenForSelectRequests(model)
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
  /// What a dropped folder holds that the vault doesn't have: its databases, and its projects for the other apps.
  @State private var importOffer: VaultImportOffer?
  #if os(iOS)
    /// Settings, which iPhone and iPad have no window for (D-021): until Done or something is picked, alone in the
    /// detail on iPad (its own pane list beside the sidebar doesn't fit portrait), over the split view on iPhone.
    @State private var showsSettings = false
    @State private var columnsBeforeSettings = NavigationSplitViewVisibility.all
    @Environment(\.kitIdiom) private var idiom
  #endif

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
      sidebar
        .toolbar(removing: .sidebarToggle)
        .kitSidebarColumn()
    } detail: {
      #if os(iOS)
        if showsSettings && idiom != .phone {
          NavigationStack {
            SettingsView {
              showsSettings = false
              compactColumn = .sidebar
            }
          }
        } else {
          // The detail's own stack: on iPhone an item pushes its screen (a split view's detail column has none).
          NavigationStack {
            DetailView(window: window)
              .kitSidebarToggle(columnVisibility: $columnVisibility)
          }
        }
      #else
        DetailView(window: window)
          .kitSidebarToggle(columnVisibility: $columnVisibility)
      #endif
    }
    #if os(iOS)
      // iPhone: Settings slides in over the split view with a stack of its own. Pushed in the collapsed split view's
      // detail, a pane's Back made the split view report the sidebar column, which closed Settings underneath it, so
      // Done then changed nothing and did nothing (D-024).
      .overlay {
        if showsSettings && idiom == .phone {
          NavigationStack {
            SettingsView { withAnimation(.kit) { showsSettings = false } }
          }
          .transition(.move(edge: .trailing))
        }
      }
      .onChange(of: showsSettings) { _, shows in
        guard idiom != .phone else { return }
        if shows {
          columnsBeforeSettings = columnVisibility
          columnVisibility = .detailOnly
          compactColumn = .detail
        } else {
          columnVisibility = columnsBeforeSettings
        }
      }
      // iPhone: back from Settings to the sidebar; anywhere: a connection, table or query picked.
      .onChange(of: compactColumn) { _, column in
        if column == .sidebar && idiom != .phone { showsSettings = false }
      }
      .onChange(of: window.route) { showsSettings = false }
      #if DEBUG
        // `--settings`: Settings at launch, as the Mac opens its window (screenshots, checks).
        .task {
          guard LaunchOptions.flag("--settings") else { return }
          showsSettings = true
          guard idiom != .phone else { return }
          columnVisibility = .detailOnly
          compactColumn = .detail
        }
      #endif
    #endif
    .focusedSceneValue(\.databaseWindow, window)
    .databaseSheets(window)
    .modifier(CompactColumnFollower(window: window, column: $compactColumn))
    .onOpenURL { url in
      if let profile = app.addFile(url) { window.connect(profile.id) }
    }
    #if os(macOS)
      // The kit's: a file dropped over a connection row (a reorderable row) comes here too.
      .kitFileDrop { urls in
        var folders: [URL] = []
        for url in urls {
          if let profile = app.addFile(url) {
            window.connect(profile.id)
          } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            folders.append(url)
          }
        }
        guard !folders.isEmpty else { return }
        Task { importOffer = await VaultImportOffer.scan(folders, store: app.vault.store) }
      }
      .kitSheet(item: $importOffer) { offer in VaultImportSheet(offer, vault: app.vault, app: "Database") }
    #endif
  }
}

extension WindowContent {
  private var sidebar: SidebarView {
    #if os(iOS)
      SidebarView(window: window, columnVisibility: $columnVisibility) { withAnimation(.kit) { showsSettings = true } }
    #else
      SidebarView(window: window, columnVisibility: $columnVisibility)
    #endif
  }
}

/// Shows the page on a phone once something is open, the sidebar on Welcome, and the page again for a row tapped again
/// (D-025: after Back the row is still the selection, so the route doesn't change). A modifier of its own: read in the
/// window's body, the route (a new one on every table, query tab or connection picked) built the split view again,
/// the sidebar with it.
private struct CompactColumnFollower: ViewModifier {
  let window: WindowModel
  @Binding var column: NavigationSplitViewColumn

  func body(content: Content) -> some View {
    content
      .onChange(of: window.route) { _, route in follow(route) }
      .onChange(of: window.openCount) { _, _ in follow(window.route) }
  }

  private func follow(_ route: WindowModel.Route) {
    if case .welcome = route { column = .sidebar } else { column = .detail }
  }
}
