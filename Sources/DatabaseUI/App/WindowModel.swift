import DatabaseKit
import Foundation
import Observation
import VaultKit

/// What a sidebar row points at.
public nonisolated enum SidebarItem: Hashable, Sendable {
  case connection(UUID)
  case node(UUID, TreeNode)
  case savedQuery(UUID, UUID)
  case queryTab(UUID, UUID)

  /// The connection the row belongs to.
  public var connectionID: UUID {
    switch self {
    case .connection(let id), .node(let id, _), .savedQuery(let id, _), .queryTab(let id, _): id
    }
  }
}

/// One window's navigation: which connection and object are open, and the sheets.
@Observable @MainActor
public final class WindowModel {
  public enum Route: Equatable {
    case welcome
    case connection(UUID)
    case browse(UUID, ObjectRef)
    case query(UUID)

    var connectionID: UUID? {
      switch self {
      case .welcome: nil
      case .connection(let id), .browse(let id, _), .query(let id): id
      }
    }
  }

  public let app: DatabaseModel
  public var selection: SidebarItem? {
    didSet {
      route(for: selection)
      if selection != oldValue { onSelect?(selection) }
    }
  }
  /// Counts `open` calls: on iPhone a row tapped again shows its screen again, though the selection (still the row,
  /// after Back) doesn't change (D-025).
  public private(set) var openCount = 0

  /// A sidebar row picked: selects it and counts the open, so the phone shows its screen even when it was selected
  /// already (D-025).
  public func open(_ item: SidebarItem?) {
    selection = item
    if item != nil { openCount += 1 }
  }

  /// Called when the selection changes, by a row or from inside (a new query tab, a foreign key's table), for apps
  /// whose own sidebar shows the tree (Shell).
  @ObservationIgnored public var onSelect: ((SidebarItem?) -> Void)?
  public private(set) var route: Route = .welcome {
    didSet {
      let id = route.connectionID
      if id != currentConnectionID { currentConnectionID = id }
    }
  }
  public var showsInspector = true
  public var showsNewConnection = false
  /// The SSH host a new connection starts out going through (Shell's per-host New Database).
  public var newConnectionHost: VaultHost?
  public var editingProfileID: UUID?
  var searchText = ""

  public init(app: DatabaseModel) { self.app = app }

  /// The open connection's id. Kept apart from `route` and set only when it changes, so a view showing the connection
  /// (the sidebar's card) doesn't update each time another table or tab of it opens.
  public private(set) var currentConnectionID: UUID?

  public var currentConnection: LiveConnection? { currentConnectionID.map { app.connection(for: $0) } }

  var browser: BrowserModel? {
    if case .browse(let id, let ref) = route { return app.connection(for: id).browser(for: ref) }
    return nil
  }

  var queries: QueryWorkspace? {
    if case .query(let id) = route { return app.connection(for: id).queries }
    return nil
  }

  private func route(for item: SidebarItem?) {
    switch item {
    case nil: break
    case .connection(let id):
      route = .connection(id)
      let connection = app.connection(for: id)
      Task { await connection.connect() }
    case .node(let id, let node):
      if let ref = node.ref {
        route = .browse(id, ref)
        let browser = app.connection(for: id).browser(for: ref)
        if browser.page == nil { Task { await browser.load() } }
      }
    case .savedQuery(let id, let queryID):
      let connection = app.connection(for: id)
      if let saved = app.savedQueries.first(where: { $0.id == queryID }) { connection.queries.open(saved) }
      route = .query(id)
    case .queryTab(let id, let tabID):
      app.connection(for: id).queries.selectedID = tabID
      route = .query(id)
    }
  }

  /// Leaves a connection that was closed or deleted: while the window shows it, the selection goes and the detail
  /// returns to the welcome, rather than showing a table of a connection that's gone (D-016) or connecting it again
  /// (D-003: an empty selection alone left the route, whose card read "Connecting…").
  public func leave(_ id: UUID) {
    guard currentConnectionID == id else { return }
    selection = nil
    route = .welcome
  }

  /// Opens a table or collection by reference (from a foreign-key link, for example).
  func open(_ ref: ObjectRef, in connectionID: UUID) {
    let connection = app.connection(for: connectionID)
    let node = connection.node(for: ref) ?? TreeNode(id: ref.id, title: ref.name, kind: .table, ref: ref)
    selection = .node(connectionID, node)
  }

  public func newQuery() {
    guard let id = currentConnectionID else { return }
    let connection = app.connection(for: id)
    let node: TreeNode? = if case .node(_, let n) = selection { n } else { nil }
    let tab = connection.queries.newTab(context: connection.context(for: node))
    selection = .queryTab(id, tab.id)
  }

  public func refresh() async {
    switch route {
    case .browse:
      await browser?.reload()
    case .connection(let id):
      await app.connection(for: id).refreshTree()
    case .query, .welcome:
      break
    }
  }

  public func run() async {
    if let queries {
      await queries.runSelected()
    } else if let browser {
      if browser.mode == .aggregate {
        await browser.pipeline.run()
      } else if browser.showsQueryEditor {
        await browser.runQuery()
      } else {
        await browser.reload()
      }
    }
  }

  /// Opens the New Connection sheet, going through `host` when given.
  public func newConnection(through host: VaultHost? = nil) {
    newConnectionHost = host
    showsNewConnection = true
  }

  public func connect(_ id: UUID) {
    selection = .connection(id)
  }
}
