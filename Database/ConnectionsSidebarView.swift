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
        VStack(spacing: 0) {
            if model.session != nil {
                TextField("Filter collections…", text: $model.collectionSearch)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .onChange(of: model.collectionSearch) { _, _ in
                        Task { await model.loadAllCollections() }
                    }
            }
            List {
                Section("Connections") {
                    if records.isEmpty {
                        Text("No saved connections — use + to add one.")
                            .foregroundStyle(.secondary)
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
                            Text(isSearching ? "No matching collections" : "No databases on server")
                                .foregroundStyle(.secondary)
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

    /// True while the collection filter is active: databases are force-expanded
    /// and databases without matches are hidden.
    private var isSearching: Bool {
        !model.collectionSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Databases shown in the sidebar: while searching, only those with at
    /// least one matching collection (all databases are loaded on search).
    private var visibleDatabases: [String] {
        if isSearching {
            return model.databases.filter { !model.collections(for: $0).isEmpty }
        }
        return model.databases
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
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name)
                Text("\(record.host):\(record.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
