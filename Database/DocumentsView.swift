import MongoDB
import Redis
import SwiftUI

/// Merged item-list + preview screen: documents render as $key/$value cell
/// rows. Strings are one line and objects/arrays collapse by default; a click
/// expands a value across every entry with the same key. Double-clicking a
/// value cell turns it into an inline editor with a type picker. Values are
/// color-coded: .primary for strings, .blue otherwise.
///
/// A persistent query bar (search/sort/project) sits above the list; the Edit
/// button toggles add-field rows; Delete previews matches and confirms. The
/// toolbar's segmented picker switches the display format: List (below),
/// Table (spreadsheet grid) or JSON (pretty-printed text).
struct DocumentsView: View {
  @Environment(DatabaseModel.self) private var model

  @AppStorage("documentDisplayFormat") private var storedDisplayFormat = DisplayFormat.list.rawValue

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

  /// Filter-builder chips; their rendered text is the source of truth for the
  /// Filter field while they exist.
  @State private var filterRules: [FilterRule] = []
  /// The chip editor sheet is owned here so column/key menus can open it
  /// prefilled for their field (see `handle`).
  @State private var editingRule: FilterRule?
  @State private var isCreatingRule = false
  /// Column "Search…" fragment box.
  @State private var searchTarget: SearchTarget?
  @State private var searchFragment = ""
  @State private var searchError: String?
  /// "Search all text fields" box.
  @State private var quickSearch = ""
  /// Redis key-filter match mode.
  @State private var redisMatch: KeyGlob.Match = .contains
  /// Fields/kinds/sample values of the loaded rows, rebuilt only when the
  /// documents CHANGE. Deriving it per body evaluation re-walked every loaded
  /// row (chip bar, Fields menu, searchable fields, table headers all read it)
  /// on each keystroke.
  @State private var catalog: [FieldInfo] = []

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
          contentForFormat
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
    }.toolbar {
      ToolbarItemGroup {
        if model.selectedCollection != nil && model.isSessionActive {
          Picker("Display Format", selection: displayFormatBinding) {
            ForEach(DisplayFormat.allCases) { format in
              Image(systemName: format.symbol).accessibilityLabel(format.name).tag(format)
            }
          }
          .pickerStyle(.segmented)
          .help("Display format: List / Table / JSON")
        }
      }
    }
    .navigationSubtitle(model.statusMessage).sheet(
      isPresented: $showDeleteSheet
    ) { DeleteSheet(filter: filterText, errorMessage: $errorMessage) }.sheet(item: $searchTarget) {
      target in
      ColumnSearchSheet(
        field: target.field,
        fragment: $searchFragment,
        errorMessage: $searchError,
        onCancel: { searchTarget = nil },
        onApply: { applySearchFragment(for: target.field) })
    }.onChange(of: model.documents) { _, documents in
      catalog = FieldCatalog.fields(in: documents)
    }.onAppear {
      filterText = model.currentQuery.filter ?? ""
      sortText = model.currentQuery.sort ?? ""
      projectText = model.currentQuery.projection ?? ""
      catalog = FieldCatalog.fields(in: model.documents)
    }
  }

  // MARK: - Display format

  private var displayFormat: DisplayFormat {
    DisplayFormat(rawValue: storedDisplayFormat) ?? .list
  }

  private var displayFormatBinding: Binding<DisplayFormat> {
    Binding(
      get: { displayFormat },
      set: { storedDisplayFormat = $0.rawValue })
  }

  /// The documents pane content for the current display format. List keeps
  /// the expand/collapse + inline-edit rows; Table/JSON are read-only
  /// renderers over the same loaded documents.
  @ViewBuilder
  private var contentForFormat: some View {
    switch displayFormat {
    case .list: documentList
    case .table:
      TableDocumentsView(
        documents: model.documents,
        fields: catalog,
        sortDirections: sortDirections,
        hiddenFields: hiddenFields,
        onColumnAction: handle)
    case .json: JSONDocumentsView(documents: model.documents)
    }
  }

  // MARK: - Query bar

  private var queryBar: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Redis has no server-side sort/projection: only a key-glob Filter is
      // offered. MongoDB keeps all three; SQL accepts the same JSON query
      // dialect (auto-detected) or raw SQL fragments — Filter→WHERE,
      // Sort→ORDER BY, JSON Project→column list.
      if model.activeEngine == .redis {
        RedisKeyFilterView(
          match: $redisMatch,
          text: $filterText,
          onMatchChange: { apply() },
          onTextChange: { debounceApply() })
      } else if let dialect = FilterEngine.dialect(for: model.activeEngine) {
        FilterBuilderView(
          fields: catalog,
          rules: $filterRules,
          editing: $editingRule,
          isCreating: $isCreatingRule,
          dialect: dialect,
          onChange: applyRules)
        if !filterRules.isEmpty
          && !rulesMatchFilterText(dialect: dialect, anyOfFields: searchableFields)
        {
          Label(
            "Filter text was edited by hand — Clear the chips to start over",
            systemImage: "exclamationmark.triangle"
          ).font(.caption).foregroundStyle(.orange)
        }
        if !searchableFields.isEmpty { quickSearchRow }
      }
      TextField(filterPlaceholder, text: $filterText, axis: .vertical)
        .onChange(of: filterText) { _, _ in debounceApply() }
      if model.activeEngine != .redis {
        TextField("Sort", text: $sortText, axis: .vertical)
          .onChange(of: sortText) { _, _ in debounceApply() }
        TextField("Project", text: $projectText, axis: .vertical)
          .onChange(of: projectText) { _, _ in debounceApply() }
        if !allFields.isEmpty { fieldsRow }
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

  /// "Search all text fields" box: writes ONE `$or` chip over every string field
  /// of the loaded rows, so a search is still a chip that can be removed again.
  private var quickSearchRow: some View {
    HStack(spacing: 6) {
      TextField("Search all text fields", text: $quickSearch)
        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
        .onChange(of: quickSearch) { _, _ in debounceQuickSearch() }
        .onSubmit { applyQuickSearch() }
      if !quickSearch.isEmpty {
        Button("Search") { applyQuickSearch() }
        Button("Cancel", systemImage: "xmark.circle") {
          quickSearch = ""
          filterRules.removeAll { $0.field == Self.quickSearchMarker }
          applyRules()
        }.buttonStyle(.plain).labelStyle(.iconOnly)
      }
      Spacer(minLength: 0)
    }
  }

  /// Hide/show menu for every loaded field. Writes the Projection text (through
  /// `handle`), so it can un-hide a column whose header is already gone.
  private var fieldsRow: some View {
    HStack(spacing: 6) {
      Menu {
        ForEach(allFields, id: \.self) { field in
          Button {
            handle(hiddenFields.contains(field) ? .show(field) : .hide(field))
          } label: {
            Label(field, systemImage: hiddenFields.contains(field) ? "eye.slash" : "eye")
          }
        }
        Divider()
        Button("Show All Fields", systemImage: "eye") { handle(.showAllFields) }
      } label: {
        Label("Fields", systemImage: "eye")
      }.fixedSize().help("Hide or show fields (writes the Project filter)")
      if !hiddenFields.isEmpty {
        Text("\(hiddenFields.count) hidden").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
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
              onStartEdit: { startEditing(row) }, onCommit: commitEditor,
              onCancel: { editor = nil },
              keyMenuState: KeyMenuState(
                sortDirection: SortText.direction(of: row.key, in: sortText),
                isHidden: hiddenFields.contains(row.key)),
              onColumnAction: handle
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

  // MARK: - Filter chips

  /// Writes the chips into the Filter field and re-runs the query. The chip text
  /// is the single source of truth for execution while chips exist.
  private func applyRules() {
    guard let dialect = FilterEngine.dialect(for: model.activeEngine) else { return }
    filterText = FilterText.render(filterRules, dialect: dialect, anyOfFields: searchableFields) ?? ""
    apply()
  }

  /// True while the Filter field still holds exactly what the chips render.
  private func rulesMatchFilterText(dialect: FilterDialect, anyOfFields: [String]) -> Bool {
    filterText.trimmingCharacters(in: .whitespacesAndNewlines)
      == (FilterText.render(filterRules, dialect: dialect, anyOfFields: anyOfFields) ?? "")
  }

  /// String fields offered to "search all text fields". `_id` is excluded: its
  /// values are opaque identifiers, so a substring/regex search over them only
  /// adds a useless branch to every `$or`. Cap mirrors `FieldCatalog.textFields`.
  private var searchableFields: [String] {
    Array(
      catalog.filter { $0.kind == .string && $0.name != "_id" }.map(\.name).prefix(6))
  }

  /// Marker field of the "search all text fields" chip (see `FilterText.render`).
  private static let quickSearchMarker = "$or"

  /// Writes/replaces the "search all text fields" chip and applies it.
  private func applyQuickSearch() {
    let text = quickSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    filterRules.removeAll { $0.field == Self.quickSearchMarker }
    guard !text.isEmpty else {
      applyRules()
      return
    }
    filterRules.append(
      FilterRule(
        field: Self.quickSearchMarker, op: .contains, value: .array([.string(text)])))
    applyRules()
  }

  // MARK: - Column UI: everything derived from the query bar text

  /// Sort keys parsed from the Sort text: the ONLY source for header arrows and
  /// for what the next click does. Hand-typed sort text drives the UI too.
  private var sortKeys: [SortKey] { SortText.parse(sortText) }

  /// Arrow per column, derived from `sortKeys`.
  private var sortDirections: [String: SortText.Direction] {
    var result: [String: SortText.Direction] = [:]
    for key in sortKeys { result[key.field] = key.ascending ? .ascending : .descending }
    return result
  }

  /// The field universe of the loaded rows (drives hide/show and projections).
  private var allFields: [String] { catalog.map(\.name) }

  /// Hidden columns, derived from the Projection text — never stored.
  private var hiddenFields: Set<String> {
    guard let dialect = FilterEngine.dialect(for: model.activeEngine) else { return [] }
    return Set(ProjectionText.hidden(in: projectText, allFields: allFields, dialect: dialect))
  }

  /// One funnel for every column/key gesture (table headers, List key menus and
  /// the query bar's Fields menu). Every case rewrites query TEXT and re-runs the
  /// query; no sort/hidden/filter state is ever stored in a view.
  private func handle(_ action: ColumnAction) {
    guard let dialect = FilterEngine.dialect(for: model.activeEngine) else { return }
    switch action {
    case .cycleSort(let field):
      writeSort(SortText.cycle(field, in: sortKeys).keys, dialect: dialect)
    case .setSort(let field, let direction):
      writeSort(SortText.set(field, direction: direction, in: sortKeys), dialect: dialect)
    case .disableSort(let field):
      writeSort(SortText.remove(field, from: sortKeys), dialect: dialect)
    case .hide(let field):
      projectText = ProjectionText.hide(
        field, in: projectText, allFields: allFields, dialect: dialect) ?? ""
      apply()
    case .show(let field):
      projectText = ProjectionText.show(
        field, in: projectText, allFields: allFields, dialect: dialect) ?? ""
      apply()
    case .showAllFields:
      projectText = ProjectionText.showAll ?? ""
      apply()
    case .filter(let field, let rule):
      // A menu item that still needs a value ("Filter: contains…") opens the chip
      // editor prefilled instead of adding an empty chip.
      if rule.op.needsValue, !rule.op.takesList, FilterText.display(rule.value).isEmpty {
        isCreatingRule = true
        editingRule = rule
      } else {
        filterRules.append(rule)
        applyRules()
      }
    case .search(let field):
      searchFragment = ""
      searchError = nil
      searchTarget = SearchTarget(field: field)
    }
  }

  /// Writes sort keys as dialect text (Mongo `{ a: 1 }`, SQL `a ASC`) and re-runs.
  private func writeSort(_ keys: [SortKey], dialect: FilterDialect) {
    sortText = SortText.render(keys, dialect: dialect) ?? ""
    apply()
  }

  // MARK: - Column search fragments

  /// Validates a typed fragment with the SAME parser the query bar uses, then
  /// stores it verbatim as a `.custom` chip: `15` -> `{ age: 15 }`,
  /// `{ $gt: 15 }` -> `{ age: { $gt: 15 } }`. On error the box stays open with the
  /// parser's message (it carries a column number) and nothing is applied.
  private func applySearchFragment(for field: String) {
    let fragment = searchFragment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fragment.isEmpty else {
      searchError = "Type a value or an operator object, e.g. 15 or { $gt: 15 }"
      return
    }
    do {
      try FilterText.validate(fragment: fragment, for: field)
    } catch {
      searchError = error.localizedDescription
      return
    }
    filterRules.removeAll { $0.field == field && $0.op == .custom }
    filterRules.append(FilterRule(field: field, op: .custom, value: .string(fragment)))
    searchTarget = nil
    applyRules()
  }

  private func debounceApply() {
    debounceTask?.cancel()
    debounceTask = Task {
      try? await Task.sleep(for: Self.applyDelay)
      guard !Task.isCancelled else { return }
      apply()
    }
  }

  /// How long typing must pause before the query re-runs. A query per keystroke
  /// meant a round trip plus a full document/table re-render per character,
  /// which made typing in the query bar feel blocked.
  private static let applyDelay: Duration = .seconds(1)

  /// Debounced "search all text fields": typing re-runs the search one second
  /// after the last keystroke; the Search button applies immediately.
  private func debounceQuickSearch() {
    guard !quickSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    debounceTask?.cancel()
    debounceTask = Task {
      try? await Task.sleep(for: Self.applyDelay)
      guard !Task.isCancelled else { return }
      applyQuickSearch()
    }
  }

  private func trimmed(_ string: String) -> String? {
    let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }

  private func refresh() { apply() }
}

/// Identifiable wrapper so the "Search…" fragment box can be a sheet item.
private struct SearchTarget: Identifiable {
  let field: String
  var id: String { field }
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
