import MongoDB
import SwiftUI

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

  @State private var showDeleteSheet = false
  @State private var errorMessage: String?
  @State private var editor: ValueEditorState?
  /// Field keys currently expanded (applies to every entry with that key).
  @State private var expandedKeys: Set<String> = []

  /// Persistent query bar contents.
  @State private var filterText = ""
  @State private var sortText = ""
  @State private var projectText = ""
  @State private var updateText = ""
  @State private var isRunning = false
  @State private var editMode = false
  @State private var debounceTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if model.selectedCollection == nil {
          ContentUnavailableView(
            "No Collection Selected", systemImage: "shippingbox",
            description: Text("Select a collection in the sidebar."))
        } else if model.documents.isEmpty {
          ContentUnavailableView(
            emptyTitle, systemImage: "doc.text.magnifyingglass",
            description: Text(emptySummary))
        } else {
          documentList
        }
      }
    }.frame(maxHeight: .infinity).safeAreaBar(edge: .top) {
      if model.selectedCollection != nil && model.isSessionActive {
        queryBar
      }
    }.toolbar {
      ToolbarItemGroup {
        if model.session != nil && model.selectedCollection == nil {
          if editMode {
            Button {
              showDeleteSheet = true
            } label: {
              Label("Delete…", systemImage: "trash")
            }
          }
          
          Button {
            editMode.toggle()
          } label: {
            Label(editMode ? "Done" : "Edit", systemImage: editMode ? "checkmark.square" : "pencil")
          }

          Button {
            refresh()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        }
      }
    }.navigationSubtitle(model.statusMessage).sheet(
      isPresented: $showDeleteSheet
    ) { DeleteSheet(filter: filterText, errorMessage: $errorMessage) }.onAppear {
      filterText = model.currentQuery.filter ?? ""
      sortText = model.currentQuery.sort ?? ""
      projectText = model.currentQuery.projection ?? ""
    }
  }

  // MARK: - Query bar

  private var queryBar: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Redis has no server-side sort/projection: only a key-glob Filter is
      // offered. MongoDB keeps all three; SQL accepts the same JSON query
      // dialect (auto-detected) or raw SQL fragments — Filter→WHERE,
      // Sort→ORDER BY, JSON Project→column list.
      TextField(filterPlaceholder, text: $filterText, axis: .vertical)
        .onChange(of: filterText) { _, _ in debounceApply() }
      if model.activeEngine != .redis {
        TextField("Sort", text: $sortText, axis: .vertical)
          .onChange(of: sortText) { _, _ in debounceApply() }
        TextField("Project", text: $projectText, axis: .vertical)
          .onChange(of: projectText) { _, _ in debounceApply() }
      }
      if editMode {
        TextField("Update", text: $updateText, axis: .vertical)
      }
      if let errorMessage {
        Text(errorMessage).foregroundStyle(.red)
      }
    }.padding(8).background(.bar)
      .autocorrectionDisabled()
      .textFieldStyle(.roundedBorder).onSubmit { apply() }
  }

  /// The Filter field's placeholder differs per engine: MongoDB and SQL take
  /// JSON query syntax ({age: {$gt:30}}); SQL also accepts raw WHERE bodies,
  /// Redis a key glob.
  private var filterPlaceholder: String {
    switch model.activeEngine {
    case .redis: "Filter (key glob)"
    case .postgresql, .sqlite: "Filter (JSON or WHERE…)"
    case .mongodb, nil: "Filter"
    }
  }

  /// Title/description of the empty state, which differs for Redis (keys vs
  /// documents) and when the query bar is actively filtering.
  private var emptyTitle: String {
    switch model.activeEngine {
    case .redis: "No Keys"
    case .postgresql, .sqlite: "No Rows"
    case .mongodb, nil: "No Documents"
    }
  }

  private var emptySummary: String {
    switch model.activeEngine {
    case .redis: "No keys match. Clear or edit the filter."
    case .postgresql, .sqlite: "No rows match. Clear or edit the filter."
    case .mongodb, nil: "No documents match. Clear or edit the filter."
    }
  }

  // MARK: - Document list

  private var documentList: some View {
    // Snapshot (index, document) pairs once per body evaluation. Re-indexing
    // the live `model.documents` array inside the ForEach builder crashes
    // (index out of range) when the array is replaced with a shorter one
    // mid-diff — debounced query apply, collection switch, or post-mutation
    // refresh all replace the array while the List is still diffing.
    let sections = model.documents.enumerated().map {
      DocumentSection(index: $0.offset, document: $0.element)
    }
    return List {
      ForEach(sections) { section in
        Section {
          ForEach(
            FieldTree.rows(
              for: section.document, docIndex: section.index, expandedKeys: expandedKeys)
          ) { row in
            KeyValueRow(
              row: row, editor: editor, expandedKeys: expandedKeys, onToggle: toggleExpansion,
              onStartEdit: { startEditing(row) }, onCommit: commitEditor, onCancel: { editor = nil }
            )
          }
          if editMode {
            AddFieldRow(onAdd: { key, value in
              model.addField(to: section.index, key: key, value: value)
            }).padding(.leading, 16).padding(.vertical, 2)
          }
        } header: {
          Text(documentHeader(for: section.document, index: section.index)).font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      // "Load more" sentinel: appears at the bottom while more rows exist.
      // Its `.onAppear` fires when the user scrolls to the bottom, loading the
      // next page; a ProgressView shows while a fetch is in flight.
      if model.hasMore && model.activeEngine != .redis {
        HStack(spacing: 8) {
          if model.isLoadingMore {
            ProgressView().controlSize(.small)
            Text("Loading…").font(.caption).foregroundStyle(.secondary)
          } else {
            Text(scrollHint).font(.caption).foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity).padding(.vertical, 8)
          .onAppear { Task { await model.loadMoreDocuments() } }
      }
    }.listStyle(.inset)
  }

  /// Hint shown at the scroll-bottom sentinel before the next page arrives.
  private var scrollHint: String {
    model.activeEngine == .redis ? "" : "Scroll down to load more"
  }

  private func documentHeader(for doc: BSONDocument, index: Int) -> String {
    if let id = doc["_id"], !BSONSupport.displayString(id).isEmpty {
      return "\(BSONSupport.displayString(id)) · #\(index + 1)"
    }
    return "Document \(index + 1)"
  }

  // MARK: - Expansion / editing

  private func toggleExpansion(_ key: String) {
    if expandedKeys.contains(key) { expandedKeys.remove(key) } else { expandedKeys.insert(key) }
  }

  private func startEditing(_ row: FieldRow) {
    commitEditor()  // commit any in-flight edit before switching targets
    guard !row.bson.isContainer else { return }  // containers expand, not edit
    editor = ValueEditorState(docIndex: row.docIndex, path: row.path, bson: row.bson)
  }

  private func commitEditor() {
    guard let editor, let value = editor.committedValue() else { return }  // keep open on parse failure
    model.updateDocument(editor.docIndex, at: editor.path, to: value)
    self.editor = nil
  }
  
  private func updateMany() {
    guard !isRunning else { return }
    isRunning = true
    let f = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    let u = updateText.trimmingCharacters(in: .whitespacesAndNewlines)
    Task {
      defer { isRunning = false }
      do {
        _ = try await model.runUpdate(filter: f, update: u)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Query execution

  private func apply() {
    debounceTask?.cancel()
    model.currentQuery = QuerySpec(
      filter: trimmed(filterText), sort: trimmed(sortText), projection: trimmed(projectText))
    Task {
      do { _ = try await model.applyQuery() } catch { errorMessage = error.localizedDescription }
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

  private func refresh() { apply() }
}

/// One document section in the list: a snapshot of (index, document) captured
/// once per body evaluation. Identified by `id` so rows/headers never re-index
/// the live `model.documents` array (which crashes when it shrinks mid-diff).
private struct DocumentSection: Identifiable {
  let id: Int
  let index: Int
  let document: BSONDocument

  init(index: Int, document: BSONDocument) {
    self.id = index
    self.index = index
    self.document = document
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

  private var trimmedFilter: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Delete Documents").font(.headline)
      Text(
        trimmedFilter.isEmpty ? "Filter: (none — ALL documents match)" : "Filter: \(trimmedFilter)"
      ).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

      Group {
        if let error = previewError {
          Text(error).font(.caption).foregroundStyle(.red)
        } else if let preview {
          if preview.isEmpty {
            Text("No documents match this filter.").font(.caption).foregroundStyle(.secondary)
          } else {
            Text("\(preview.count) document(s) will be deleted:").font(.caption).foregroundStyle(
              .secondary)
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(preview.indices, id: \.self) { i in
                  Text(BSONSupport.json(preview[i])).font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                }
              }.padding(4)
            }.frame(maxHeight: 220).border(.quaternary)
          }
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: 80)
        }
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Delete \(preview?.count ?? 0)", role: .destructive) { confirmDelete = true }
          .disabled(isDeleting || preview == nil || preview!.isEmpty)
      }
    }.padding().frame(width: 540).task { await loadPreview() }.alert(
      "Delete \(preview?.count ?? 0) document(s)?", isPresented: $confirmDelete
    ) {
      Button("Delete", role: .destructive) { Task { await delete() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This cannot be undone.")
    }
  }

  private func loadPreview() async {
    do { preview = try await model.previewDelete(filter: trimmedFilter, limit: 500) } catch {
      previewError = error.localizedDescription
    }
  }

  private func delete() async {
    isDeleting = true
    defer { isDeleting = false }
    do {
      _ = try await model.runDelete(filter: trimmedFilter)
      dismiss()
    } catch { previewError = error.localizedDescription }
  }
}
