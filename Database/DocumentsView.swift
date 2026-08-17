import SwiftUI
import MongoDB

/// Merged item-list + preview screen: documents render as $key/$value cell
/// rows. Strings are one line and objects/arrays collapse by default; a click
/// expands a value across every entry with the same key. Double-clicking a
/// value cell turns it into an inline editor with a type picker. Values are
/// color-coded: .primary for strings, .blue otherwise.
///
/// A persistent query bar (search/sort/project) sits above the list; the Edit
/// button toggles add-field rows; Delete previews matches and confirms.
struct DocumentsView: View {
    @Environment(DatabaseModel.self) private var model

    @State private var showUpdateSheet = false
    @State private var showDeleteSheet = false
    @State private var errorMessage: String?
    @State private var editor: ValueEditorState?
    /// Field keys currently expanded (applies to every entry with that key).
    @State private var expandedKeys: Set<String> = []

    /// Persistent query bar contents.
    @State private var filterText = ""
    @State private var sortText = ""
    @State private var projectText = ""
    @State private var editMode = false
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            queryBar
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
                        description: Text("No documents match. Clear or edit the filter.")
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
                    editMode.toggle()
                } label: {
                    Label(editMode ? "Done" : "Edit", systemImage: editMode ? "checkmark.square" : "square.and.pencil")
                }
                .disabled(model.selectedCollection == nil)

                Button {
                    showDeleteSheet = true
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .disabled(model.selectedCollection == nil)

                Button {
                    showUpdateSheet = true
                } label: {
                    Label("Update Many…", systemImage: "wand.and.stars")
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
        .sheet(isPresented: $showUpdateSheet) {
            UpdateSheet(errorMessage: $errorMessage)
        }
        .sheet(isPresented: $showDeleteSheet) {
            DeleteSheet(filter: filterText, errorMessage: $errorMessage)
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
        .onAppear {
            filterText = model.currentQuery.filter ?? ""
            sortText = model.currentQuery.sort ?? ""
            projectText = model.currentQuery.projection ?? ""
        }
    }

    // MARK: - Query bar

    private var queryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filterText, prompt: Text("Filter — e.g. { user: \"ann\" }"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { apply() }
                .onChange(of: filterText) { _, _ in debounceApply() }
            Divider()
                .frame(height: 20)
            TextField("Sort", text: $sortText, prompt: Text("Sort — age: -1"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit { apply() }
                .onChange(of: sortText) { _, _ in debounceApply() }
            TextField("Project", text: $projectText, prompt: Text("Project — name: 1"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit { apply() }
                .onChange(of: projectText) { _, _ in debounceApply() }
        }
        .padding(8)
        .background(.bar)
    }

    // MARK: - Document list

    private var documentList: some View {
        List {
            ForEach(model.documents.indices, id: \.self) { index in
                Section {
                    ForEach(FieldTree.rows(for: model.documents[index], docIndex: index, expandedKeys: expandedKeys)) { row in
                        KeyValueRow(
                            row: row,
                            editor: editor,
                            expandedKeys: expandedKeys,
                            onToggle: toggleExpansion,
                            onStartEdit: { startEditing(row) },
                            onCommit: commitEditor,
                            onCancel: { editor = nil }
                        )
                    }
                    if editMode {
                        AddFieldRow(onAdd: { key, value in
                            model.addField(to: index, key: key, value: value)
                        })
                        .padding(.leading, 16)
                        .padding(.vertical, 2)
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

    // MARK: - Expansion / editing

    private func toggleExpansion(_ key: String) {
        if expandedKeys.contains(key) {
            expandedKeys.remove(key)
        } else {
            expandedKeys.insert(key)
        }
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

    // MARK: - Query execution

    private func apply() {
        debounceTask?.cancel()
        model.currentQuery = QuerySpec(
            filter: trimmed(filterText),
            sort: trimmed(sortText),
            projection: trimmed(projectText)
        )
        Task {
            do {
                _ = try await model.applyQuery()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func debounceApply() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            apply()
        }
    }

    private func trimmed(_ string: String) -> String? {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func refresh() {
        apply()
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
            TextField("Filter query", text: $filter, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
            Text("Update operators (JSON, e.g. {\"$set\": {\"bucket\": \"young\"}})")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Update JSON", text: $update, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
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
        .frame(width: 480)
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

/// Delete sheet: previews the entries the current filter would delete, then
/// requires explicit confirmation before deleting.
private struct DeleteSheet: View {
    @Environment(DatabaseModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let filter: String
    @Binding var errorMessage: String?

    @State private var preview: [BSONDocument]?
    @State private var previewError: String?
    @State private var isDeleting = false
    @State private var confirmDelete = false

    private var trimmedFilter: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete Documents").font(.headline)
            Text(trimmedFilter.isEmpty
                 ? "Filter: (none — ALL documents match)"
                 : "Filter: \(trimmedFilter)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Group {
                if let error = previewError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let preview {
                    if preview.isEmpty {
                        Text("No documents match this filter.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(preview.count) document(s) will be deleted:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(preview.indices, id: \.self) { i in
                                    Text(BSONSupport.json(preview[i]))
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(4)
                        }
                        .frame(maxHeight: 220)
                        .border(.quaternary)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: 80)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete \(preview?.count ?? 0)", role: .destructive) { confirmDelete = true }
                    .disabled(isDeleting || preview == nil || preview!.isEmpty)
            }
        }
        .padding()
        .frame(width: 540)
        .task { await loadPreview() }
        .alert(
            "Delete \(preview?.count ?? 0) document(s)?",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func loadPreview() async {
        do {
            preview = try await model.previewDelete(filter: trimmedFilter, limit: 500)
        } catch {
            previewError = error.localizedDescription
        }
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await model.runDelete(filter: trimmedFilter)
            dismiss()
        } catch {
            previewError = error.localizedDescription
        }
    }
}