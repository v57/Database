import SwiftUI
import SwiftData
import MongoDB

/// Sidebar column: saved connections with Connect / Disconnect / Edit / Delete.
/// Selecting a row connects to it; the context menu has the full action set.
struct ConnectionsSidebarView: View {
    @Environment(DatabaseModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ConnectionRecord.name) private var records: [ConnectionRecord]

    @State private var selectedRecordID: ConnectionRecord.ID?
    @State private var showAddSheet = false
    @State private var editingRecord: ConnectionRecord?

    var body: some View {
        List(records, selection: $selectedRecordID) { record in
            ConnectionRow(record: record, isActive: isActive(record))
                .contextMenu {
                    Button("Connect") {
                        connect(record)
                    }
                    Button("Disconnect") {
                        Task { await model.disconnect() }
                    }
                    .disabled(model.session == nil)
                    Divider()
                    Button("Edit…") {
                        editingRecord = record
                    }
                    Button("Delete", role: .destructive) {
                        delete(record)
                    }
                }
        }
        .onChange(of: selectedRecordID) { _, newID in
            guard let newID else { return }
            if let record = records.first(where: { $0.id == newID }) {
                connect(record)
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "No Saved Connections",
                    systemImage: "cable.connector",
                    description: Text("Click + to add a MongoDB connection.")
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
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

    private func connect(_ record: ConnectionRecord) {
        guard !model.isConnecting else { return }
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