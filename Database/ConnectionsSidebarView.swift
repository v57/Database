import MongoDB
import SwiftData
import SwiftUI

/// Sidebar column: saved connections; under the active connection, its
/// databases with collections nested inside (folded by default). Selecting a
/// connection connects; expanding a database lazily loads its collections;
/// selecting a collection loads its documents into the middle column.
struct ConnectionsSidebarView: View {
  @Environment(DatabaseModel.self) private var model
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \ConnectionRecord.name) private var records: [ConnectionRecord]

  @State private var selectedRecordID: ConnectionRecord.ID?
  /// Databases the user has expanded; collections stay folded until then.
  @State private var expandedDatabases: Set<String> = []
  @State private var showAddSheet = false
  @State private var editingRecord: ConnectionRecord?

  var body: some View {
    @Bindable var model = model
    ScrollView {
      LazyVStack {
        Section {
          if records.isEmpty {
            Text("No saved connections — use + to add one.").foregroundStyle(.secondary)
          }
          ForEach(records) { record in
            Button {
              selectConnection(record)
            } label: {
              ConnectionRow(record: record, isActive: isActive(record)).frame(
                maxWidth: .infinity, alignment: .leading
              ).background(.black.opacity(0.001))
            }.buttonStyle(.plain).contextMenu {
              Button("Connect") { selectConnection(record) }
              Button("Disconnect") { Task { await model.disconnect() } }.disabled(
                model.session == nil)
              Divider()
              Button("Edit…") { editingRecord = record }
              Button("Delete", role: .destructive) { delete(record) }
            }
          }
        } header: {
          HStack {
            Text("Connections")
              .frame(maxWidth: .infinity, alignment: .leading)
            Button("Add", systemImage: "plus") {
              showAddSheet = true
            }.buttonStyle(.plain).labelStyle(.iconOnly)
              .help("Add Connection")
          }.foregroundStyle(.secondary).font(.caption)
            .padding(.horizontal, 8)
        }
        
        if model.session != nil {
          Section {
            if visibleDatabases.isEmpty { emptyDatabasesText.foregroundStyle(.secondary) }
            ForEach(visibleDatabases, id: \.self) { db in
              // While searching: force-expand every database that
              // has matches (the search field already triggered
              // loading collections for all databases).
              let isExpanded = isSearching ? .constant(true) : expandedBinding(for: db)
              Button {
                withAnimation(.smooth(duration: 0.25)) {
                  isExpanded.wrappedValue.toggle()
                }
              } label: {
                Label(db, systemImage: "cylinder.split.1x2.fill")
                  .tint(isExpanded.wrappedValue ? .blue : .secondary)
              }.buttonStyle(.plain)
              if isExpanded.wrappedValue {
                collectionChildren(for: db)
                  .transition(.blurReplace)
              }
            }
          } header: {
            Text("Databases")
              .frame(maxWidth: .infinity, alignment: .leading)
              .foregroundStyle(.secondary).font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
          }.transition(.blurReplace)
        }
      }
    }.safeAreaPadding(.horizontal, 10).searchable(text: $model.collectionSearch, placement: .sidebar)
      .navigationSplitViewColumnWidth(min: 200, ideal: 250).sheet(isPresented: $showAddSheet) { ConnectionFormView() }.sheet(item: $editingRecord) {
      record in ConnectionFormView(record: record)
    }.animation(.smooth(duration: 0.25), value: model.session != nil).animation(
      .smooth(duration: 0.25), value: model.databases.count)
    .task(id: model.collectionSearch) {
      do {
        try await Task.sleep(for: .milliseconds(100))
        await model.loadAllCollections()
      } catch { }
    }.labelStyle(SidebarLabelStyle())
  }

  // MARK: - Sidebar actions

  /// True while the search field is active: databases are force-expanded
  /// and non-matching databases are hidden.
  private var isSearching: Bool { model.searchTerms.isSearching }

  /// Databases shown in the sidebar:
  /// - `$name` terms filter by database name (AND).
  /// - plain terms keep only databases with at least one matching
  ///   collection (all databases are loaded on search).
  private var visibleDatabases: [String] {
    let terms = model.searchTerms
    return model.sortedDatabases.filter { db in
      let dbMatches =
        terms.hasDatabaseTerms
        ? terms.databaseTerms.allSatisfy { db.localizedCaseInsensitiveContains($0) } : true
      guard dbMatches else { return false }
      if terms.collectionTerms.isEmpty { return true }
      return !model.collections(for: db).isEmpty
    }
  }

  private var emptyDatabasesText: Text {
    let terms = model.searchTerms
    if terms.hasDatabaseTerms {
      return Text("No matching databases")
    } else if model.databases.isEmpty {
      return Text("No databases on server")
    }
    return Text("No matching collections")
  }

  @ViewBuilder private func collectionChildren(for db: String) -> some View {
    let colls = model.collections(for: db)
    if colls.isEmpty {
      Text(isSearching ? "No matching collections" : "No collections").foregroundStyle(.secondary)
    } else {
      ForEach(colls, id: \.self) { coll in collectionRow(coll, in: db) }
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

  private func collectionRow(_ coll: String, in db: String) -> some View {
    let isSelected = model.selectedCollection == coll && model.selectedDatabase == db
    return Label(coll, systemImage: "tablecells.fill")
      .tint(isSelected ? .blue : .secondary)
      .onTapGesture {
      Task { await model.select(collection: coll, in: db) }
    }
  }

  private func selectConnection(_ record: ConnectionRecord) {
    guard !model.isConnecting else { return }
    selectedRecordID = record.id
    Task { await model.connect(record.toConfig()) }
  }

  private func delete(_ record: ConnectionRecord) {
    if isActive(record) { Task { await model.disconnect() } }
    if selectedRecordID == record.id { selectedRecordID = nil }
    modelContext.delete(record)
    try? modelContext.save()
  }

  /// A record is "active" when the live session was started from it.
  /// ConnectionConfig regenerates its UUID on every toConfig() call, so the
  /// id can't be compared — match by name + host + port instead.
  private func isActive(_ record: ConnectionRecord) -> Bool {
    guard let session = model.session, session.isConnected else { return false }
    let c = session.config
    return c.name == record.name && c.host == record.host && c.port == UInt16(record.port)
  }
}

/// One sidebar row: name + host:port subtitle + status dot (green = active session).
private struct ConnectionRow: View {
  let record: ConnectionRecord
  let isActive: Bool
  
  var body: some View {
    HStack(spacing: 8) {
      Label(record.name, systemImage: isActive ? "wifi" : "wifi.slash")
        .tint(isActive ? .blue : .secondary)
    }
  }
}

struct SidebarLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline) {
      configuration.icon.foregroundStyle(.tint)
        .contentTransition(.symbolEffect)
        .frame(width: 16)
      configuration.title
        .contentTransition(.numericText())
    }.padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05)))
  }
}

#Preview {
  ContentView()
}
