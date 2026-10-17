import ComponentKit
import DatabaseKit
import SwiftUI

/// The kit's sidebar: the open connection as its own card (its databases, tables and queries), then every saved
/// connection in the Connections card.
struct SidebarView: View {
  @Bindable var window: WindowModel
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var deleting: ConnectionProfile?

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

  var body: some View {
    let current = current
    let others = profiles.filter { $0.id != current?.id }
    // The Mac's toggle hides the sidebar through the window's split view; iPad and iPhone need the binding.
    KitSidebar(selection: $window.selection, searchText: $window.searchText, columnVisibility: idiom.isTouch ? $columnVisibility : nil) {
      if let current {
        CurrentConnectionSection(connection: current, window: window) { deleting = current.profile }
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

/// What a connection holds once open: its tree and its queries, or how far connecting got.
private struct ConnectionContents: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  let level: Int

  var body: some View {
    switch connection.status {
    case .connected:
      TreeChildren(connection: connection, parent: nil, window: window, level: level)
      QueryRows(connection: connection, window: window, level: level)
    case .connecting, .idle:
      TreeNote("Connecting…", level: level)
    case .failed(let message):
      TreeNote(message, hue: .red, level: level)
    }
  }
}

/// A saved connection in the Connections card; its chevron opens its tree under it.
struct ConnectionRow: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  var onDelete: () -> Void

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
        value: SidebarItem.connection(connection.id), profile.displayName, subtitle: profile.subtitle,
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
      // The system's menu: the row drags to reorder, and on touch the kit's long press would take the drag's.
      .contextMenu { ConnectionMenu(connection: connection, window: window, onDelete: onDelete) }
      .accessibilityLabel("\(profile.displayName), \(profile.engine.displayName)")
      if isExpanded.wrappedValue {
        ConnectionContents(connection: connection, window: window, level: 1)
      }
    }
  }
}

/// A connection's actions, for its context menu and the open connection's "…" menu.
private struct ConnectionMenu: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  var onDelete: () -> Void
  @Environment(AppModel.self) private var app

  var body: some View {
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
    Button("Edit Connection…", systemImage: "pencil") { window.editingProfileID = connection.id }
    Button("Duplicate", systemImage: "plus.square.on.square") { app.duplicate(connection.id) }
    Button("Copy Link", systemImage: "link") { KitPasteboard.copy(ConnectionLink.url(for: connection.profile)) }
    Divider()
    Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
  }
}

extension LiveConnection {
  /// The engine's two-letter tile, carrying the connection's state (the arc while it connects, red when it failed).
  func liveTile(size: CGFloat) -> LiveIcon<Text> {
    let status: WorkStatus =
      switch self.status {
      case .connecting: .working
      case .failed(let message): .failed(message)
      case .idle, .connected: .idle
      }
    return LiveIcon(hue: profile.engine.hue, status: status, size: size) {
      Text(profile.engine.monogram).font(.system(size: size * 0.42, weight: .bold))
    }
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
        TreeNote(emptyText, level: level)
      }
      ForEach(nodes) { node in
        TreeNodeRow(connection: connection, node: node, window: window, level: level)
      }
    } else if let error = connection.treeErrors[key] {
      TreeNote(error, hue: .red, level: level)
    } else {
      TreeNote("Loading…", level: level)
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
      SidebarRow(value: SidebarItem.node(connection.id, node), node.title, systemImage: node.symbol) {
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
  @Environment(AppModel.self) private var app
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
          SidebarRow(value: SidebarItem.savedQuery(connection.id, query.id), query.title, systemImage: "terminal")
            .disclosureSlot()
            .kitRowIndent(level + 1)
          .kitContextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { app.deleteQuery(query.id) }
          }
        }
        ForEach(tabs) { tab in
          SidebarRow(value: SidebarItem.queryTab(connection.id, tab.id), tab.title, systemImage: "doc.text")
            .disclosureSlot()
            .kitRowIndent(level + 1)
        }
      }
    }
  }
}

/// A quiet line in the tree: loading, empty, or what went wrong.
private struct TreeNote: View {
  let text: String
  var hue: Hue?
  let level: Int

  init(_ text: String, hue: Hue? = nil, level: Int) {
    self.text = text
    self.hue = hue
    self.level = level
  }

  var body: some View {
    Text(text)
      .kitFont(.caption)
      .foregroundStyle(hue.map { AnyShapeStyle($0.text) } ?? AnyShapeStyle(.kitSecondary))
      .lineLimit(4)
      .padding(.leading, 8 + 14 + CGFloat(level) * 14)
      .padding(.vertical, 4)
  }
}
