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

  public init(window: WindowModel, columnVisibility: Binding<NavigationSplitViewVisibility>) {
    self.window = window
    _columnVisibility = columnVisibility
  }

  private var query: String { window.searchText.trimmingCharacters(in: .whitespaces) }

  private var profiles: [ConnectionProfile] {
    guard !query.isEmpty else { return app.profiles }
    return app.profiles.filter { profile in
      if profile.displayName.localizedCaseInsensitiveContains(query) || profile.subtitle.localizedCaseInsensitiveContains(query) {
        return true
      }
      // Or any loaded table/collection matches.
      guard let live = app.live[profile.id] else { return false }
      return live.children.values.joined().contains { $0.title.localizedCaseInsensitiveContains(query) }
    }
  }

  /// The connection the window shows, lifted out of the list into its own card.
  private var current: LiveConnection? {
    guard let id = window.currentConnectionID, profiles.contains(where: { $0.id == id }) else { return nil }
    return app.connection(for: id)
  }

  public var body: some View {
    let current = current
    let others = profiles.filter { $0.id != current?.id }
    // The Mac's toggle hides the sidebar through the window's split view; iPad and iPhone need the binding.
    KitSidebar(selection: $window.selection, searchText: $window.searchText, columnVisibility: idiom.isTouch ? $columnVisibility : nil) {
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
        if window.currentConnectionID == deleting.id { window.selection = nil }
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

  public init(connection: LiveConnection, window: WindowModel, level: Int) {
    self.connection = connection
    self.window = window
    self.level = level
  }

  public var body: some View {
    switch connection.status {
    case .connected:
      TreeChildren(connection: connection, parent: nil, window: window, level: level)
      QueryRows(connection: connection, window: window, level: level)
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

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { connection.expanded.contains(LiveConnection.rootID) },
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
      Button("Disconnect", systemImage: "eject") { Task { await app.disconnect(connection.id) } }
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

/// Lazily loaded children of a tree node.
struct TreeChildren: View {
  let connection: LiveConnection
  let parent: TreeNode?
  @Bindable var window: WindowModel
  var level: Int

  var body: some View {
    let key = connection.key(parent)
    if let nodes = connection.children[key] {
      if nodes.isEmpty {
        NoteLine(emptyText, systemImage: nil).inTree(level)
      }
      ForEach(nodes) { node in
        TreeNodeRow(connection: connection, node: node, window: window, level: level)
      }
    } else if let error = connection.treeErrors[key] {
      NoteLine(error, systemImage: nil, hue: .red).inTree(level)
    } else {
      NoteLine("Loading…", systemImage: nil).inTree(level)
        .task { await connection.loadChildren(of: parent) }
    }
  }

  private var emptyText: String {
    switch parent?.kind {
    case .database, .keyspace, .schema: "No \(connection.profile.engine.collectionNoun.plural)"
    default: "Nothing here yet"
    }
  }
}

struct TreeNodeRow: View {
  let connection: LiveConnection
  let node: TreeNode
  @Bindable var window: WindowModel
  var level: Int
  @Environment(\.databaseSidebarTag) private var tag

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { connection.expanded.contains(node.id) },
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
      if isExpanded.wrappedValue {
        TreeChildren(connection: connection, parent: node, window: window, level: level + 1)
      }
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
  @Environment(DatabaseModel.self) private var app
  @Environment(\.databaseSidebarTag) private var tag
  @State private var isExpanded = true

  var body: some View {
    let saved = app.queries(for: connection.id)
    let tabs = connection.queries.tabs.filter { $0.savedID == nil }
    if !saved.isEmpty || !tabs.isEmpty {
      SidebarRow("Queries", systemImage: "folder", isExpanded: $isExpanded) {
        Text("\(saved.count + tabs.count)")
      }
      .action { withKitAnimation { isExpanded.toggle() } }
      .kitRowIndent(level)
      if isExpanded {
        ForEach(saved) { query in
          SidebarRow(value: tag(.savedQuery(connection.id, query.id)), query.title, systemImage: "terminal")
            .disclosureSlot()
            .kitRowIndent(level + 1)
          .kitContextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { app.deleteQuery(query.id) }
          }
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

extension NoteLine {
  /// The note as a line of the tree (loading, empty, or what went wrong), under the rows of `level`.
  fileprivate func inTree(_ level: Int) -> some View {
    lineLimit(4)
      .padding(.leading, 2 + 14 + CGFloat(level) * 14)
      .padding(.vertical, 4)
  }
}
