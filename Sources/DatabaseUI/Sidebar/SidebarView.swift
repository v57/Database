import ComponentKit
import DatabaseKit
import SwiftUI
import VaultUI

/// The kit's sidebar: the window's account (hidden while Personal is the only one), the open connection as its own
/// card (its databases, tables and queries), then every saved connection in the Connections card.
public struct SidebarView: View {
  @Bindable var window: WindowModel
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @Environment(DatabaseModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var deleting: ConnectionProfile?
  /// Opens Settings from the sidebar's bottom bar: iPhone and iPad, which have no Settings window (D-021).
  private let settings: (() -> Void)?

  public init(
    window: WindowModel, columnVisibility: Binding<NavigationSplitViewVisibility>, settings: (() -> Void)? = nil
  ) {
    self.window = window
    _columnVisibility = columnVisibility
    self.settings = settings
  }

  private var query: String { window.sidebarQuery }

  private var profiles: [ConnectionProfile] {
    guard !query.isEmpty else { return app.profiles }
    return app.profiles.filter { profile in
      if profile.matches(query) { return true }
      // Or anything it has loaded matches.
      return app.live[profile.id]?.holdsMatch(for: query, in: app) ?? false
    }
  }

  /// The connection the window shows, lifted out of the list into its own card. A search narrows its tree, and it
  /// stays to say what wasn't found.
  private var current: LiveConnection? {
    guard let id = window.currentConnectionID, app.profiles.contains(where: { $0.id == id }) else { return nil }
    return app.connection(for: id)
  }

  public var body: some View {
    let current = current
    let others = profiles.filter { $0.id != current?.id }
    // The Mac's toggle hides the sidebar through the window's split view; iPad and iPhone need the binding.
    SidebarFrame(window: window, columnVisibility: idiom.isTouch ? $columnVisibility : nil, settings: settings) {
      VaultAccountPicker(meta: app.profiles.count == 1 ? "1 connection" : "\(app.profiles.count) connections")
      // A long tree keeps the open connection's title in view; Connections waits at the bottom while it's below.
      if let current {
        CurrentConnectionSection(connection: current, window: window) { deleting = current.profile }
          .kitSticky()
      }
      KitSection(
        "Connections", meta: connectionsMeta(current: current), systemImage: "cylinder.split.1x2"
      ) {
        ReorderableSection(others, move: { move(others, from: $0, to: $1) }) { profile in
          ConnectionRow(connection: app.connection(for: profile.id), window: window) { deleting = profile }
        }
        if app.profiles.isEmpty {
          Button("Add a Connection", systemImage: "plus") { window.showsNewConnection = true }
            .buttonStyle(.kitPlain)
            .padding(.vertical, 4)
          // On iPhone the sidebar is the first screen, so the sample is offered here too.
          Button("Open the Sample Database", systemImage: "cart") { window.openSample() }
            .buttonStyle(.kitPlain)
            .padding(.bottom, 4)
        } else if profiles.isEmpty {
          Text("No connections match “\(query)”.")
            .kitFont(.caption)
            .padding(8)
        }
      } accessory: {
        Button("New Connection", systemImage: "plus") { window.showsNewConnection = true }
      }
      .kitSticky(bottom: .title)
    }
    .navigationTitle("Database")
    .kitConfirmation(
      "Delete “\(deleting?.displayName ?? "")”?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      message: "This removes the saved connection and its password. The database itself isn't touched.",
      systemImage: "trash", confirm: "Delete Connection"
    ) {
      if let deleting {
        window.leave(deleting.id)
        app.delete(deleting.id)
      }
      deleting = nil
    }
  }

  private func connectionsMeta(current: LiveConnection?) -> [String] {
    var parts = ["\(app.profiles.count) saved"]
    if let current { parts.append("\(current.profile.displayName) open") }
    return parts
  }

  /// Moves within the shown rows (filtered, without the open connection) by moving the same profiles in the full list.
  private func move(_ shown: [ConnectionProfile], from source: IndexSet, to destination: Int) {
    let all = app.profiles.map(\.id)
    let from = IndexSet(source.compactMap { all.firstIndex(of: shown[$0].id) })
    let to: Int =
      if destination < shown.count { all.firstIndex(of: shown[destination].id) ?? all.count } else {
        shown.last.flatMap { all.firstIndex(of: $0.id) }.map { $0 + 1 } ?? all.count
      }
    app.move(from: from, to: to)
  }
}

/// The kit's sidebar around the rows, bound to the window's selection. A view of its own: a binding reads its value
/// as it's made, so made in `SidebarView`'s body the selection rebuilt every card and row (new closures each time) on
/// each click in the tree. Here the rows come in built and stay the same value when only the selection changes.
private struct SidebarFrame<Content: View>: View {
  @Bindable var window: WindowModel
  let columnVisibility: Binding<NavigationSplitViewVisibility>?
  let settings: (() -> Void)?
  let content: Content

  init(
    window: WindowModel, columnVisibility: Binding<NavigationSplitViewVisibility>?, settings: (() -> Void)?,
    @ViewBuilder content: () -> Content
  ) {
    self.window = window
    self.columnVisibility = columnVisibility
    self.settings = settings
    self.content = content()
  }

  var body: some View {
    // A row tapped again opens its screen again: on iPhone, after Back, the row is still the selection (D-025).
    let selection = Binding<SidebarItem?>(get: { window.selection }, set: { window.open($0) })
    KitSidebar(selection: selection, searchText: $window.searchText, columnVisibility: columnVisibility) {
      content
    } bottomBar: {
      if let settings { Button("Settings", systemImage: "gearshape", action: settings) }
    }
  }
}

/// The open connection as a card: its tile, name and server in the header, its tree as rows.
private struct CurrentConnectionSection: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  var onDelete: () -> Void
  @State private var showsActions = false

  var body: some View {
    let profile = connection.profile
    KitSection(Text(profile.displayName)) {
      ConnectionContents(connection: connection, window: window, level: 0)
    } icon: {
      connection.liveTile(size: 24)
    } meta: {
      MetaLine([profile.engine.displayName, profile.serverSummary])
        .truncationMode(.tail)
    } accessory: {
      Button("\(profile.displayName) actions", systemImage: "ellipsis") { showsActions = true }
        .labelStyle(.iconOnly)
        .kitMenu(isPresented: $showsActions) {
          ConnectionMenu(connection: connection, window: window, onDelete: onDelete)
        }
    }
    .titleAccessory {
      if profile.isProduction { Chip.production.controlSize(.small) }
    }
    .kitContextMenu { ConnectionMenu(connection: connection, window: window, onDelete: onDelete) }
  }
}

/// What a connection holds once open: its tree and its queries, or how far connecting got. Shell shows it under its
/// own sidebar row for the connection; its rows tag the selection through `databaseSidebarTag`.
public struct ConnectionContents: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  let level: Int
  @Environment(DatabaseModel.self) private var app

  public init(connection: LiveConnection, window: WindowModel, level: Int) {
    self.connection = connection
    self.window = window
    self.level = level
  }

  public var body: some View {
    switch connection.status {
    case .connected:
      // The open tree as one lazy list, however deep it's open: a server can hold thousands of collections, and every
      // built row costs layout and hit testing on each frame of a scroll.
      let query = window.sidebarQuery
      // A search on the connection's own name alone leaves its tree as it is.
      let isNarrowed = !query.isEmpty && (connection.holdsMatch(for: query, in: app) || !connection.profile.matches(query))
      let search = isNarrowed ? connection.treeSearch(query) : nil
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(connection.outline.lines(level: level, search: search)) { line in
          TreeLineRow(connection: connection, line: line)
        }
        QueryRows(connection: connection, window: window, level: level, query: isNarrowed ? query : "")
        if let search {
          if !connection.holdsMatch(for: query, in: app) {
            NoteLine("Nothing loaded matches “\(query)”.", systemImage: nil).inTree(level)
          }
          if let note = search.unopenedNote {
            NoteLine(note, systemImage: nil).inTree(level)
          }
        }
      }
    case .connecting, .idle:
      NoteLine("Connecting…", systemImage: nil).inTree(level)
    case .failed(let message):
      NoteLine(message, systemImage: nil, hue: .red).inTree(level)
    }
  }
}

/// A saved connection in the Connections card; its chevron opens its tree under it.
struct ConnectionRow: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  var onDelete: () -> Void
  @Environment(\.databaseSidebarTag) private var tag
  @Environment(DatabaseModel.self) private var app

  /// A search found something it has loaded: the row opens to show it.
  private var holdsSearchMatch: Bool {
    let query = window.sidebarQuery
    return !query.isEmpty && connection.holdsMatch(for: query, in: app)
  }

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { connection.expanded.contains(LiveConnection.rootID) || holdsSearchMatch },
      set: { open in
        if open {
          connection.expanded.insert(LiveConnection.rootID)
          Task { await connection.connect() }
        } else {
          connection.expanded.remove(LiveConnection.rootID)
        }
      })
  }

  var body: some View {
    let profile = connection.profile
    VStack(alignment: .leading, spacing: 2) {
      SidebarRow(
        value: tag(.connection(connection.id)), profile.displayName, subtitle: profile.subtitle,
        isExpanded: isExpanded
      ) {
        connection.liveTile(size: 22)
      }
      .titleAccessory {
        HStack(spacing: 6) {
          if let hue = profile.color.hue { StatusDot(hue: hue) }
          if profile.isProduction { Chip.production.controlSize(.small) }
        }
      }
      .kitContextMenu { ConnectionMenu(connection: connection, window: window, onDelete: onDelete) }
      .accessibilityLabel("\(profile.displayName), \(profile.engine.displayName)")
      if isExpanded.wrappedValue {
        ConnectionContents(connection: connection, window: window, level: 1)
      }
    }
  }
}

/// A connection's actions, for its context menu and the open connection's "…" menu. `extra` adds the app's own
/// (Shell's Rename).
public struct ConnectionMenu<Extra: View>: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  var onDelete: () -> Void
  var extra: Extra
  @Environment(DatabaseModel.self) private var app

  public init(
    connection: LiveConnection, window: WindowModel, onDelete: @escaping () -> Void,
    @ViewBuilder extra: () -> Extra = { EmptyView() }
  ) {
    self.connection = connection
    self.window = window
    self.onDelete = onDelete
    self.extra = extra()
  }

  public var body: some View {
    if connection.isConnected {
      Button("New Query", systemImage: "terminal") {
        window.selection = .connection(connection.id)
        window.newQuery()
      }
      Button("Refresh", systemImage: "arrow.clockwise") { Task { await connection.refreshTree() } }
      Button("Disconnect", systemImage: "eject") {
        window.leave(connection.id)
        Task { await app.disconnect(connection.id) }
      }
        .kitMenuPreview("Closes the connection to \(connection.profile.displayName). It stays saved.")
    } else {
      Button("Connect", systemImage: "bolt") { window.connect(connection.id) }
    }
    Divider()
    extra
    Button("Edit Connection…", systemImage: "pencil") { window.editingProfileID = connection.id }
    Button("Duplicate", systemImage: "plus.square.on.square") { app.duplicate(connection.id) }
    Button("Copy Link", systemImage: "link") { KitPasteboard.copy(ConnectionLink.url(for: connection.profile)) }
    Divider()
    Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
  }
}

extension LiveConnection {
  /// The engine's two-letter tile, carrying the connection's state (the arc while it connects, red when it failed).
  public func liveTile(size: CGFloat) -> LiveIcon<Text> {
    let status: WorkStatus =
      switch self.status {
      case .connecting: .working
      case .failed(let message): .failed(message)
      case .idle, .connected: .idle
      }
    return LiveIcon(letters: profile.engine.monogram, hue: profile.engine.hue, status: status, size: size)
  }
}

extension ConnectionProfile {
  /// "127.0.0.1:27018", "analytics.duckdb": the subtitle without the engine's name.
  var serverSummary: String {
    let prefix = engine.displayName + " · "
    return subtitle.hasPrefix(prefix) ? String(subtitle.dropFirst(prefix.count)) : subtitle
  }
}

extension WindowModel {
  /// What the sidebar's search field holds, trimmed.
  var sidebarQuery: String { searchText.trimmingCharacters(in: .whitespaces) }
}

extension ConnectionProfile {
  fileprivate func matches(_ query: String) -> Bool {
    displayName.localizedCaseInsensitiveContains(query) || subtitle.localizedCaseInsensitiveContains(query)
  }
}

extension LiveConnection {
  /// Whether a search finds anything this connection has loaded: its tree, its saved queries or its open tabs.
  fileprivate func holdsMatch(for query: String, in app: DatabaseModel) -> Bool {
    if treeSearch(query)?.hasMatches == true { return true }
    return QueryRows.saved(of: self, in: app, query: query).isEmpty == false || QueryRows.tabs(of: self, query: query).isEmpty == false
  }
}

extension TreeSearch {
  /// Says what the search couldn't see: a branch's children load when it's opened.
  fileprivate var unopenedNote: String? {
    guard let first = unopened.first else { return nil }
    let count = unopened.count
    return switch first.kind {
    case .database:
      count == 1
        ? String(localized: "1 database isn't open, so it isn't searched.")
        : String(localized: "\(count) databases aren't open, so they aren't searched.")
    case .schema:
      count == 1
        ? String(localized: "1 schema isn't open, so it isn't searched.")
        : String(localized: "\(count) schemas aren't open, so they aren't searched.")
    case .keyspace:
      count == 1
        ? String(localized: "1 keyspace isn't open, so it isn't searched.")
        : String(localized: "\(count) keyspaces aren't open, so they aren't searched.")
    default:
      count == 1
        ? String(localized: "1 folder isn't open, so it isn't searched.")
        : String(localized: "\(count) folders aren't open, so they aren't searched.")
    }
  }
}

struct TreeLineRow: View {
  let connection: LiveConnection
  let line: TreeOutline.Line

  var body: some View {
    switch line.content {
    case .node(let node, let isRevealed):
      TreeNodeRow(connection: connection, node: node, isRevealed: isRevealed, level: line.level)
    case .empty(let parent):
      NoteLine(emptyText(parent), systemImage: nil).inTree(line.level)
    case .failed(let message):
      NoteLine(message, systemImage: nil, hue: .red).inTree(line.level)
    case .loading(let parent):
      NoteLine("Loading…", systemImage: nil).inTree(line.level)
        .task { await connection.loadChildren(of: parent) }
    }
  }

  private func emptyText(_ parent: TreeNode?) -> String {
    switch parent?.kind {
    case .database, .keyspace, .schema: String(localized: "No \(connection.profile.engine.collectionNoun.plural)")
    default: String(localized: "Nothing here yet")
    }
  }
}

struct TreeNodeRow: View {
  let connection: LiveConnection
  let node: TreeNode
  /// Open because a search found something in it.
  var isRevealed = false
  var level: Int
  @Environment(\.databaseSidebarTag) private var tag

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { isRevealed || connection.expanded.contains(node.id) },
      set: { open in
        withKitAnimation {
          if open { connection.expanded.insert(node.id) } else { connection.expanded.remove(node.id) }
        }
      })
  }

  var body: some View {
    if node.hasChildren {
      SidebarRow(node.title, systemImage: node.symbol, isExpanded: isExpanded) {
        detail
      }
      .action { isExpanded.wrappedValue.toggle() }
      .kitRowIndent(level)
    } else {
      SidebarRow(value: tag(.node(connection.id, node)), node.title, systemImage: node.symbol) {
        detail
      }
      .disclosureSlot()
      .kitRowIndent(level)
    }
  }

  @ViewBuilder private var detail: some View {
    if let detail = node.detail { Text(detail) }
  }
}

/// Saved queries and open query tabs under a connection.
struct QueryRows: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  var level: Int
  /// Keeps the ones with this in their title; a search opens the folder.
  var query = ""
  @Environment(DatabaseModel.self) private var app
  @Environment(\.databaseSidebarTag) private var tag
  @State private var isExpanded = true

  static func saved(of connection: LiveConnection, in app: DatabaseModel, query: String) -> [SavedQuery] {
    app.queries(for: connection.id).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
  }

  static func tabs(of connection: LiveConnection, query: String) -> [QueryTab] {
    connection.queries.tabs.filter { $0.savedID == nil && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
  }

  var body: some View {
    let saved = Self.saved(of: connection, in: app, query: query)
    let tabs = Self.tabs(of: connection, query: query)
    if !saved.isEmpty || !tabs.isEmpty {
      SidebarRow("Queries", systemImage: "folder", isExpanded: query.isEmpty ? $isExpanded : .constant(true)) {
        Text("\(saved.count + tabs.count)")
      }
      .action { withKitAnimation { isExpanded.toggle() } }
      .kitRowIndent(level)
      if isExpanded || !query.isEmpty {
        ForEach(saved) { query in
          SavedQueryRow(connection: connection, query: query, level: level + 1)
        }
        ForEach(tabs) { tab in
          SidebarRow(value: tag(.queryTab(connection.id, tab.id)), tab.title, systemImage: "doc.text")
            .disclosureSlot()
            .kitRowIndent(level + 1)
        }
      }
    }
  }
}

/// A saved query's row, with Delete in its menu. A view of its own: inline in QueryRows, the row's type crashed the
/// Windows toolchain's debug-info mangler (its Asserts build: "Remangling failed", Shell 0.1.0's archive).
private struct SavedQueryRow: View {
  let connection: LiveConnection
  let query: SavedQuery
  let level: Int
  @Environment(DatabaseModel.self) private var app
  @Environment(\.databaseSidebarTag) private var tag

  var body: some View {
    SidebarRow(value: tag(.savedQuery(connection.id, query.id)), query.title, systemImage: "terminal")
      .disclosureSlot()
      .kitRowIndent(level)
      .kitContextMenu {
        Button("Delete", systemImage: "trash", role: .destructive) { app.deleteQuery(query.id) }
          .kitMenuPreview("Deletes the saved query “\(query.title)”.")
      }
  }
}

extension NoteLine {
  /// The note as a line of the tree (loading, empty, or what went wrong), under the rows of `level`.
  fileprivate func inTree(_ level: Int) -> some View {
    lineLimit(4)
      .padding(.leading, 2 + 14 + CGFloat(level) * 14)
      .padding(.vertical, 4)
  }
}
