import DatabaseCore
import SwiftUI

struct SidebarView: View {
  @Bindable var window: WindowModel
  @Environment(AppModel.self) private var app
  @State private var deleting: ConnectionProfile?

  private var profiles: [ConnectionProfile] {
    let query = window.searchText.trimmingCharacters(in: .whitespaces)
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

  var body: some View {
    List(selection: $window.selection) {
      Section {
        ForEach(profiles) { profile in
          ConnectionTree(connection: app.connection(for: profile.id), window: window) {
            deleting = profile
          }
        }
        .onMove { app.move(from: $0, to: $1) }
        if app.profiles.isEmpty {
          Button {
            window.showsNewConnection = true
          } label: {
            Label("Add a connection", systemImage: "plus.circle")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
        }
      } header: {
        HStack {
          Text("Connections")
          #if os(macOS)
            // On iPhone and iPad the toolbar's + does this.
            Spacer()
            Button {
              window.showsNewConnection = true
            } label: {
              Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Connection")
            .accessibilityLabel("New Connection")
          #endif
        }
      }
    }
    .listStyle(.sidebar)
    .searchable(text: $window.searchText, placement: .sidebar, prompt: "Search")
    .navigationTitle("Database Pro")
    .confirmationDialog(
      "Delete “\(deleting?.displayName ?? "")”?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete Connection", role: .destructive) {
        if let deleting {
          if window.currentConnectionID == deleting.id { window.selection = nil }
          app.delete(deleting.id)
        }
        deleting = nil
      }
    } message: {
      Text("This removes the saved connection and its password. The database itself isn't touched.")
    }
    #if os(iOS)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("New Connection", systemImage: "plus") { window.showsNewConnection = true }
        }
      }
    #endif
  }
}

/// A connection row that expands into its databases, tables and saved queries.
struct ConnectionTree: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  var onDelete: () -> Void
  @Environment(AppModel.self) private var app

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
    DisclosureGroup(isExpanded: isExpanded) {
      switch connection.status {
      case .connected:
        TreeChildren(connection: connection, parent: nil, window: window)
        QueryRows(connection: connection, window: window)
      case .connecting, .idle:
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Connecting…").foregroundStyle(.secondary)
        }
      case .failed(let message):
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(4)
      }
    } label: {
      ConnectionLabel(connection: connection)
        .tag(SidebarItem.connection(connection.id))
        .contextMenu { menu }
    }
  }

  @ViewBuilder private var menu: some View {
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
    Button("Copy Link", systemImage: "link") { Clipboard.copy(ConnectionLink.url(for: connection.profile)) }
    Divider()
    Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
  }
}

struct ConnectionLabel: View {
  let connection: LiveConnection

  var body: some View {
    HStack(spacing: 8) {
      EngineTile(engine: connection.profile.engine)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 5) {
          if let color = connection.profile.color.color {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
          }
          Text(connection.profile.displayName).fontWeight(.medium).lineLimit(1)
        }
        Text(connection.profile.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if connection.profile.isProduction {
        TagLabel(text: "Production", color: .red)
      }
      switch connection.status {
      case .connecting: ProgressView().controlSize(.mini)
      case .failed(let message):
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
      default: EmptyView()
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(connection.profile.displayName), \(connection.profile.engine.displayName)")
  }
}

/// Lazily loaded children of a tree node.
struct TreeChildren: View {
  let connection: LiveConnection
  let parent: TreeNode?
  @Bindable var window: WindowModel

  var body: some View {
    let key = connection.key(parent)
    if let nodes = connection.children[key] {
      if nodes.isEmpty {
        Text(emptyText).font(.caption).foregroundStyle(.secondary)
      }
      ForEach(nodes) { node in
        TreeNodeRow(connection: connection, node: node, window: window)
      }
    } else if let error = connection.treeErrors[key] {
      Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
    } else {
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Loading…").font(.caption).foregroundStyle(.secondary)
      }
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

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { connection.expanded.contains(node.id) },
      set: { open in
        if open { connection.expanded.insert(node.id) } else { connection.expanded.remove(node.id) }
      })
  }

  var body: some View {
    if node.hasChildren {
      DisclosureGroup(isExpanded: isExpanded) {
        TreeChildren(connection: connection, parent: node, window: window)
      } label: {
        label
      }
    } else {
      label.tag(SidebarItem.node(connection.id, node))
    }
  }

  private var label: some View {
    HStack(spacing: 6) {
      Image(systemName: node.symbol)
        .foregroundStyle(node.ref == nil ? Color.secondary : Color.accentColor)
        .imageScale(.small)
        .frame(width: 16)
      Text(node.title).lineLimit(1)
      Spacer(minLength: 4)
      if let detail = node.detail {
        Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// Saved queries and open query tabs under a connection.
struct QueryRows: View {
  let connection: LiveConnection
  @Bindable var window: WindowModel
  @Environment(AppModel.self) private var app

  var body: some View {
    let saved = app.queries(for: connection.id)
    let tabs = connection.queries.tabs.filter { $0.savedID == nil }
    if !saved.isEmpty || !tabs.isEmpty {
      DisclosureGroup {
        ForEach(saved) { query in
          Label(query.title, systemImage: "terminal")
            .lineLimit(1)
            .tag(SidebarItem.savedQuery(connection.id, query.id))
            .contextMenu {
              Button("Delete", systemImage: "trash", role: .destructive) { app.deleteQuery(query.id) }
            }
        }
        ForEach(tabs) { tab in
          Label(tab.title, systemImage: "doc.text")
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .tag(SidebarItem.queryTab(connection.id, tab.id))
        }
      } label: {
        Label("Queries", systemImage: "folder")
      }
    }
  }
}

enum Clipboard {
  static func copy(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }
}
