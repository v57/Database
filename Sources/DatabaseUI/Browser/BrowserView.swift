import ComponentKit
import DatabaseKit
import SwiftUI

/// The main pane for a table or collection: simple bar, grid, changes, status bar, inspector.
struct BrowserView: View {
  @Bindable var browser: BrowserModel
  @Bindable var window: WindowModel
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.showToast) private var toast
  @State private var adding = false
  @State private var deleting: [Record] = []

  var body: some View {
    titled
      .kitSheet(isPresented: $browser.showsReview) {
        ReviewSheet(browser: browser).componentKit(accent: .databaseAccent)
      }
      .kitSheet(isPresented: $browser.showsIndexes) {
        IndexesSheet(browser: browser).componentKit(accent: .databaseAccent)
      }
      .kitSheet(isPresented: $adding) {
        NewItemSheet(browser: browser).componentKit(accent: .databaseAccent)
      }
      .kitConfirmation(
        "Delete \(browser.noun.count(deleting.count))?", isPresented: isDeleting,
        message: "You'll see the change before anything is deleted.", systemImage: "trash", confirm: "Add to Changes",
        action: stageDeletes)
      .onChange(of: browser.toast) { _, message in showToast(message) }
      // Its own modifier, as the inspector is its own view: the selection read in this body built the whole pane again
      // (bar, filters, grid, status bar) on every click in the grid.
      .modifier(DeleteActionFocus(browser: browser, deleting: $deleting))
      .modifier(PageSizeSetting(browser: browser))
  }

  private var titled: some View {
    split
      .kitToolbar(browser.ref.name, meta: [subtitle], systemImage: browser.ref.symbol, hue: browser.engine.hue, status: titleStatus) {
        tools
      }
  }

  private var split: some View {
    InspectorSplit("inspectorWidth", range: 280...520, isShown: showsInspector) {
      main
    } pane: {
      BrowserInspector(browser: browser, window: window, deleting: $deleting)
    } over: {
      SelectionInspector(browser: browser, window: window, deleting: $deleting)
    }
  }

  private var isDeleting: Binding<Bool> {
    Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })
  }

  private func stageDeletes() {
    browser.stageDelete(deleting)
    deleting = []
    browser.showsReview = true
  }

  /// "Saved 3 changes", with Undo, for a few seconds after saving.
  private func showToast(_ message: String?) {
    guard let message else { return }
    let browser = browser
    var undo: (@MainActor () -> Void)?
    if browser.canUndo {
      undo = { @MainActor in
        Task { @MainActor in await browser.undo() }
      }
    }
    toast(Toast(message, systemImage: "checkmark", duration: .seconds(8), undo: undo))
    browser.toast = nil
  }

  private var main: some View {
    VStack(spacing: 0) {
      if browser.mode == .aggregate {
        PipelineView(pipeline: browser.pipeline, browser: browser)
      } else {
        FilterBar(browser: browser)
        if browser.showsQueryEditor {
          QueryStrip(browser: browser)
        }
        notices
        content
        if !browser.pending.isEmpty {
          changes
            .padding([.horizontal, .top], KitMetrics.gutter)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        statusBar
      }
    }
    .animation(.kit, value: browser.pending.isEmpty)
    .kitPane(.content)
  }

  private var showsInspector: Bool {
    window.showsInspector && sizeClass != .compact && browser.mode == .find && !browser.collapsesInspector
  }

  private var subtitle: String {
    var parts = [browser.connection.profile.displayName]
    if !browser.ref.location.isEmpty { parts.append(browser.ref.location) }
    if let total = browser.exactTotal ?? browser.page?.total { parts.append(browser.noun.count(total)) }
    return parts.joined(separator: " › ")
  }

  @ViewBuilder private var content: some View {
    if let error = browser.errorMessage, browser.page == nil {
      EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn't Load \(browser.noun.pluralCapitalized)", message: "\(error)") {
        Button("Try Again") { Task { await browser.reload() } }.buttonStyle(.kitPrimary)
      }
    } else if let runs = browser.customRunsForDisplay {
      QueryResultsView(outputs: runs, connection: browser.connection)
    } else if browser.page == nil {
      LiveIcon(systemImage: browser.ref.symbol, hue: browser.engine.hue, status: .working, size: 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if browser.records.isEmpty {
      EmptyState(systemImage: "doc.text.magnifyingglass", title: emptyTitle, message: emptyDescription) {
        if !browser.request.activeFilters.isEmpty || !browser.request.search.isEmpty {
          Button("Clear Filters") {
            browser.request.filters = []
            browser.request.search = ""
            Task { await browser.reload() }
          }
          .buttonStyle(.kit)
        }
      }
    } else if sizeClass == .compact {
      PhoneRecordList(browser: browser, window: window)
    } else {
      switch browser.viewMode {
      case .table:
        RecordTable(browser: browser, window: window, onDelete: { deleting = $0 })
          .padding(.horizontal, KitMetrics.gutter)
      case .cards: CardsView(browser: browser)
      case .json: JSONListView(browser: browser)
      }
    }
  }

  private var emptyTitle: String {
    browser.request.activeFilters.isEmpty && browser.request.search.isEmpty
      ? String(localized: "No \(browser.noun.pluralCapitalized)") : String(localized: "No Matches")
  }

  private var emptyDescription: String {
    browser.request.activeFilters.isEmpty && browser.request.search.isEmpty
      ? String(localized: "This \(browser.engine.collectionNoun.singular) is empty.")
      : String(localized: "Nothing matches the search and filters.")
  }

  @ViewBuilder private var notices: some View {
    if let error = browser.errorMessage, browser.page != nil {
      Banner(error, systemImage: "exclamationmark.triangle", hue: .red, onDismiss: { browser.errorMessage = nil })
        .padding([.horizontal, .bottom], KitMetrics.gutter)
    }
    ForEach(browser.page?.notes ?? [], id: \.self) { note in
      Banner(note, systemImage: "info.circle", hue: .gray)
        .padding([.horizontal, .bottom], KitMetrics.gutter)
    }
  }

  /// The edits waiting for review, under the grid.
  private var changes: some View {
    ChangesCard(
      count: browser.pending.count, discardAll: { withKitAnimation { browser.discardChanges() } },
      review: { browser.showsReview = true }
    ) {
      // "orders on Shop [Production] · nothing is saved until you review"
      HStack(spacing: 6) {
        Text("\(browser.ref.name) on \(browser.connection.profile.displayName)")
        if browser.connection.profile.isProduction { Chip.production.controlSize(.small) }
        Text("·").foregroundStyle(.kitTertiary)
        Text("nothing is saved until you review")
      }
      .lineLimit(1)
    } rows: {
      ForEach(browser.pending) { edit in
        PendingChangeRow(edit: edit, browser: browser)
      }
    }
  }

  /// Counts, timing, safety notice and paging.
  private var statusBar: some View {
    StatusBar {
      Text(browser.pageLabel)
      if let elapsed = browser.page?.elapsed {
        Text(formatDuration(elapsed)).foregroundStyle(.kitTertiary)
      }
      if browser.connection.profile.isProduction {
        Label(sizeClass == .compact ? "Production" : "Production: every change is reviewed before saving", systemImage: "shield")
      } else if browser.connection.profile.isReadOnly {
        Label("Read only", systemImage: "lock")
      } else if browser.ref.kind == .view {
        Label("View: read only", systemImage: "eye")
      }
      Spacer()
      Button("Previous Page", systemImage: "chevron.left") { Task { await browser.previousPage() } }
        .disabled(browser.request.offset == 0)
      Button("Next Page", systemImage: "chevron.right") { Task { await browser.nextPage() } }
        .disabled(browser.page?.hasMore != true)
    }
    .buttonStyle(.kitIcon)
    .padding(.top, KitMetrics.gutter)
  }

  /// The pane's tools. As the bar narrows, "show as" folds into "…" first, then the mode, then the query editor,
  /// refresh and add; reviewing changes never folds.
  @ToolbarSlotBuilder private var tools: [ToolbarSlot] {
    if hasModes {
      ToolbarSlot(priority: 1) {
        KitSegmented(selection: modeSelection, segments: modeSegments)
      } menu: {
        KitSubmenu("Mode", systemImage: "square.stack.3d.up") {
          KitMenuOptions(selection: modeSelection, segments: modeSegments)
        }
      }
    }
    if browser.mode == .find {
      ToolbarSlot(priority: 0) {
        KitSegmented(selection: $browser.viewMode, options: availableModes.map { ($0.rawValue, $0) })
      } menu: {
        KitSubmenu("Show As", systemImage: "rectangle.grid.1x2") {
          KitMenuOptions(selection: $browser.viewMode, options: availableModes.map { ($0.rawValue, $0) })
        }
      }
    }
    if !browser.pending.isEmpty {
      ToolGroup {
        Button {
          browser.showsReview = true
        } label: {
          Label {
            HStack(spacing: 4) {
              Text("Review Changes").foregroundStyle(Hue.accent.text)
              Count(browser.pending.count, .attention)
            }
          } icon: {
            Image(systemName: "checklist").foregroundStyle(Hue.accent.text)
          }
        }
        .kitHelp("Review Changes", shortcut: "⌘S", systemImage: "checklist")
      }
    }
    ToolbarSlot(priority: 2) {
      ToolGroup(iconOnly: true) {
        if browser.mode == .find {
          Button(
            browser.showsQueryEditor ? "Hide Query Editor" : "Show Query Editor",
            systemImage: "chevron.left.forwardslash.chevron.right"
          ) {
            browser.showsQueryEditor.toggle()
          }
          .kitToolOn(browser.showsQueryEditor)
          .kitHelp(
            browser.showsQueryEditor ? "Hide Query Editor" : "Show Query Editor", shortcut: "⇧⌘E",
            systemImage: "chevron.left.forwardslash.chevron.right")
          if browser.showsQueryEditor, browser.hasIndexes {
            Button("Indexes", systemImage: "bolt.horizontal") { browser.showsIndexes = true }
              .kitHelp("Indexes", systemImage: "bolt.horizontal")
          }
        }
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await browser.reload() } }
          .kitHelp("Refresh", systemImage: "arrow.clockwise")
        if canAdd {
          Button("Add \(browser.noun.capitalized)", systemImage: "plus") { adding = true }
        }
        // The Mac has View › Show Inspector; an iPad only this (D-014).
        if hasInspectorTool {
          Button(window.showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") {
            withKitAnimation { window.showsInspector.toggle() }
          }
          .kitToolOn(window.showsInspector)
        }
      }
    } menu: {
      if browser.mode == .find {
        Toggle("Query Editor", systemImage: "chevron.left.forwardslash.chevron.right", isOn: $browser.showsQueryEditor)
        if browser.showsQueryEditor, browser.hasIndexes {
          Button("Indexes", systemImage: "bolt.horizontal") { browser.showsIndexes = true }
        }
      }
      Button("Refresh", systemImage: "arrow.clockwise") { Task { await browser.reload() } }
        .kitMenuPreview("Loads the \(browser.noun.plural) again, from the first page.")
      if canAdd {
        Button("Add \(browser.noun.capitalized)", systemImage: "plus") { adding = true }
      }
      if hasInspectorTool {
        Toggle("Inspector", systemImage: "sidebar.right", isOn: $window.showsInspector)
      }
    }
  }

  private var canAdd: Bool { browser.isEditable && browser.mode == .find }

  private var hasInspectorTool: Bool {
    idiom != .mac && sizeClass != .compact && browser.mode == .find && !browser.collapsesInspector
  }

  /// The title's live icon: the arc while the page loads.
  private var titleStatus: WorkStatus {
    browser.isLoading && browser.page != nil ? .working : .idle
  }

  private var hasModes: Bool { browser.engine.family == .document || browser.engine.family == .sql }

  private var modeSegments: [KitSegment<BrowserModel.Mode>] {
    BrowserModel.Mode.allCases.map {
      KitSegment($0.rawValue, value: $0, systemImage: $0 == .find ? "magnifyingglass" : "square.stack.3d.up")
    }
  }

  private var modeSelection: Binding<BrowserModel.Mode> {
    Binding(get: { browser.mode }, set: { mode in Task { await browser.switchMode(mode) } })
  }

  private var availableModes: [BrowserModel.ViewMode] {
    browser.engine.family == .document ? BrowserModel.ViewMode.allCases : [.table, .json]
  }

}

/// The inspector beside the grid: the selected item, several, or none. Reads the selection itself, so a click in the
/// grid updates it and the grid, not the pane around them.
private struct BrowserInspector: View {
  let browser: BrowserModel
  let window: WindowModel
  @Binding var deleting: [Record]

  var body: some View {
    if browser.selectedRecords.count > 1 {
      MultiSelectionInspector(browser: browser) { deleting = $0 }
    } else if let record = browser.selectedRecord {
      if browser.engine.family == .document {
        DocumentInspector(browser: browser, record: record, onDelete: { deleting = [record] })
      } else {
        RecordInspector(browser: browser, record: record, window: window, onDelete: { deleting = [record] })
      }
    } else {
      EmptyState(systemImage: "sidebar.right", title: "No Selection", message: "Select a \(browser.noun.singular) to see its fields.")
        .kitPane(.secondary)
    }
  }
}

/// The inspector over the grid while something is selected, where the pane has no room beside it.
private struct SelectionInspector: View {
  let browser: BrowserModel
  let window: WindowModel
  @Binding var deleting: [Record]

  var body: some View {
    if !browser.selectedRecords.isEmpty {
      BrowserInspector(browser: browser, window: window, deleting: $deleting)
    }
  }
}

/// A pane's main view with its inspector beside it, resizable, or, where the two don't fit side by side (an iPad mini
/// in portrait, beside the sidebar: D-014), the inspector floating over the main view's trailing side while `over`
/// has something to show. The toolbar's Hide Inspector takes it away.
struct InspectorSplit<Main: View, Pane: View, Over: View>: View {
  let autosaveName: String
  let range: ClosedRange<CGFloat>
  let isShown: Bool
  let main: Main
  let pane: Pane
  let over: Over

  static var mainMinWidth: CGFloat { 420 }

  init(
    _ autosaveName: String, range: ClosedRange<CGFloat>, isShown: Bool, @ViewBuilder main: () -> Main,
    @ViewBuilder pane: () -> Pane, @ViewBuilder over: () -> Over
  ) {
    self.autosaveName = autosaveName
    self.range = range
    self.isShown = isShown
    self.main = main()
    self.pane = pane()
    self.over = over()
  }

  var body: some View {
    // The width offered, not the width taken: a split wider than the pane would measure as fitting.
    GeometryReader { proxy in
      layout(width: proxy.size.width)
        .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }

  @ViewBuilder private func layout(width: CGFloat) -> some View {
    if isShown && width >= Self.mainMinWidth + range.lowerBound {
      ResizableSplit(
        autosaveName, pane: .trailing, width: KitMetrics.inspectorWidth, range: range, mainMinWidth: Self.mainMinWidth
      ) {
        main
      } pane: {
        pane
      }
    } else {
      main
        .overlay(alignment: .trailing) {
          if isShown {
            over
              .frame(width: min(range.lowerBound + 20, max(0, width - 64)))
              .frame(maxHeight: .infinity)
              .kitOverlayCard()
              .padding(KitMetrics.gutter)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
    }
  }
}

/// Delete in the Edit menu for the selected items, while there are some to delete.
/// Follows Settings ▸ General ▸ Items per page (D-019), in its own view so the pane doesn't read the setting: while the
/// browser shows, and when it shows again. On iPhone the browser isn't on screen while Settings is, so a change made
/// there reached no `onChange`, and the table opened before kept its old size until a relaunch; the size is now
/// checked each time the browser appears too (a cached model reloads only when it differs).
private struct PageSizeSetting: ViewModifier {
  let browser: BrowserModel
  @KitStorage(BrowserModel.pageSizeKey) private var pageSize = 50

  func body(content: Content) -> some View {
    content.task(id: pageSize) {
      await browser.changePageSize(to: BrowserModel.pageSize(for: browser.connection.profile.engine))
    }
  }
}

private struct DeleteActionFocus: ViewModifier {
  let browser: BrowserModel
  @Binding var deleting: [Record]

  func body(content: Content) -> some View {
    content.focusedSceneValue(\.deleteAction, deleteAction)
  }

  private var deleteAction: (() -> Void)? {
    guard browser.isEditable, !browser.selectedRecords.isEmpty else { return nil }
    return { [browser, binding = $deleting] in binding.wrappedValue = browser.selectedRecords }
  }
}

/// One pending edit in the changes card, with its Undo.
private struct PendingChangeRow: View {
  let edit: RecordEdit
  let browser: BrowserModel

  var body: some View {
    let title = edit.key?.summary ?? edit.title
    let undo = { withKitAnimation { browser.revert(edit.id) } }
    switch edit.kind {
    case .update(let changes):
      if changes.count == 1, let change = changes.first {
        ChangeRow(.edited, title: title, field: change.field, old: change.old.reviewText, new: change.new.reviewText, undo: undo)
      } else {
        ChangeRow(.edited, title: title, field: "\(changes.count) fields", undo: undo) {
          Text(changes.map(\.field).joined(separator: ", ")).foregroundStyle(.kitSecondary)
        }
      }
    case .insert(let values):
      ChangeRow(.inserted, title: title, field: "row", new: summary(values), undo: undo)
    case .delete(let record):
      ChangeRow(.deleted, title: title, field: "row", old: summary(record.values), undo: undo)
    }
  }

  private func summary(_ values: [String: CellValue]) -> String {
    browser.fields.filter { !$0.isPrimaryKey }.prefix(3).compactMap { values[$0.name]?.displayText }.joined(separator: ", ")
  }
}

extension CellValue {
  /// How a value reads in a review: "empty" for NULL, "missing" for a field a document doesn't have.
  var reviewText: String { self == .unset ? "missing" : isNull ? "empty" : displayText }
}

extension ObjectRef {
  var symbol: String {
    switch kind {
    case .table: "tablecells"
    case .view, .materializedView: "eye"
    case .collection: "curlybraces"
    case .redisDatabase: "key"
    case .file: "doc"
    }
  }
}

extension BrowserModel {
  /// Results of an edited query in the Query Editor strip, shown instead of the list.
  var customRunsForDisplay: [QueryOutput]? {
    guard queryIsCustom, let runs = customRuns else { return nil }
    return runs.flatMap(\.outputs)
  }
}

extension FocusedValues {
  @Entry var deleteAction: (() -> Void)?
}

