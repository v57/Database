import Database
import MongoDB
import PostgreSQL
import Redis
import SQLite
import SwiftData
import SwiftUI

/// One selectable sidebar row. Hashable so a native `List(selection:)` drives
/// the system highlight and arrow-key navigation. Collections carry their
/// database because the same name can exist in several databases.
enum SidebarItem: Hashable {
  case connection(PersistentIdentifier)
  case database(String)
  case collection(database: String, name: String)
}

/// Sidebar column: saved connections; under the active connection, its
/// databases with collections nested inside (folded by default). Selecting a
/// connection connects; expanding a database lazily loads its collections;
/// selecting a collection loads its documents into the middle column.
struct ConnectionsSidebarView: View {
  @Environment(DatabaseModel.self) private var model
  @Environment(\.modelContext) private var modelContext
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.openURL) private var openURL
  @Query(sort: \ConnectionRecord.name) private var records: [ConnectionRecord]

  @State private var selection: SidebarItem?
  /// Databases the user has expanded; collections stay folded until then.
  @State private var expandedDatabases: Set<String> = []
  @State private var showAddSheet = false
  @State private var editingRecord: ConnectionRecord?
  /// Drives the delete confirmation (deleting a saved connection can't be undone).
  @State private var recordPendingDeletion: ConnectionRecord?
  /// The record whose connect is in flight, so its row can show a spinner.
  @State private var connectingRecordID: ConnectionRecord.ID?
  /// The record whose last connect failed, so the alert can name it and
  /// offer to edit it. Nil when the failing connect came from elsewhere.
  @State private var failedRecordID: ConnectionRecord.ID?

  /// iPhone-width split view: ANY list selection pushes the detail column, so
  /// only collections are selectable there; connections are plain buttons and
  /// databases only fold. (nil on macOS, where everything stays selectable.)
  private var isCompact: Bool { horizontalSizeClass == .compact }

  var body: some View {
    @Bindable var model = model
    List(selection: $selection) {
      connectionsSection
      if model.isSessionActive { databasesSection }
    }.listStyle(.sidebar).searchable(
      text: $model.collectionSearch, placement: .sidebar, prompt: searchPrompt
    ).navigationSplitViewColumnWidth(min: 200, ideal: 250).sheet(isPresented: $showAddSheet) {
      ConnectionFormView(onConnect: connectFromForm)
    }.sheet(item: $editingRecord) { record in
      ConnectionFormView(record: record, onConnect: connectFromForm)
    }.focusedSceneValue(\.isAddingConnection, $showAddSheet).confirmationDialog(
      "Delete “\(recordPendingDeletion?.name ?? "")”?", isPresented: deleteConfirmationBinding,
      titleVisibility: .visible, presenting: recordPendingDeletion
    ) { record in
      Button("Delete", role: .destructive) { delete(record) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("This removes the saved connection.")
    }.alert(
      connectionErrorTitle, isPresented: connectionErrorBinding, presenting: model.connectionError
    ) { _ in
      if model.friendlyConnectionError?.requiresEncryption == true,
        let upgrade = EncryptionNotice.upgradeURL
      {
        Button("Get \(EncryptionNotice.upgradeName)") {
          clearConnectionError()
          openURL(upgrade)
        }
      }
      if let record = failedRecord {
        Button("Edit Connection…") {
          clearConnectionError()
          editingRecord = record
        }
      }
      Button("OK", role: .cancel) { clearConnectionError() }
    } message: { _ in
      Text(model.friendlyConnectionError.map { Self.alertText($0) } ?? "")
    }.onChange(of: selection) { _, newValue in selectionChanged(to: newValue) }.task(id: selection)
    {
      await connectSelectedRecord()
    }.onChange(of: model.selectedCollection) { syncSelectionFromModel() }.onChange(
      of: model.selectedDatabase
    ) { _, database in
      // The open database starts unfolded: after connecting (SQLite's single
      // `main` included) its tables are one click away, not two.
      if let database { expandedDatabases.insert(database) }
      syncSelectionFromModel()
    }.onChange(of: model.isSessionActive) { _, isActive in
      sessionActivityChanged(isActive)
    }.onAppear { syncSelectionFromModel() }.task(id: model.collectionSearch) {
      await loadCollectionsForSearch()
    }.animation(.smooth(duration: 0.25), value: model.isSessionActive)
  }

  // MARK: - Sections

  private var connectionsSection: some View {
    Section {
      if records.isEmpty {
        if isCompact {
          // iPhone shows the sidebar first, so the welcome choices live here.
          WelcomeActions().listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowBackground(Color.clear)
        } else {
          Text("No saved connections yet.").foregroundStyle(.secondary)
        }
      }
      ForEach(records) { record in
        let active = isActive(record)
        let row = ConnectionRow(
          record: record, isActive: active, isConnecting: connectingRecordID == record.id,
          disconnect: disconnect)
        Group {
          if isCompact {
            Button { connectIfInactive(record.id) } label: { row }.buttonStyle(.plain)
          } else {
            row.tag(SidebarItem.connection(record.id))
          }
        }.contextMenu {
          Button("Connect") {
            if !isCompact { selection = .connection(record.id) }
            connect(record)
          }.disabled(active || connectingRecordID != nil)
          Button("Disconnect") { disconnect() }.disabled(!active)
          Divider()
          Button("Edit…") { editingRecord = record }
          Button("Delete…", role: .destructive) { recordPendingDeletion = record }
        }
      }
    } header: {
      HStack {
        Text("Connections")
        Spacer()
        Button("Add Connection", systemImage: "plus") { showAddSheet = true }.buttonStyle(
          .borderless
        ).labelStyle(.iconOnly).help("Add Connection (⌘N)")
      }
    }
  }

  @ViewBuilder private var databasesSection: some View {
    if let only = singleFileDatabase {
      // A SQLite file has one database, "main": list its tables directly
      // rather than under a name that means nothing to most people.
      Section("Tables") { collectionChildren(for: only) }
    } else {
      databasesList
    }
  }

  /// The one database of a SQLite file, while no database search is typed.
  private var singleFileDatabase: String? {
    guard model.activeEngine == .sqlite, model.databases.count == 1,
      !model.searchTerms.hasDatabaseTerms
    else { return nil }
    return model.databases.first
  }

  private var databasesList: some View {
    Section(model.activeEngine == .redis ? "Databases (numbered)" : "Databases") {
      if visibleDatabases.isEmpty { emptyDatabasesText.foregroundStyle(.secondary) }
      ForEach(visibleDatabases, id: \.self) { db in
        // While searching: force-expand every database that has matches
        // (the search task already loaded their collections).
        DisclosureGroup(isExpanded: isSearching ? .constant(true) : expandedBinding(for: db)) {
          collectionChildren(for: db)
        } label: {
          Label(db, systemImage: "cylinder.split.1x2")
        }.modifier(SelectableTag(item: .database(db), isEnabled: !isCompact))
      }
    }
  }

  // MARK: - Search

  /// Names what the field searches for the live engine ("Tables or
  /// $database"); before connecting there is nothing to search yet.
  private var searchPrompt: String {
    guard model.isSessionActive else { return "Connect to search" }
    if singleFileDatabase != nil { return "Search \(model.containerNoun.plural)" }
    return "\(model.containerNoun.plural.capitalized) or $database"
  }

  /// True while the search field is active: databases are force-expanded
  /// and non-matching databases are hidden.
  private var isSearching: Bool { model.searchTerms.isSearching }

  /// Databases shown in the sidebar:
  /// - `$name` terms filter by database name (AND).
  /// - plain terms keep only databases with at least one matching
  ///   collection (collections are loaded while searching).
  private var visibleDatabases: [String] {
    let terms = model.searchTerms
    return model.sortedDatabases.filter { db in
      guard matchesDatabaseTerms(db, terms) else { return false }
      if terms.collectionTerms.isEmpty { return true }
      return !model.collections(for: db).isEmpty
    }
  }

  private func matchesDatabaseTerms(_ db: String, _ terms: SearchTerms) -> Bool {
    terms.databaseTerms.allSatisfy { db.localizedCaseInsensitiveContains($0) }
  }

  /// Search needs collections of every database it can show. Debounced so
  /// typing doesn't fan out a listing per keystroke, and skipped entirely
  /// for an empty search (nothing is force-expanded then).
  private func loadCollectionsForSearch() async {
    guard isSearching else { return }
    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
    let terms = model.searchTerms
    for db in model.sortedDatabases where matchesDatabaseTerms(db, terms) {
      guard !Task.isCancelled else { return }
      await model.loadCollections(for: db)
    }
  }

  private var emptyDatabasesText: Text {
    let terms = model.searchTerms
    if terms.hasDatabaseTerms {
      return Text("No matching databases")
    } else if model.databases.isEmpty {
      return Text("No databases on server")
    }
    return Text("No matching \(model.containerNoun.plural)")
  }

  // MARK: - Databases & collections

  @ViewBuilder private func collectionChildren(for db: String) -> some View {
    let colls = model.collections(for: db)
    let noun = model.containerNoun.plural
    if colls.isEmpty {
      Text(isSearching ? "No matching \(noun)" : "No \(noun)").foregroundStyle(.secondary)
    } else {
      ForEach(colls, id: \.self) { coll in
        Label(coll, systemImage: model.activeEngine == .redis ? "key.horizontal" : "tablecells")
          .tag(SidebarItem.collection(database: db, name: coll))
      }
      if model.isKeyListTruncated(db) {
        Text("Showing the first \(DatabaseModel.redisKeyLimit) keys — use the key filter to find others.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func expandedBinding(for db: String) -> Binding<Bool> {
    Binding(
      get: { expandedDatabases.contains(db) },
      set: { expanded in
        if expanded {
          expandedDatabases.insert(db)
          Task { await model.loadCollections(for: db) }
        } else {
          expandedDatabases.remove(db)
        }
      })
  }

  // MARK: - Selection

  /// Collections open immediately. Connections go through the debounced
  /// `connectSelectedRecord()` so arrowing past a row doesn't connect to it.
  /// Database rows only highlight; their chevron (or ←/→) folds them.
  private func selectionChanged(to item: SidebarItem?) {
    // Clicking a database row unfolds it (a highlight alone did nothing).
    if case .database(let db)? = item, !expandedDatabases.contains(db) {
      expandedBinding(for: db).wrappedValue = true
    }
    guard case .collection(let db, let name)? = item else { return }
    // Already open (e.g. the selection was just synced FROM the model).
    guard model.selectedDatabase != db || model.selectedCollection != name else { return }
    Task { await model.select(collection: name, in: db) }
  }

  /// Runs per selection change; cancelled when the selection moves on, so
  /// only a connection row that stays selected briefly gets connected.
  private func connectSelectedRecord() async {
    guard case .connection(let id)? = selection else { return }
    // A row that was already live is a highlight synced from the model, not
    // a pick: don't reconnect it if the model switches away meanwhile (a
    // file opened from Finder while this window was appearing).
    let wasActive = records.first { $0.id == id }.map(isActive) ?? false
    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
    guard !wasActive else { return }
    connectIfInactive(id)
  }

  /// Selecting the ACTIVE connection does nothing (disconnect is explicit:
  /// the row's eject button or the context menu).
  private func connectIfInactive(_ id: ConnectionRecord.ID) {
    guard let record = records.first(where: { $0.id == id }), !isActive(record) else { return }
    connect(record)
  }

  /// Mirrors the model's open collection into the list highlight (it can
  /// change from the documents pane, or be cleared by a disconnect).
  private func syncSelectionFromModel() {
    if let db = model.selectedDatabase, let coll = model.selectedCollection {
      let item = SidebarItem.collection(database: db, name: coll)
      if selection != item { selection = item }
    } else if case .collection? = selection {
      selection = nil
    } else if selection == nil, !isCompact, let active = records.first(where: isActive) {
      selection = .connection(active.id)
    }
  }

  /// On disconnect, drop the highlight of rows that no longer exist and of
  /// the closed connection — otherwise clicking it again would not change the
  /// selection and could not reconnect. While switching connections (the
  /// model disconnects first) the newly picked row stays selected.
  private func sessionActivityChanged(_ isActive: Bool) {
    guard !isActive else { return }
    expandedDatabases = []
    switch selection {
    case .database?, .collection?: selection = nil
    case .connection?: if connectingRecordID == nil { selection = nil }
    case nil: break
    }
  }

  // MARK: - Connection actions

  /// Connects to `record`. One attempt at a time: a row picked while another
  /// attempt runs is connected when that attempt finishes.
  private func connect(_ record: ConnectionRecord) {
    guard connectingRecordID == nil, !model.isConnecting else { return }
    let id = record.id
    connectingRecordID = id
    failedRecordID = nil
    let settings = record.toSettings()
    Task {
      await model.connect(settings)
      connectingRecordID = nil
      if model.connectionError != nil {
        failedRecordID = id
        // Unselect so clicking the row again retries.
        if selection == .connection(id) { selection = nil }
      }
      if case .connection(let next)? = selection, next != id { connectIfInactive(next) }
    }
  }

  /// The form's "Save & Connect" (and reconnect-after-edit) goes through the
  /// sidebar so the row shows progress and a failure alert can name it.
  private func connectFromForm(_ record: ConnectionRecord) {
    if !isCompact { selection = .connection(record.id) }
    connect(record)
  }

  private func disconnect() { Task { await model.disconnect() } }

  private func delete(_ record: ConnectionRecord) {
    if isActive(record) { disconnect() }
    if selection == .connection(record.id) { selection = nil }
    modelContext.delete(record)
    try? modelContext.save()
  }

  /// A record is "active" when the live session was started from it.
  private func isActive(_ record: ConnectionRecord) -> Bool {
    record.matchesLiveSession(of: model)
  }

  // MARK: - Dialog plumbing

  private var deleteConfirmationBinding: Binding<Bool> {
    Binding(
      get: { recordPendingDeletion != nil },
      set: { if !$0 { recordPendingDeletion = nil } })
  }

  private var failedRecord: ConnectionRecord? {
    failedRecordID.flatMap { id in records.first { $0.id == id } }
  }

  /// "Can't reach the server" — the plain cause, not just "couldn't connect".
  private var connectionErrorTitle: String {
    let cause = model.friendlyConnectionError?.title
    if let cause, let record = failedRecord { return "\(record.name): \(cause)" }
    return cause ?? "Couldn’t Connect"
  }

  /// The alert body: what happened, what to try, then the original message.
  private static func alertText(_ error: FriendlyError) -> String {
    var parts = [error.message]
    if let suggestion = error.suggestion { parts.append(suggestion) }
    if !error.detailsRepeatMessage { parts.append("Details: \(error.details)") }
    return parts.joined(separator: "\n\n")
  }

  private var connectionErrorBinding: Binding<Bool> {
    Binding(
      get: { model.connectionError != nil },
      set: { if !$0 { clearConnectionError() } })
  }

  private func clearConnectionError() {
    model.connectionError = nil
    model.connectionErrorHost = nil
    failedRecordID = nil
  }
}

/// One connection row: engine glyph + name; the active connection adds a
/// green dot (shape, not just colour) and an explicit eject button; the row
/// being connected shows a spinner.
private struct ConnectionRow: View {
  let record: ConnectionRecord
  let isActive: Bool
  let isConnecting: Bool
  let disconnect: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Label(record.name, systemImage: record.engineKind.systemImage).lineLimit(1)
        .accessibilityLabel("\(record.name), \(record.engineKind.displayName)")
        .accessibilityValue(statusText)
      Spacer(minLength: 0)
      if isConnecting {
        ProgressView().controlSize(.small).accessibilityLabel("Connecting")
      } else if isActive {
        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green).help(
          "Connected"
        ).accessibilityHidden(true)
        Button(action: disconnect) {
          Label("Disconnect", systemImage: "eject").labelStyle(.iconOnly).touchTarget()
        }.buttonStyle(.borderless).help("Disconnect from \(record.name)")
          .accessibilityLabel("Disconnect from \(record.name)")
      }
    }.help(locationText)
  }

  /// Spoken status; the dot itself is hidden from VoiceOver to avoid repeats.
  private var statusText: String {
    if isConnecting { return "Connecting" }
    return isActive ? "Connected" : ""
  }

  private var locationText: String {
    record.engineKind == .sqlite
      ? "\(record.engineKind.displayName) · \(record.host)"
      : "\(record.engineKind.displayName) · \(record.host):\(record.port)"
  }
}

#Preview {
  let container = try! ModelContainer(
    for: ConnectionRecord.self, DatabaseOpenRecord.self, CollectionOpenRecord.self)
  return ContentView(
    model: DatabaseModel(modelContext: container.mainContext), container: container)
}

/// Tags a row for `List(selection:)` only when `isEnabled` — compact layouts
/// keep non-collection rows out of the selection (see `isCompact`).
private struct SelectableTag: ViewModifier {
  let item: SidebarItem
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled { content.tag(item) } else { content }
  }
}
