import SwiftUI
import SwiftData
import MongoDB

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
        List {
            Section {
                if records.isEmpty {
                    Text("No saved connections — use + to add one.").foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    ConnectionRow(record: record, isActive: isActive(record))
                        .contentShape(Rectangle())
                        .onTapGesture { selectConnection(record) }
                        .listRowBackground(
                            selectedRecordID == record.id
                            ? Color.accentColor.opacity(0.12) : nil
                        )
                        .contextMenu {
                            Button("Connect") { selectConnection(record) }
                            Button("Disconnect") {
                                Task { await model.disconnect() }
                            }
                            .disabled(model.session == nil)
                            Divider()
                            Button("Edit…") { editingRecord = record }
                            Button("Delete", role: .destructive) { delete(record) }
                        }
                }
            }
            
            if model.session != nil {
                Section("Databases") {
                    if visibleDatabases.isEmpty {
                        emptyDatabasesText.foregroundStyle(.secondary)
                    }
                    ForEach(visibleDatabases, id: \.self) { db in
                        // While searching: force-expand every database that
                        // has matches (the search field already triggered
                        // loading collections for all databases).
                        DisclosureGroup(isExpanded: isSearching ? .constant(true) : expandedBinding(for: db)) {
                            collectionChildren(for: db)
                        } label: {
                            Label(db, systemImage: "cylinder")
                        }
                    }
                }
            }
        }.safeAreaBar(edge: .top) {
            if model.session != nil {
                TextField("Search", text: $model.collectionSearch)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .onChange(of: model.collectionSearch) { _, _ in
                        Task { await model.loadAllCollections() }
                    }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        .toolbar {
            ToolbarItem {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Connection", systemImage: "plus")
                }
                .help("Add Connection")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ConnectionFormView()
        }
        .sheet(item: $editingRecord) { record in
            ConnectionFormView(record: record)
        }
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
            let dbMatches = terms.hasDatabaseTerms
                ? terms.databaseTerms.allSatisfy { db.localizedCaseInsensitiveContains($0) }
                : true
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

    @ViewBuilder
    private func collectionChildren(for db: String) -> some View {
        let colls = model.collections(for: db)
        if colls.isEmpty {
            Text(isSearching ? "No matching collections" : "No collections")
                .foregroundStyle(.secondary)
        } else {
            ForEach(colls, id: \.self) { coll in
                collectionRow(coll, in: db)
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
            }
        )
    }

    private func collectionRow(_ coll: String, in db: String) -> some View {
        let isSelected = model.selectedCollection == coll && model.selectedDatabase == db
        return Label(coll, systemImage: "shippingbox")
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await model.select(collection: coll, in: db) }
            }
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
    }

    private func selectConnection(_ record: ConnectionRecord) {
        guard !model.isConnecting else { return }
        selectedRecordID = record.id
        Task { await model.connect(record.toConfig()) }
    }

    private func delete(_ record: ConnectionRecord) {
        if isActive(record) {
            Task { await model.disconnect() }
        }
        if selectedRecordID == record.id {
            selectedRecordID = nil
        }
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
            Circle().fill(isActive ? Color.green : Color.secondary.opacity(0.35)).frame(width: isActive ? 7 : 5, height: isActive ? 7 : 5)
            Text(record.name)
        }
    }
}
