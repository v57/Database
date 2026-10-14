import DatabaseKit
import Foundation
import Observation

/// What a sidebar row points at.
enum SidebarItem: Hashable {
  case connection(UUID)
  case node(UUID, TreeNode)
  case savedQuery(UUID, UUID)
  case queryTab(UUID, UUID)
}

/// One window's navigation: which connection and object are open, and the sheets.
@Observable @MainActor
final class WindowModel {
  enum Route: Equatable {
    case welcome
    case connection(UUID)
    case browse(UUID, ObjectRef)
    case query(UUID)
  }

  let app: AppModel
  var selection: SidebarItem? {
    didSet { route(for: selection) }
  }
  private(set) var route: Route = .welcome
  var showsInspector = true
  var showsNewConnection = false
  var editingProfileID: UUID?
  var searchText = ""

  init(app: AppModel) { self.app = app }

  var currentConnectionID: UUID? {
    switch route {
    case .welcome: nil
    case .connection(let id), .browse(let id, _), .query(let id): id
    }
  }

  var currentConnection: LiveConnection? { currentConnectionID.map { app.connection(for: $0) } }

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

  /// Opens a table or collection by reference (from a foreign-key link, for example).
  func open(_ ref: ObjectRef, in connectionID: UUID) {
    let connection = app.connection(for: connectionID)
    let node = connection.node(for: ref) ?? TreeNode(id: ref.id, title: ref.name, kind: .table, ref: ref)
    selection = .node(connectionID, node)
  }

  func newQuery() {
    guard let id = currentConnectionID else { return }
    let connection = app.connection(for: id)
    let node: TreeNode? = if case .node(_, let n) = selection { n } else { nil }
    let tab = connection.queries.newTab(context: connection.context(for: node))
    selection = .queryTab(id, tab.id)
  }

  func refresh() async {
    switch route {
    case .browse:
      await browser?.reload()
    case .connection(let id):
      await app.connection(for: id).refreshTree()
    case .query, .welcome:
      break
    }
  }

  func run() async {
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

  func connect(_ id: UUID) {
    selection = .connection(id)
  }
}
