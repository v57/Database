import SwiftUI
import MongoDB

/// Merged item-list + preview screen: documents render as expanded
/// $key/$value cell rows (nested values flattened with depth indentation).
/// Double-clicking a value cell turns it into an inline editor with a type
/// picker. Values are color-coded: .primary for strings, .blue otherwise.
struct DocumentsView: View {
    @Environment(DatabaseModel.self) private var model

    @State private var showFindSheet = false
    @State private var showUpdateSheet = false
    @State private var showDeleteSheet = false
    @State private var errorMessage: String?
    @State private var editor: ValueEditorState?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.selectedCollection == nil {
                    ContentUnavailableView(
                        "No Collection Selected",
                        systemImage: "shippingbox",
                        description: Text("Select a collection in the sidebar.")
                    )
                } else if model.documents.isEmpty {
                    ContentUnavailableView(
                        "No Documents",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("No documents in this collection — try Find with a filter.")
                    )
                } else {
                    documentList
                }
            }
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showFindSheet = true
                } label: {
                    Label("Find…", systemImage: "magnifyingglass")
                }
                .disabled(model.selectedCollection == nil)

                Button {
                    showUpdateSheet = true
                } label: {
                    Label("Update Many…", systemImage: "wand.and.stars")
                }
                .disabled(model.selectedCollection == nil)

                Button {
                    showDeleteSheet = true
                } label: {
                    Label("Delete Many…", systemImage: "trash")
                }
                .disabled(model.selectedCollection == nil)

                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.selectedCollection == nil)
            }
        }
        .sheet(isPresented: $showFindSheet) {
            FindSheet(errorMessage: $errorMessage)
        }
        .sheet(isPresented: $showUpdateSheet) {
            UpdateSheet(errorMessage: $errorMessage)
        }
        .sheet(isPresented: $showDeleteSheet) {
            DeleteSheet(errorMessage: $errorMessage)
        }
        .alert(
            "Query Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var documentList: some View {
        List {
            ForEach(model.documents.indices, id: \.self) { index in
                Section {
                    ForEach(FieldTree.rows(for: model.documents[index], docIndex: index)) { row in
                        KeyValueRow(
                            row: row,
                            editor: editor,
                            onStartEdit: { startEditing(row) },
                            onCommit: commitEditor,
                            onCancel: { editor = nil }
                        )
                    }
                } header: {
                    Text(documentHeader(for: model.documents[index], index: index))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }

    private func documentHeader(for doc: BSONDocument, index: Int) -> String {
        if let id = doc["_id"], !BSONSupport.displayString(id).isEmpty {
            return "\(BSONSupport.displayString(id)) · #\(index + 1)"
        }
        return "Document \(index + 1)"
    }

    private func startEditing(_ row: FieldRow) {
        commitEditor() // commit any in-flight edit before switching targets
        guard !row.bson.isContainer else { return } // containers expand, not edit
        editor = ValueEditorState(docIndex: row.docIndex, path: row.path, bson: row.bson)
    }

    private func commitEditor() {
        guard let editor,
              let value = editor.committedValue() else { return } // keep open on parse failure
        model.updateDocument(editor.docIndex, at: editor.path, to: value)
        self.editor = nil
    }

    private func refresh() {
        guard let coll = model.selectedCollection else { return }
        Task { await model.select(collection: coll) }
    }
}

/// Find sheet: optional filter query + limit. Empty filter = match everything.
private struct FindSheet: View {
    @Environment(DatabaseModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var errorMessage: String?

    @State private var filter = ""
    @State private var limit = "100"
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Documents").font(.headline)
            Text("Filter (query; empty matches everything)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Accepted: { \"user\": \"some\" } · { user: \"some\" } · user: \"some\"")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter query", text: $filter, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...6)
            HStack {
                Text("Limit").frame(width: 44, alignment: .leading)
                TextField("Limit (empty = no limit)", text: $limit)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private func run() {
        guard !isRunning else { return }
        isRunning = true
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let limitValue = Int(limit.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            defer { isRunning = false }
            do {
                _ = try await model.runFind(
                    filter: trimmed.isEmpty ? nil : trimmed,
                    limit: limitValue
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                dismiss()
            }
        }
    }
}

/// Update Many sheet: filter query + update-operators JSON.
private struct UpdateSheet: View {
    @Environment(DatabaseModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var errorMessage: String?

    @State private var filter = ""
    @State private var update = ""
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update Many").font(.headline)
            Text("Filter (query)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Accepted: { \"user\": \"some\" } · { user: \"some\" } · user: \"some\"")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter query", text: $filter, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...6)
            Text("Update operators (JSON, e.g. {\"$set\": {\"bucket\": \"young\"}})")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Update JSON", text: $update, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private func run() {
        guard !isRunning else { return }
        isRunning = true
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = update.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isRunning = false }
            do {
                _ = try await model.runUpdate(filter: f, update: u)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                dismiss()
            }
        }
    }
}

/// Delete Many sheet: filter query + destructive confirm.
private struct DeleteSheet: View {
    @Environment(DatabaseModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var errorMessage: String?

    @State private var filter = ""
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete Many").font(.headline)
            Text("Deletes every document matching this filter (query).")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter query", text: $filter, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private func run() {
        guard !isRunning else { return }
        isRunning = true
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isRunning = false }
            do {
                _ = try await model.runDelete(filter: f)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                dismiss()
            }
        }
    }
}