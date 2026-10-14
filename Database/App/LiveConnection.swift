import DatabaseKit
import Foundation
import Observation

/// One open (or opening) connection and its sidebar tree.
@Observable @MainActor
final class LiveConnection: Identifiable {
  enum Status: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
  }

  var profile: ConnectionProfile
  private(set) var status: Status = .idle
  private(set) var session: DatabaseSession?
  private(set) var report: ConnectionReport?
  /// Children by parent node id ("" for the top level).
  private(set) var children: [String: [TreeNode]] = [:]
  private(set) var loading: Set<String> = []
  private(set) var treeErrors: [String: String] = [:]
  var expanded: Set<String> = []
  /// Open browsers, kept so switching back keeps filters and scroll.
  private var browsers: [String: BrowserModel] = [:]
  @ObservationIgnored private weak var app: AppModel?
  /// Open query tabs.
  @ObservationIgnored private(set) lazy var queries = QueryWorkspace(connection: self)
  @ObservationIgnored private var connectTask: Task<Void, Never>?

  var id: UUID { profile.id }

  init(profile: ConnectionProfile, app: AppModel) {
    self.profile = profile
    self.app = app
  }

  var isConnected: Bool { status == .connected }

  /// Connects once; later calls wait for the same attempt.
  func connect() async {
    if status == .connected { return }
    if let connectTask {
      await connectTask.value
      return
    }
    let task = Task { await performConnect() }
    connectTask = task
    await task.value
    connectTask = nil
  }

  private func performConnect() async {
    guard let app else { return }
    status = .connecting
    if let latest = app.profile(profile.id) { profile = latest }
    do {
      let (session, report) = try await Connector.connect(profile, credentials: app.credentials(for: profile))
      self.session = session
      self.report = report
      status = .connected
      app.rememberHostKey(report.sshHostKeyFingerprint, for: profile.id)
      app.markUsed(profile.id)
      session.onTunnelClosed { [weak self] reason in
        Task { @MainActor in self?.tunnelClosed(reason) }
      }
      await loadChildren(of: nil)
      expanded.insert(Self.rootID)
    } catch {
      status = .failed(FriendlyError.message(error))
    }
  }

  private func tunnelClosed(_ reason: String?) {
    guard status == .connected else { return }
    status = .failed(reason ?? "The SSH tunnel closed.")
    session = nil
  }

  func close() async {
    connectTask?.cancel()
    await session?.close()
    session = nil
    status = .idle
    children = [:]
    browsers = [:]
  }

  func reconnect() async {
    await close()
    await connect()
  }

  static let rootID = "root"

  func key(_ node: TreeNode?) -> String { node?.id ?? Self.rootID }

  func loadChildren(of node: TreeNode?, force: Bool = false) async {
    guard let session else { return }
    let key = key(node)
    if !force, children[key] != nil { return }
    loading.insert(key)
    defer { loading.remove(key) }
    do {
      children[key] = try await session.children(of: node)
      treeErrors[key] = nil
    } catch {
      treeErrors[key] = FriendlyError.message(error)
    }
  }

  func refreshTree() async {
    let open = expanded
    children = [:]
    await loadChildren(of: nil, force: true)
    // Reload what was open, level by level.
    var frontier = children[Self.rootID] ?? []
    while !frontier.isEmpty {
      var next: [TreeNode] = []
      for node in frontier where open.contains(node.id) && node.hasChildren {
        await loadChildren(of: node, force: true)
        next += children[node.id] ?? []
      }
      frontier = next
    }
  }

  func browser(for ref: ObjectRef) -> BrowserModel {
    if let existing = browsers[ref.id] { return existing }
    let browser = BrowserModel(connection: self, ref: ref)
    browsers[ref.id] = browser
    return browser
  }

  /// Finds a node already loaded in the tree.
  func node(for ref: ObjectRef) -> TreeNode? {
    for list in children.values {
      if let node = list.first(where: { $0.ref == ref }) { return node }
    }
    return nil
  }

  /// The query context for a selected node.
  func context(for node: TreeNode?) -> QueryContext {
    guard let node else {
      return QueryContext(database: profile.database.isEmpty ? nil : profile.database)
    }
    return QueryContext(
      database: node.database ?? node.ref?.database, schema: node.schema ?? node.ref?.schema,
      collection: node.ref?.kind == .collection ? node.ref?.name : nil)
  }
}

extension DatabaseSession {
  /// Calls back when this session's SSH tunnel drops.
  func onTunnelClosed(_ handler: @escaping @Sendable (String?) -> Void) {
    (self as? TunnelOwning)?.tunnel?.onClosed(handler)
  }
}
