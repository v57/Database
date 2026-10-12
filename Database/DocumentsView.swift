import Database
import MongoDB
import Redis
import SwiftUI

/// Merged item-list + preview screen. The toolbar's segmented picker switches
/// the display format: Table (spreadsheet grid, the default), List ($key/$value
/// rows that expand and edit inline) or JSON (pretty-printed text).
///
/// Above the results sits a query bar. By default it is the simple one —
/// search, filter chips, sort and field menus — that needs no query syntax;
/// the Query Editor toggle adds the Filter/Sort/Project text fields, the
/// aggregation builder and the filter-wide Edit mode. Selecting a record
/// shows it in the inspector, from where it can be edited or deleted with a
/// review step and Undo.
struct DocumentsView: View {
  @Environment(DatabaseModel.self) private var model
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @AppStorage("documentDisplayFormat") private var storedDisplayFormat = DisplayFormat.table.rawValue
  /// Power tools: the query text fields, aggregation and Edit mode.
  @AppStorage("showsQueryEditor") private var showsQueryEditor = false

  @State private var showDeleteSheet = false
  /// Failure of a user action that isn't a query (saving an edit, Update):
  /// shown in the query bar. Query failures live in `model.queryError`.
  @State private var actionError: FriendlyError?
  @State private var editor: ValueEditorState?
  /// Field keys currently expanded (applies to every entry with that key).
  @State private var expandedKeys: Set<String> = []

  /// The record shown in the inspector (an index into `model.documents`).
  @State private var selectedRecord: Int?
  @State private var showsInspector = false
  @State private var recordEditor: RecordEditorTarget?
  /// A single record awaiting delete confirmation.
  @State private var recordPendingDeletion: Int?
  /// The same two, started from the inspector: on iPhone the inspector is
  /// itself a sheet, so its editor and confirmation must be presented from
  /// inside it.
  @State private var inspectorEditor: RecordEditorTarget?
  @State private var inspectorDeletion: Int?

  /// Persistent query bar contents.
  @State private var filterText = ""
  @State private var sortText = ""
  @State private var projectText = ""
  @State private var updateText = ""
  @State private var isRunning = false
  /// Queries in flight (several can overlap while typing); drives the spinner.
  @State private var runningQueries = 0
  @State private var editMode = false
  @State private var debounceTask: Task<Void, Never>?
  @State private var quickSearchTask: Task<Void, Never>?
  /// An Update awaiting confirmation, with the number of documents it hits.
  @State private var pendingUpdate: PendingUpdate?

  /// Filter-builder chips; their rendered text is the source of truth for the
  /// Filter field while they exist.
  @State private var filterRules: [FilterRule] = []
  /// The chip editor sheet is owned here so column/key menus can open it
  /// prefilled for their field (see `handle`).
  @State private var editingRule: FilterRule?
  @State private var isCreatingRule = false
  /// What the chips last wrote into the Filter field, and the chips that wrote
  /// it. Filter text that differs was typed by hand; a chip change then asks
  /// before replacing it, and Cancel restores `renderedRules`.
  @State private var lastRenderedFilter = ""
  @State private var renderedRules: [FilterRule] = []
  @State private var confirmsFilterOverwrite = false
  /// Fields the "search all text fields" chip searches, fixed when the search
  /// is made: re-deriving them from each result page changed the search (and
  /// its rendered text) every time the results changed.
  @State private var quickSearchFields: [String] = []
  /// Compact width: Sort/Project/Fields fold away behind a toggle so the query
  /// bar doesn't take a third of an iPhone screen.
  @State private var showsQueryOptions = false
  /// Column "Search…" fragment box.
  @State private var searchTarget: SearchTarget?
  @State private var searchFragment = ""
  @State private var searchError: String?
  /// "Search all text fields" box.
  @State private var quickSearch = ""
  /// Redis key filter: the typed text and its match mode. The Filter text is
  /// DERIVED from these (`KeyGlob.query`), so the mode really filters.
  @State private var redisKeyText = ""
  @State private var redisMatch: KeyGlob.Match = .contains
  /// Find (Filter/Sort/Project bar) or Aggregate (pipeline builder). Changed
  /// only through `switchMode`, which re-runs the matching query.
  @State private var queryMode = QueryMode.find
  /// The aggregation builder's stages, and the stages that produced the shown
  /// results (for the Run button's "edited" state).
  @State private var pipelineStages: [PipelineStage] = []
  @State private var appliedStages: [PipelineStage] = []
  /// Fields/kinds/sample values of the loaded rows, rebuilt only when the
  /// documents CHANGE. Deriving it per body evaluation re-walked every loaded
  /// row (chip bar, Fields menu, searchable fields, table headers all read it)
  /// on each keystroke.
  @State private var catalog: [FieldInfo] = []

  // Split into separately type-checked pieces: as one modifier chain the body
  // exceeded the type checker's time limit.
  var body: some View { syncingQueryBar(dialogs(inspecting(chrome))) }

  /// The pane with its query bar, toolbar and titles.
  private var chrome: some View {
    paneContent.frame(maxHeight: .infinity).topBar {
      if model.selectedCollection != nil && model.isSessionActive {
        queryBar
      }
    }
    .safeAreaInset(edge: .bottom) {
      if let change = model.lastChange { UndoBar(change: change, onUndo: undo) }
    }
    .toolbar { toolbarItems }
    .subtitle(subtitle)
#if os(iOS)
    // A large title sat in an empty band above the query bar.
    .navigationBarTitleDisplayMode(.inline)
#endif
  }

  /// Whatever the pane shows under the query bar: a placeholder when there is
  /// nothing to show yet, else the documents in the chosen format.
  @ViewBuilder private var paneContent: some View {
    if !model.isSessionActive {
      if model.isConnecting {
        ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        WelcomeView()
      }
    } else if model.selectedCollection == nil {
      let noun = model.containerNoun.singular
      ContentUnavailableView(
        "No \(noun.capitalized) Selected", systemImage: "shippingbox",
        description: Text("Choose a \(noun) in the sidebar to see what’s in it."))
    } else if model.documents.isEmpty && model.isLoadingDocuments {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.documents.isEmpty, let error = model.queryError {
      let friendly = FriendlyError(error, while: .loading)
      ContentUnavailableView {
        Label(friendly.title, systemImage: "exclamationmark.triangle")
      } description: {
        VStack(spacing: 6) {
          if friendly.message != friendly.title { Text(friendly.message) }
          if let suggestion = friendly.suggestion { Text(suggestion) }
          if !friendly.detailsRepeatMessage {
            Text(friendly.details).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      } actions: {
        if isQueryActive { Button(isAggregating ? "Clear Pipeline" : "Clear Search & Filters") { clearQuery() } }
        Button("Try Again") { refresh() }
      }
    } else if model.documents.isEmpty {
      ContentUnavailableView {
        Label(emptyTitle, systemImage: "doc.text.magnifyingglass")
      } description: {
        Text(emptySummary)
      } actions: {
        if isQueryActive { Button(isAggregating ? "Clear Pipeline" : "Clear Search & Filters") { clearQuery() } }
        if model.canEditDocuments && !isAggregating {
          Button("Add \(model.itemNoun.singular.capitalized)…") { recordEditor = RecordEditorTarget(mode: .add) }
        }
      }
    } else {
      // Results of a query that has since failed stay visible but dimmed;
      // the query bar says they are stale.
      contentForFormat.opacity(model.queryError == nil ? 1 : 0.5)
    }
  }

  @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
    ToolbarItemGroup {
      if model.selectedCollection != nil && model.isSessionActive {
        if model.canEditDocuments && !isAggregating {
          Button {
            recordEditor = RecordEditorTarget(mode: .add)
          } label: {
            Label("Add \(model.itemNoun.singular.capitalized)", systemImage: "plus")
          }.help("Add a \(model.itemNoun.singular)")
        }
        // Edit mode (inline values, Add Field, filter-wide Update/Delete) is
        // a power tool: it comes with the query editor.
        if showsQueryEditor && model.canEditDocuments && !isAggregating {
          if editMode && model.canBulkEdit {
            Button {
              showDeleteSheet = true
            } label: {
              Label("Delete Matching…", systemImage: "trash")
            }.keyboardShortcut(.delete, modifiers: .command)
              .help("Delete every \(model.itemNoun.singular) the filter matches (⌘⌫)")
          }
          Button {
            editMode.toggle()
            if !editMode { editor = nil }
          } label: {
            Label(editMode ? "Done" : "Edit", systemImage: editMode ? "checkmark" : "pencil")
          }.help(editMode ? "Leave edit mode" : "Edit values in place, add fields, update or delete in bulk")
        }

        Button {
          refresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }.keyboardShortcut("r", modifiers: .command).help("Load the latest data (⌘R)")

        if isCompact {
          // Edit + Refresh + a three-segment picker overflowed the iPhone
          // toolbar; one menu button shows the current format instead.
          Menu {
            if model.canAggregate && (showsQueryEditor || isAggregating) {
              Picker("Query Mode", selection: queryModeBinding) {
                ForEach(QueryMode.allCases) { mode in
                  Label(mode.name, systemImage: mode.symbol).tag(mode)
                }
              }
            }
            Picker("Display Format", selection: displayFormatBinding) {
              ForEach(DisplayFormat.allCases) { format in
                Label(format.name, systemImage: format.symbol).tag(format)
              }
            }
            if model.activeEngine != .redis {
              Toggle(isOn: queryEditorBinding) {
                Label("Query Editor", systemImage: "curlybraces")
              }
            }
          } label: {
            Label("Display Format: \(displayFormat.name)", systemImage: displayFormat.symbol)
          }
        } else {
          if model.canAggregate && (showsQueryEditor || isAggregating) {
            Picker("Query Mode", selection: queryModeBinding) {
              ForEach(QueryMode.allCases) { mode in
                Label(mode.name, systemImage: mode.symbol).tag(mode)
              }
            }
            .pickerStyle(.segmented)
            .help("Find with Filter/Sort/Project, or build an aggregation pipeline")
          }
          Picker("Display Format", selection: displayFormatBinding) {
            ForEach(DisplayFormat.allCases) { format in
              Image(systemName: format.symbol).accessibilityLabel(format.name).tag(format)
            }
          }
          .pickerStyle(.segmented)
          .help("Show as a table, a list of fields, or JSON")
          if model.activeEngine != .redis {
            Toggle(isOn: queryEditorBinding) {
              Label("Query Editor", systemImage: "curlybraces")
            }
            .help(showsQueryEditor
              ? "Hide the query editor" : "Show the query editor, aggregation and bulk editing")
          }
          Button {
            showsInspector.toggle()
          } label: {
            Label("Details", systemImage: "sidebar.trailing")
          }.help(showsInspector ? "Hide record details" : "Show the selected record’s details")
        }
      }
    }
  }

  /// Turning the query editor off also leaves Aggregate mode and Edit mode,
  /// whose controls go away with it.
  private var queryEditorBinding: Binding<Bool> {
    Binding(
      get: { showsQueryEditor },
      set: { shows in
        showsQueryEditor = shows
        if !shows {
          editMode = false
          editor = nil
          if isAggregating { switchMode(to: .find) }
        }
      })
  }

  // MARK: - Record inspector and actions

  /// The selected record's details: an inspector column on wide layouts, a
  /// sheet on iPhone (the inspector modifier adapts by itself).
  private func inspecting(_ content: some View) -> some View {
    content.inspector(isPresented: $showsInspector) {
      RecordDetailView(
        index: selectedRecord ?? -1,
        onSelect: { selectedRecord = $0 },
        onEdit: { if let i = selectedRecord { inspectorEditor = RecordEditorTarget(mode: .edit(i)) } },
        onDelete: { if let i = selectedRecord { inspectorDeletion = i } },
        onUndo: undo
      )
      .modifier(
        RecordDialogs(
          editor: $inspectorEditor, deletion: $inspectorDeletion, fields: catalog,
          onDelete: deleteRecord))
      .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
    }
    .onChange(of: collectionKey) { _, _ in selectedRecord = nil }
    .onChange(of: model.documents.count) { _, count in
      if let index = selectedRecord, index >= count { selectedRecord = count > 0 ? count - 1 : nil }
    }
  }

  /// What every record row offers (table context menu, list header menu).
  private var recordActions: RecordActions {
    RecordActions(
      canEdit: model.canEditDocuments && !isAggregating,
      showDetails: { index in
        selectedRecord = index
        showsInspector = true
      },
      edit: { editRecord($0) },
      delete: { recordPendingDeletion = $0 })
  }

  private func editRecord(_ index: Int) {
    if let blocker = model.editBlocker(forRecordAt: index) {
      actionError = FriendlyError(title: "This \(model.itemNoun.singular) can’t be edited", message: blocker, details: blocker)
      return
    }
    recordEditor = RecordEditorTarget(mode: .edit(index))
  }

  private func deleteRecord(_ index: Int) {
    Task {
      do {
        try await model.deleteRecord(at: index)
        actionError = nil
      } catch {
        actionError = FriendlyError(error, while: .saving)
      }
    }
  }

  private func undo() {
    Task {
      do {
        try await model.undoLastChange()
      } catch {
        actionError = FriendlyError(error, while: .saving)
      }
    }
  }

  /// The pane's sheets and alerts.
  private func dialogs(_ content: some View) -> some View {
    content
    .modifier(
      RecordDialogs(
        editor: $recordEditor, deletion: $recordPendingDeletion, fields: catalog,
        onDelete: deleteRecord))
    .sheet(
      isPresented: $showDeleteSheet
    ) { DeleteSheet(filter: filterText) }.sheet(item: $searchTarget) {
      target in
      ColumnSearchSheet(
        field: target.field,
        dialect: FilterEngine.dialect(for: model.activeEngine) ?? .mongo,
        fragment: $searchFragment,
        errorMessage: $searchError,
        onCancel: { searchTarget = nil },
        onApply: { applySearchFragment(for: target.field) })
    }.alert(
      pendingUpdate.map { "Update \($0.count) \($0.count == 1 ? "document" : "documents")?" } ?? "",
      isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } }),
      presenting: pendingUpdate
    ) { update in
      Button("Update", role: .destructive) { runUpdate(update) }
      Button("Cancel", role: .cancel) {}
    } message: { update in
      Text(
        update.filter.isEmpty
          ? "No filter is set: this updates EVERY document in the collection."
          : "Applies the update to every document matching \(update.filter).")
    }.alert(
      "Replace the typed filter?", isPresented: $confirmsFilterOverwrite
    ) {
      Button("Replace") { applyRules(confirmed: true) }
      Button("Cancel", role: .cancel) { filterRules = renderedRules }
    } message: {
      Text(
        "Filter chips rewrite the Filter field, so “\(trimmed(filterText) ?? "")” would be replaced.")
    }
  }

  /// Keeps the query bar's text, the chips and the model's query in step.
  private func syncingQueryBar(_ content: some View) -> some View {
    content
    .onChange(of: model.documents) { _, documents in
      // Keep the last non-empty field list: a query with no results would
      // otherwise empty it, hiding the search box, Fields menu and chip
      // fields right when the query needs changing. A new collection resets it.
      if !documents.isEmpty { catalog = FieldCatalog.fields(in: documents) }
    }.onChange(of: collectionKey) { _, _ in
      resetQueryBar()
    }.onChange(of: filterText) { _, text in
      if let plain = text.withStraightQuotes { filterText = plain } else { debounceApply() }
    }
    .onChange(of: sortText) { _, text in
      if let plain = text.withStraightQuotes { sortText = plain } else { debounceApply() }
    }
    .onChange(of: projectText) { _, text in
      if let plain = text.withStraightQuotes { projectText = plain } else { debounceApply() }
    }
    .onChange(of: updateText) { _, text in
      if let plain = text.withStraightQuotes { updateText = plain }
    }
    .onChange(of: filterRules) { _, rules in
      // Removing the "search all text fields" chip (its ×, Clear) also clears
      // the box, so the two never disagree.
      if !rules.contains(where: { $0.field == Self.quickSearchMarker }) && !quickSearch.isEmpty {
        quickSearchTask?.cancel()
        quickSearch = ""
      }
    }.onAppear {
      filterText = model.currentQuery.filter ?? ""
      sortText = model.currentQuery.sort ?? ""
      projectText = model.currentQuery.projection ?? ""
      // A pane re-created while a pipeline drives the list (compact
      // navigation) shows that pipeline again rather than a stale Find bar.
      if let pipeline = model.currentPipeline {
        queryMode = .aggregate
        pipelineStages = pipeline.compactMap { stage in
          stage.keys.first.flatMap { name in stage[name].map { PipelineStage(name: name, value: $0) } }
        }
        appliedStages = pipelineStages
      }
      catalog = FieldCatalog.fields(in: model.documents)
    }
  }

  /// Identity of the selected collection; the query bar resets when it changes.
  private var collectionKey: String {
    "\(model.selectedDatabase ?? "")\u{1F}\(model.selectedCollection ?? "")"
  }

  /// A new collection starts with an empty query bar (the model resets
  /// `currentQuery` on the same change, so no extra query is triggered).
  private func resetQueryBar() {
    debounceTask?.cancel()
    quickSearchTask?.cancel()
    filterText = ""
    sortText = ""
    projectText = ""
    updateText = ""
    filterRules = []
    renderedRules = []
    lastRenderedFilter = ""
    quickSearch = ""
    quickSearchFields = []
    redisKeyText = ""
    pipelineStages = []
    appliedStages = []
    editor = nil
    expandedKeys = []
    actionError = nil
    // Rebuilt from what is loaded now (possibly nothing yet) rather than
    // cleared: this handler and the documents one can run in either order.
    catalog = FieldCatalog.fields(in: model.documents)
  }

  /// Clears filter/sort/projection (and their chips) and re-runs the query;
  /// in Aggregate mode, empties the pipeline instead.
  private func clearQuery() {
    if isAggregating {
      pipelineStages = []
      runPipeline()
      return
    }
    quickSearchTask?.cancel()
    filterRules = []
    renderedRules = []
    lastRenderedFilter = ""
    quickSearch = ""
    redisKeyText = ""
    filterText = ""
    sortText = ""
    projectText = ""
    apply()
  }

  // MARK: - Display format

  private var displayFormat: DisplayFormat {
    DisplayFormat(rawValue: storedDisplayFormat) ?? .table
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
        sortDirections: isAggregating ? [:] : sortDirections,
        hiddenFields: isAggregating ? [] : hiddenFields,
        onColumnAction: columnActionHandler,
        selection: $selectedRecord,
        recordActions: recordActions)
    case .json: JSONDocumentsView(documents: model.documents, header: documentHeader)
    }
  }

  // MARK: - Query bar

  private var queryBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Redis has no server-side sort/projection: only the key filter is
      // offered (text or glob → SCAN MATCH). MongoDB and SQL share the JSON
      // query dialect; SQL also accepts raw fragments — Filter→WHERE,
      // Sort→ORDER BY, JSON Project→column list.
      if isAggregating {
        AggregationBuilderView(
          stages: $pipelineStages,
          fields: catalog,
          isRunning: runningQueries > 0,
          hasUnappliedChanges: pipelineStages != appliedStages,
          onRun: { runPipeline(throughStage: $0) })
      } else if model.activeEngine == .redis {
        RedisKeyFilterView(
          match: $redisMatch,
          text: $redisKeyText,
          onMatchChange: {
            filterText = KeyGlob.query(redisKeyText, match: redisMatch) ?? ""
            apply()
          },
          onTextChange: {
            // The derived Filter text change is debounced by its onChange.
            filterText = KeyGlob.query(redisKeyText, match: redisMatch) ?? ""
          })
      } else if let dialect = FilterEngine.dialect(for: model.activeEngine) {
        simpleControls(dialect)
        if showsQueryEditor {
          queryEditor
        } else if let typed = handTypedFilter {
          customQueryNotice(typed)
        }
      }
      if editMode && model.canEditDocuments && showsQueryEditor {
        if displayFormat != .list {
          // Table/JSON are read-only renderers; say where editing happens.
          HStack(alignment: .firstTextBaseline) {
            Label("Values are edited in List view.", systemImage: "info.circle")
              .font(.caption).foregroundStyle(.secondary)
            Button("Switch to List") { storedDisplayFormat = DisplayFormat.list.rawValue }
              .font(.caption).buttonStyle(.borderless)
          }
        }
        if model.canBulkEdit { updateRow }
      }
      if let error = model.queryError, !model.documents.isEmpty {
        let friendly = FriendlyError(error, while: .loading)
        VStack(alignment: .leading, spacing: 2) {
          Label("\(friendly.title). Showing the previous results.", systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.red)
          Text(friendly.suggestion.map { "\(friendly.details) — \($0)" } ?? friendly.details)
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      if let actionError {
        HStack(alignment: .top) {
          FriendlyErrorView(error: actionError).font(.callout)
          Spacer(minLength: 0)
          Button("Dismiss", systemImage: "xmark.circle") { self.actionError = nil }
            .buttonStyle(.plain).labelStyle(.iconOnly).foregroundStyle(.secondary)
        }
      }
    }.padding(8).background(.bar)
      .plainTextEntry()
      .textFieldStyle(.roundedBorder)
  }

  /// The controls that need no query syntax: search, sort and field menus,
  /// and the filter chips.
  private func simpleControls(_ dialect: FilterDialect) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        searchField
        sortMenu
        fieldsMenu
        Spacer(minLength: 0)
        if showsQueryEditor && !isCompact { runControl }
      }
      FilterBuilderView(
        fields: catalog,
        rules: $filterRules,
        editing: $editingRule,
        isCreating: $isCreatingRule,
        dialect: dialect,
        onChange: { applyRules() }
      ).padding(.horizontal, -8)
    }
  }

  /// The Filter/Sort/Project text fields (Query Editor on).
  @ViewBuilder private var queryEditor: some View {
    if chipsOutOfSync {
      HStack(alignment: .firstTextBaseline) {
        Label(
          "The Filter was edited by hand, so the chips no longer apply.",
          systemImage: "exclamationmark.triangle"
        ).font(.caption).foregroundStyle(.orange)
        Button("Clear Chips") {
          filterRules = []
          applyRules()
        }.font(.caption).buttonStyle(.borderless)
      }
    }
    queryField("Filter", text: $filterText, prompt: filterPrompt) {
      if isCompact { runControl }
    }
    if isCompact {
      if showsQueryOptions || !sortText.isEmpty || !projectText.isEmpty {
        queryField("Sort", text: $sortText, prompt: sortPrompt)
        queryField("Project", text: $projectText, prompt: projectPrompt)
      } else {
        HStack(spacing: 6) {
          Spacer().frame(width: Self.queryLabelWidth)
          Button("Sort & Project…", systemImage: "slider.horizontal.3") {
            showsQueryOptions = true
          }.font(.caption).buttonStyle(.borderless)
        }
      }
    } else {
      HStack(alignment: .center, spacing: 12) {
        queryField("Sort", text: $sortText, prompt: sortPrompt)
        queryField("Project", text: $projectText, prompt: projectPrompt)
      }
    }
  }

  /// Filter text typed in the query editor, which the chips don't show.
  private var handTypedFilter: String? {
    guard let text = trimmed(filterText), text != lastRenderedFilter else { return nil }
    return text
  }

  /// With the editor hidden, a typed filter would silently narrow the
  /// results; say it's there and offer to show or clear it.
  private func customQueryNotice(_ filter: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label("A typed filter is applied: \(filter)", systemImage: "curlybraces")
        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      Button("Show") { showsQueryEditor = true }.font(.caption).buttonStyle(.borderless)
      Button("Clear") {
        filterText = ""
        apply()
      }.font(.caption).buttonStyle(.borderless)
    }
  }

  /// One labelled query field. The visible caption keeps Filter/Sort/Project
  /// telling apart once they contain text (a placeholder alone disappears).
  private func queryField(
    _ label: String, text: Binding<String>, prompt: String,
    @ViewBuilder trailing: () -> some View = { EmptyView() }
  ) -> some View {
    // Centered, not baseline-aligned: an empty iOS field (placeholder only)
    // reports no text baseline, which pushed the caption above the field.
    HStack(alignment: .center, spacing: 6) {
      Text(label).font(.caption).foregroundStyle(.secondary)
        .frame(width: Self.queryLabelWidth, alignment: .trailing)
      TextField(label, text: text, prompt: Text(prompt), axis: .vertical)
        .lineLimit(1...4)
        .onSubmit { apply() }
      trailing()
    }
  }

  private static let queryLabelWidth: CGFloat = 44

  private var isCompact: Bool { horizontalSizeClass == .compact }

  /// Spinner while a query runs; otherwise a Run button, highlighted while the
  /// bar holds changes that haven't run (typing only auto-runs text that
  /// parses — e.g. raw SQL waits for Return or Run).
  @ViewBuilder private var runControl: some View {
    if runningQueries > 0 {
      ProgressView().controlSize(.small)
    } else {
      Button {
        apply()
      } label: {
        Label("Run Query", systemImage: hasUnappliedChanges ? "play.circle.fill" : "play.circle")
          .labelStyle(.iconOnly).touchTarget(32)
      }.buttonStyle(.borderless)
        .help(hasUnappliedChanges ? "Run the edited query (Return)" : "Run the query again")
    }
  }

  private var hasUnappliedChanges: Bool { pendingSpec != model.currentQuery }

  /// Window subtitle: the connection plus the loaded-items summary, since the
  /// title names the open collection/table.
  private var subtitle: String {
    guard model.selectedCollection != nil, let name = model.connectionName else {
      return model.statusMessage
    }
    return model.statusMessage.isEmpty ? name : "\(name) · \(model.statusMessage)"
  }

  /// Edit-mode Update row: runs `updateMany(filter, update)` after a
  /// confirmation that states how many documents it will change.
  private var updateRow: some View {
    HStack(alignment: .center, spacing: 6) {
      Text("Update").font(.caption).foregroundStyle(.secondary)
        .frame(width: Self.queryLabelWidth, alignment: .trailing)
      TextField(
        "Update", text: $updateText, prompt: Text(#"{ $set: { status: "done" } }"#),
        axis: .vertical
      ).lineLimit(1...4).onSubmit { requestUpdate() }
      Button("Update…") { requestUpdate() }
        .disabled(isRunning || updateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Update every document matching the Filter (asks for confirmation)")
    }
  }

  /// "Search" box: writes ONE `$or` chip over every text field of the loaded
  /// rows, so a search is still a chip that can be removed again.
  private var searchField: some View {
    HStack(spacing: 4) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
      TextField("Search", text: $quickSearch, prompt: Text(searchPrompt))
        .textFieldStyle(.plain)
        .onChange(of: quickSearch) { _, _ in debounceQuickSearch() }
        .onSubmit { applyQuickSearch() }
      if !quickSearch.isEmpty {
        Button("Clear Search", systemImage: "xmark.circle.fill") {
          quickSearch = ""
          applyQuickSearch()
        }.buttonStyle(.plain).labelStyle(.iconOnly).foregroundStyle(.secondary)
          .help("Clear the search")
      }
    }
    .padding(.horizontal, 7).padding(.vertical, 4)
    .background(.background, in: RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
    .frame(maxWidth: isCompact ? .infinity : 280)
    .disabled(searchableFields.isEmpty && quickSearch.isEmpty)
    .help(
      searchableFields.isEmpty
        ? "There are no text fields to search in"
        : "Searches \(searchableFields.joined(separator: ", "))")
  }

  private var searchPrompt: String {
    searchableFields.isEmpty ? "Search" : "Search \(model.itemNoun.plural)"
  }

  /// Sort without syntax: pick a field and an order in plain words. Writes
  /// the Sort text, like the table's column headers.
  private var sortMenu: some View {
    Menu {
      ForEach(catalog, id: \.name) { field in
        Menu(field.name) {
          let words = Self.orderWords(for: field.kind)
          Button(words.ascending) { writeSort([SortKey(field: field.name, ascending: true)]) }
          Button(words.descending) { writeSort([SortKey(field: field.name, ascending: false)]) }
        }
      }
      if !sortKeys.isEmpty {
        Divider()
        Button("Don’t Sort", systemImage: "xmark.circle") { writeSortIfPossible([]) }
      }
    } label: {
      Label(sortSummary, systemImage: "arrow.up.arrow.down")
        .iconOnlyLabel(isCompact && sortKeys.isEmpty)
    }
    .fixedSize()
    .disabled(catalog.isEmpty)
    .help("Choose the order of the \(model.itemNoun.plural)")
  }

  /// "Sort" or "year, newest first".
  private var sortSummary: String {
    guard let first = sortKeys.first else { return "Sort" }
    let kind = catalog.first { $0.name == first.field }?.kind ?? .mixed
    let words = Self.orderWords(for: kind)
    let more = sortKeys.count > 1 ? " +\(sortKeys.count - 1)" : ""
    return "\(first.field), \((first.ascending ? words.ascending : words.descending).lowercased())\(more)"
  }

  /// How a person says "ascending/descending" for a kind of value.
  private static func orderWords(for kind: FieldKind) -> (ascending: String, descending: String) {
    switch kind {
    case .string: ("A to Z", "Z to A")
    case .number: ("Smallest First", "Largest First")
    case .date: ("Oldest First", "Newest First")
    case .boolean: ("No First", "Yes First")
    default: ("Ascending", "Descending")
    }
  }

  private func writeSortIfPossible(_ keys: [SortKey]) {
    guard let dialect = FilterEngine.dialect(for: model.activeEngine) else { return }
    writeSort(keys, dialect: dialect)
  }

  private func writeSort(_ keys: [SortKey]) { writeSortIfPossible(keys) }

  /// Hide/show menu for every loaded field. Writes the Projection text (through
  /// `handle`), so it can un-hide a column whose header is already gone.
  private var fieldsMenu: some View {
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
        .disabled(hiddenFields.isEmpty)
    } label: {
      Label(
        hiddenFields.isEmpty ? "Fields" : "\(hiddenFields.count) Hidden",
        systemImage: hiddenFields.isEmpty ? "eye" : "eye.slash"
      )
      .iconOnlyLabel(isCompact && hiddenFields.isEmpty)
    }
    .fixedSize()
    .disabled(allFields.isEmpty)
    .help("Hide or show fields")
  }

  /// Example syntax per engine: MongoDB and SQL take the JSON query dialect;
  /// SQL also accepts raw WHERE / ORDER BY fragments.
  private var filterPrompt: String {
    switch model.activeEngine {
    case .postgresql, .sqlite: "{ age: { $gt: 30 } }  or  age > 30"
    case .mongodb, .redis, nil: "{ age: { $gt: 30 } }"
    }
  }

  private var sortPrompt: String {
    switch model.activeEngine {
    case .postgresql, .sqlite: "{ age: -1 }  or  age DESC"
    case .mongodb, .redis, nil: "{ age: -1 }"
    }
  }

  private var projectPrompt: String { "{ name: 1, _id: 0 }" }

  /// Title/description of the empty state: "nothing matches" only when a
  /// query is actually restricting the results.
  private var emptyTitle: String { "No \(model.itemNoun.plural.capitalized)" }

  private var emptySummary: String {
    let noun = model.itemNoun.plural
    if model.currentQuery.isEmpty {
      return model.activeEngine == .redis
        ? "This database has no keys."
        : "“\(model.selectedCollection ?? "")” has no \(noun) yet."
    }
    return "No \(noun) match the search and filters."
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
              row: row, editor: editor, expandedKeys: expandedKeys,
              isEditable: editMode && showsQueryEditor && model.canEditDocuments,
              onToggle: toggleExpansion,
              onStartEdit: { startEditing(row) }, onCommit: commitEditor,
              onCancel: { editor = nil },
              keyMenuState: KeyMenuState(
                sortDirection: SortText.direction(of: row.queryPath ?? row.key, in: sortText),
                isHidden: hiddenFields.contains(row.key)),
              onColumnAction: columnActionHandler
            )
          }
          if editMode && model.canBulkEdit {
            AddFieldRow(onAdd: { key, value in
              Task {
                do {
                  try await model.addField(to: section.index, key: key, value: value)
                  actionError = nil
                } catch {
                  actionError = FriendlyError(error, while: .saving)
                }
              }
            }).padding(.leading, 16).padding(.vertical, 2)
          }
        } header: {
          HStack {
            Text(documentHeader(for: section.document, index: section.index)).font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Details", systemImage: "info.circle") {
              recordActions.showDetails(section.index)
            }.labelStyle(.iconOnly).buttonStyle(.borderless).help("Show details")
          }
          .contextMenu { RecordContextMenu(index: section.index, actions: recordActions) }
        }
      }
      // "Load more" sentinel: appears at the bottom while more rows exist.
      // Its `.onAppear` fires when the user scrolls to the bottom, loading the
      // next page; a ProgressView shows while a fetch is in flight.
      LoadMoreFooter()
    }.listStyle(.inset)
  }

  /// "<_id> · #3" for documents with an id, else "Row 3" / "Key 3" /
  /// "Document 3" per engine. Shared by the List and JSON formats.
  private func documentHeader(for doc: BSONDocument, index: Int) -> String {
    if let id = doc["_id"], !BSONSupport.displayString(id).isEmpty {
      return "\(BSONSupport.displayString(id)) · #\(index + 1)"
    }
    return "\(model.itemNoun.singular.capitalized) \(index + 1)"
  }

  // MARK: - Expansion / editing

  private func toggleExpansion(_ key: String) {
    if expandedKeys.contains(key) { expandedKeys.remove(key) } else { expandedKeys.insert(key) }
  }

  private func startEditing(_ row: FieldRow) {
    guard editMode && showsQueryEditor && model.canEditDocuments else { return }
    commitEditor()  // commit any in-flight edit before switching targets
    // Containers expand rather than edit; types without an editor stay read-only.
    guard !row.bson.isContainer, EditableType.canEdit(row.bson) else { return }
    editor = ValueEditorState(docIndex: row.docIndex, path: row.path, bson: row.bson)
  }

  /// Saves the edited value to the server. The editor closes right away; on
  /// failure the row keeps its server value and the error is shown.
  private func commitEditor() {
    guard let editor, let value = editor.committedValue() else { return }  // keep open on parse failure
    self.editor = nil
    Task {
      do {
        try await model.updateDocument(editor.docIndex, at: editor.path, to: value)
        actionError = nil
      } catch {
        actionError = FriendlyError(error, while: .saving)
      }
    }
  }

  // MARK: - Update (edit mode)

  /// Validates the Update text and counts the matching documents, then asks
  /// for confirmation (see the `.alert` on `pendingUpdate`).
  private func requestUpdate() {
    guard !isRunning else { return }
    let filter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    let update = updateText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !update.isEmpty else { return }
    isRunning = true
    Task {
      defer { isRunning = false }
      do {
        try model.validateUpdate(update)
        let count = try await model.countMatching(filter: filter)
        actionError = nil
        pendingUpdate = PendingUpdate(filter: filter, update: update, count: count)
      } catch {
        actionError = FriendlyError(error, while: .saving)
      }
    }
  }

  private func runUpdate(_ pending: PendingUpdate) {
    isRunning = true
    Task {
      defer { isRunning = false }
      do {
        _ = try await model.runUpdate(filter: pending.filter, update: pending.update)
        actionError = nil
      } catch {
        actionError = FriendlyError(error, while: .saving)
      }
    }
  }

  // MARK: - Query execution

  /// The query the bar currently describes.
  private var pendingSpec: QuerySpec {
    QuerySpec(filter: trimmed(filterText), sort: trimmed(sortText), projection: trimmed(projectText))
  }

  private func apply() {
    debounceTask?.cancel()
    // The selection is an index: after a new query it would point at
    // another record.
    selectedRecord = nil
    model.currentQuery = pendingSpec
    runningQueries += 1
    Task {
      defer { runningQueries -= 1 }
      // Failures land in `model.queryError`, which the pane renders.
      _ = try? await model.applyQuery()
    }
  }

  // MARK: - Filter chips

  /// Writes the chips into the Filter field and re-runs the query. The chip text
  /// is the single source of truth for execution while chips exist.
  /// Asks first (see the overwrite alert) when the Filter holds text typed by
  /// hand, which the chips would otherwise silently replace. Removing every
  /// chip just drops them and keeps the typed filter.
  private func applyRules(confirmed: Bool = false) {
    guard let dialect = FilterEngine.dialect(for: model.activeEngine) else { return }
    if typedFilterDiffers && !confirmed {
      if filterRules.isEmpty {
        renderedRules = []
      } else {
        confirmsFilterOverwrite = true
      }
      return
    }
    let text = FilterText.render(filterRules, dialect: dialect, anyOfFields: quickSearchFields) ?? ""
    filterText = text
    lastRenderedFilter = text
    renderedRules = filterRules
    apply()
  }

  /// The Filter holds non-empty text the chips didn't write.
  private var typedFilterDiffers: Bool {
    let text = trimmed(filterText) ?? ""
    return !text.isEmpty && text != lastRenderedFilter
  }

  /// Chips exist but the Filter no longer holds what they wrote.
  private var chipsOutOfSync: Bool {
    // Not while the overwrite prompt is up: the chip it asks about is pending.
    !confirmsFilterOverwrite && !filterRules.isEmpty
      && (trimmed(filterText) ?? "") != lastRenderedFilter
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
  /// Emptying the box removes the chip again.
  private func applyQuickSearch() {
    quickSearchTask?.cancel()
    let text = quickSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    let hadChip = filterRules.contains { $0.field == Self.quickSearchMarker }
    guard !text.isEmpty || hadChip else { return }
    filterRules.removeAll { $0.field == Self.quickSearchMarker }
    guard !text.isEmpty else {
      applyRules()
      return
    }
    quickSearchFields = searchableFields
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
    let typed = searchFragment.trimmingCharacters(in: .whitespacesAndNewlines)
    let fragment = typed.withStraightQuotes ?? typed
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

  /// Re-runs the query once typing pauses. Text written programmatically
  /// (chips, column menus, collection reset) has usually been applied already;
  /// comparing with `model.currentQuery` skips that duplicate run.
  private func debounceApply() {
    debounceTask?.cancel()
    guard pendingSpec != model.currentQuery, pendingSpecParses else { return }
    debounceTask = Task {
      try? await Task.sleep(for: Self.applyDelay)
      guard !Task.isCancelled, pendingSpec != model.currentQuery else { return }
      apply()
    }
  }

  /// Typing only auto-runs text that parses as a query: a pause mid-expression
  /// (`{ age: ` or SQL `age >`) used to run it and flash a failure. Raw SQL
  /// fragments never parse here, so they run on Return / Run. Redis key globs
  /// come from the key box and always run.
  private var pendingSpecParses: Bool {
    guard model.activeEngine != .redis else { return true }
    return [filterText, sortText, projectText].allSatisfy { text in
      guard let text = trimmed(text) else { return true }
      return (try? BSONSupport.document(fromQuery: text)) != nil
    }
  }

  /// How long typing must pause before the query re-runs. A query per keystroke
  /// meant a round trip plus a full document/table re-render per character,
  /// which made typing in the query bar feel blocked.
  private static let applyDelay: Duration = .seconds(1)

  /// Debounced "search all text fields": typing re-runs the search one second
  /// after the last keystroke (emptying the box removes the chip); the Search
  /// button applies immediately. Has its own task so it never cancels a
  /// pending Filter/Sort/Project apply.
  private func debounceQuickSearch() {
    quickSearchTask?.cancel()
    quickSearchTask = Task {
      try? await Task.sleep(for: Self.applyDelay)
      guard !Task.isCancelled else { return }
      applyQuickSearch()
    }
  }

  private func trimmed(_ string: String) -> String? {
    let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }

  private func refresh() {
    if isAggregating { runPipeline() } else { apply() }
  }

  // MARK: - Aggregation

  /// Column/key menus rewrite the Find bar's text, which doesn't drive
  /// aggregation output — so they're off while aggregating.
  private var columnActionHandler: ((ColumnAction) -> Void)? {
    guard !isAggregating else { return nil }
    return { handle($0) }
  }

  /// The pipeline builder replaces the Find bar (never for Redis).
  private var isAggregating: Bool { queryMode == .aggregate && model.canAggregate }

  /// Something restricts the shown results (offers "Clear" in empty states).
  private var isQueryActive: Bool {
    isAggregating ? !pipelineStages.isEmpty : !model.currentQuery.isEmpty
  }

  private var queryModeBinding: Binding<QueryMode> {
    Binding(get: { queryMode }, set: { switchMode(to: $0) })
  }

  /// Switches the query surface and re-runs what it now shows, so the results
  /// always match the visible controls. An empty pipeline starts from the Find
  /// bar's query; going back to Find drops the pipeline.
  private func switchMode(to mode: QueryMode) {
    guard mode != queryMode else { return }
    queryMode = mode
    editMode = false
    editor = nil
    switch mode {
    case .aggregate:
      if pipelineStages.isEmpty {
        pipelineStages = AggregationPipeline.stages(
          filter: trimmed(filterText), sort: trimmed(sortText), projection: trimmed(projectText))
      }
      runPipeline()
    case .find:
      appliedStages = []
      model.currentPipeline = nil
      apply()
    }
  }

  /// Runs the builder's pipeline — every enabled stage, or only up to
  /// `throughStage`. A stage that doesn't parse is flagged on its card and
  /// nothing runs; server/compile failures land in `model.queryError`.
  private func runPipeline(throughStage: Int? = nil) {
    debounceTask?.cancel()
    let selected = throughStage.map { Array(pipelineStages.prefix($0 + 1)) } ?? pipelineStages
    guard let documents = try? AggregationPipeline.documents(selected) else { return }
    appliedStages = selected
    selectedRecord = nil
    runningQueries += 1
    Task {
      defer { runningQueries -= 1 }
      _ = try? await model.applyPipeline(documents)
    }
  }
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

/// An Update the user still has to confirm.
private struct PendingUpdate {
  let filter: String
  let update: String
  let count: Int
}

/// Delete sheet: counts every entry the current filter matches, previews the
/// first few hundred, then requires explicit confirmation before deleting.
private struct DeleteSheet: View {
  @Environment(DatabaseModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let filter: String

  @State private var preview: [BSONDocument]?
  /// Exact number of matches — what deleteMany will really remove.
  @State private var total: Int?
  @State private var previewError: String?
  @State private var isDeleting = false
  @State private var confirmDelete = false

  private static let previewLimit = 500

  private var trimmedFilter: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var totalText: String {
    guard let total else { return "" }
    return "\(total) \(total == 1 ? "document" : "documents")"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Delete Documents").font(.headline)
      if trimmedFilter.isEmpty {
        Label(
          "No filter is set — EVERY document in \(model.selectedCollection ?? "the collection") matches.",
          systemImage: "exclamationmark.triangle.fill"
        ).font(.callout).foregroundStyle(.red)
      } else {
        Text("Filter: \(trimmedFilter)").font(.caption).foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Group {
        if let error = previewError {
          Text(error).font(.caption).foregroundStyle(.red)
        } else if let preview, let total {
          if total == 0 {
            Text("No documents match this filter.").font(.caption).foregroundStyle(.secondary)
          } else {
            Text(
              total > preview.count
                ? "\(totalText) will be deleted. Showing the first \(preview.count):"
                : "\(totalText) will be deleted:"
            ).font(.caption).foregroundStyle(.secondary)
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
        Button(total.map { "Delete \($0)" } ?? "Delete", role: .destructive) { confirmDelete = true }
          .disabled(isDeleting || total == nil || total == 0)
      }
    }.padding().frame(width: 540).task { await loadPreview() }.alert(
      "Delete \(totalText)?", isPresented: $confirmDelete
    ) {
      Button("Delete", role: .destructive) { Task { await delete() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This cannot be undone.")
    }
  }

  private func loadPreview() async {
    do {
      total = try await model.countMatching(filter: trimmedFilter)
      preview = try await model.previewDelete(filter: trimmedFilter, limit: Self.previewLimit)
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
    } catch { previewError = error.localizedDescription }
  }
}

/// The record editor sheet and the single-record delete confirmation, for
/// whichever view starts them (the pane, or the inspector).
private struct RecordDialogs: ViewModifier {
  @Environment(DatabaseModel.self) private var model
  @Binding var editor: RecordEditorTarget?
  @Binding var deletion: Int?
  let fields: [FieldInfo]
  let onDelete: (Int) -> Void

  func body(content: Content) -> some View {
    content
      .sheet(item: $editor) { target in
        RecordEditorView(target: target, fields: fields)
      }
      .confirmationDialog(
        deletion.map(title) ?? "",
        isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
        titleVisibility: .visible, presenting: deletion
      ) { index in
        Button("Delete", role: .destructive) { onDelete(index) }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text(
          "It will be removed from “\(model.selectedCollection ?? "")”. You can undo this right after.")
      }
  }

  /// "Delete “Up”?" — the record by name where it has one.
  private func title(_ index: Int) -> String {
    let noun = model.itemNoun.singular
    guard model.documents.indices.contains(index), let name = RecordName.of(model.documents[index])
    else { return "Delete this \(noun)?" }
    return "Delete “\(name)”?"
  }
}
