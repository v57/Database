import ComponentKit
import DatabaseKit
import SwiftUI
import UniformTypeIdentifiers

// What the sidebar says besides its tree: the activity card's lines (connections opening, open and failed, queries
// running, the last run), the Recent card, and Open a File's types.

extension WindowModel {
  /// The activity card's lines, from the connections made so far: the ones that failed to open, the ones opening,
  /// queries running, the open connections, then the shown query's last run.
  func sidebarActivity(in app: DatabaseModel) -> [SidebarActivity] {
    // In the saved order, so the lines don't trade places between updates.
    let connections = app.profiles.compactMap { app.live[$0.id] }
    var lines: [SidebarActivity] = []
    for connection in connections {
      guard case .failed(let message) = connection.status else { continue }
      let id = connection.id
      lines.append(
        SidebarActivity(
          id: "failed-\(id)", String(localized: "\(connection.profile.displayName) didn't open"), detail: message,
          systemImage: "bolt.slash", hue: .red, status: .failed(message)
        ) { [weak self] in self?.open(.connection(id)) })
    }
    for connection in connections where connection.status == .connecting {
      let profile = connection.profile
      let id = connection.id
      // Through SSH the login to the SSH server is part of connecting: the line says which server that is.
      let detail =
        profile.ssh.enabled && !profile.ssh.host.isEmpty
        ? String(localized: "Through SSH on \(profile.ssh.host)") : profile.serverSummary
      lines.append(
        SidebarActivity(
          id: "connecting-\(id)", String(localized: "Connecting to \(profile.displayName)"), detail: detail,
          systemImage: "bolt", status: .working()
        ) { [weak self] in self?.open(.connection(id)) })
    }
    let open = connections.filter(\.isConnected)
    let running = open.flatMap { connection in
      connection.queries.tabs.filter(\.isRunning).map { (connection: connection, tab: $0) }
    }
    if let first = running.first {
      let item = SidebarItem.queryTab(first.connection.id, first.tab.id)
      lines.append(
        SidebarActivity(
          id: "running",
          running.count == 1
            ? String(localized: "1 query running") : String(localized: "\(running.count) queries running"),
          detail: names(of: running.map(\.connection)), systemImage: "terminal", status: .working()
        ) { [weak self] in self?.open(item) })
    }
    if !open.isEmpty {
      // A tap goes to the next open connection after the one shown.
      let shown = open.firstIndex { $0.id == currentConnectionID } ?? -1
      let next = open[(shown + 1) % open.count].id
      lines.append(
        SidebarActivity(
          id: "open",
          open.count == 1
            ? String(localized: "1 open connection") : String(localized: "\(open.count) open connections"),
          detail: names(of: open), systemImage: "bolt", hue: .green
        ) { [weak self] in self?.open(.connection(next)) })
    }
    if let connection = open.first(where: { $0.id == currentConnectionID }), let tab = connection.queries.selected,
      !tab.isRunning, let elapsed = tab.lastElapsed
    {
      let item = SidebarItem.queryTab(connection.id, tab.id)
      let title =
        if tab.error != nil {
          String(localized: "Last query failed")
        } else if let rows = tab.lastRowCount {
          String(localized: "Last query: \(rows) rows")
        } else {
          String(localized: "Last query done")
        }
      lines.append(
        SidebarActivity(
          id: "last-query", title, detail: formatDuration(elapsed) + " · " + tab.displayTitle,
          systemImage: "terminal", hue: tab.error == nil ? .gray : .red,
          status: tab.error.map { .failed($0) } ?? .idle
        ) { [weak self] in self?.open(item) })
    }
    return lines
  }

  /// "Shop, Analytics": each connection once.
  private func names(of connections: [LiveConnection]) -> String {
    var seen: Set<UUID> = []
    return connections.filter { seen.insert($0.id).inserted }.map(\.profile.displayName).joined(separator: ", ")
  }

  /// What Open a File… takes: every available engine's file kinds.
  static var openableFileTypes: [UTType] {
    let extensions = EngineKind.available.flatMap(\.fileExtensions)
    return [.data] + extensions.compactMap { UTType(filenameExtension: $0) }
  }

  /// Opens database files as connections (saved on first use); false when none was one.
  @discardableResult
  func openFiles(_ urls: [URL], in app: DatabaseModel) -> Bool {
    var opened = false
    for url in urls {
      if let profile = app.addFile(url) {
        connect(profile.id)
        opened = true
      }
    }
    return opened
  }
}

extension QueryTab {
  /// The rows (or documents) of the last result set, when the run made one.
  var lastRowCount: Int? {
    resultOutputs.compactMap { output -> Int? in
      switch output {
      case .table(_, let rows, _): rows.count
      case .documents(let docs, _): docs.count
      default: nil
      }
    }.last
  }
}

/// What a recent row opens: a connection, one of its tables or collections, or a saved query. Its id (what
/// `KitRecents` keeps) is the entry itself as JSON, so a table opens again without its tree loaded. Open query tabs
/// aren't kept: they're gone with the connection.
nonisolated struct RecentEntry: Codable, Hashable, Sendable {
  var connection: UUID
  var object: ObjectRef?
  var query: UUID?

  init?(_ item: SidebarItem) {
    switch item {
    case .connection(let id):
      connection = id
    case .node(let id, let node):
      guard let ref = node.ref else { return nil }
      connection = id
      object = ref
    case .savedQuery(let id, let query):
      connection = id
      self.query = query
    case .queryTab:
      return nil
    }
  }

  init?(id: String) {
    guard let entry = try? JSONDecoder().decode(RecentEntry.self, from: Data(id.utf8)) else { return nil }
    self = entry
  }

  /// The same text for the same entry (sorted keys), so opening it again moves it up instead of adding it twice.
  var id: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }
}

/// The Recent card: the tables, saved queries and connections opened last, hidden while there are none and during a
/// search. A view of its own, so a newly opened item updates this card and not the whole sidebar.
struct RecentSection: View {
  let recents: KitRecents
  let window: WindowModel
  @Environment(DatabaseModel.self) private var app
  @Environment(\.databaseSidebarTag) private var tag

  /// More ids are kept than shown: ones that no longer open anything (a deleted query, another account's) are
  /// passed over.
  static let shown = 5

  private struct Row: Identifiable {
    var id: String
    var item: SidebarItem
    var title: String
    var subtitle: String
    /// A table's or query's symbol; nil shows the connection's tile.
    var symbol: String?
  }

  private var rows: [Row] {
    guard window.sidebarQuery.isEmpty else { return [] }
    let current = window.currentConnectionID
    return Array(
      recents.ids.lazy.compactMap { id -> Row? in
        guard let entry = RecentEntry(id: id), let profile = app.profile(entry.connection) else { return nil }
        if let ref = entry.object {
          // The tree's own node when it's loaded, so the row and the tree's row are the same selection.
          let node =
            app.live[entry.connection]?.node(for: ref)
            ?? TreeNode(id: ref.id, title: ref.name, kind: TreeNode.Kind(rawValue: ref.kind.rawValue) ?? .table, ref: ref)
          return Row(
            id: id, item: .node(entry.connection, node), title: ref.name, subtitle: profile.displayName,
            symbol: ref.symbol)
        }
        if let queryID = entry.query {
          guard let saved = app.savedQueries.first(where: { $0.id == queryID }) else { return nil }
          return Row(
            id: id, item: .savedQuery(entry.connection, queryID), title: saved.title, subtitle: profile.displayName,
            symbol: "terminal")
        }
        // The open connection is the card right below.
        guard entry.connection != current else { return nil }
        return Row(id: id, item: .connection(entry.connection), title: profile.displayName, subtitle: profile.subtitle)
      }.prefix(Self.shown))
  }

  var body: some View {
    let rows = rows
    if !rows.isEmpty {
      KitSection("Recent", systemImage: "clock", hue: .gray) {
        ForEach(rows) { row in
          if let symbol = row.symbol {
            SidebarRow(value: tag(row.item), row.title, subtitle: row.subtitle, systemImage: symbol)
          } else {
            SidebarRow(value: tag(row.item), row.title, subtitle: row.subtitle) {
              app.connection(for: row.item.connectionID).liveTile(size: 22)
            }
          }
        }
      }
    }
  }
}
