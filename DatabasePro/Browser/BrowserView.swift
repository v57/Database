import DatabaseCore
import SwiftUI

/// The main pane for a table or collection: simple bar, list, status bar, inspector.
struct BrowserView: View {
  @Bindable var browser: BrowserModel
  @Bindable var window: WindowModel
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var adding = false
  @State private var deleting: [Record] = []

  var body: some View {
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
        StatusBar(browser: browser)
      }
    }
    .background(.background)
    .navigationTitle(browser.ref.name)
    #if os(macOS)
      .navigationSubtitle(subtitle)
    #endif
    .toolbar { toolbar }
    .inspector(isPresented: inspectorShown) {
      inspector
        .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
    }
    .sheet(isPresented: $browser.showsReview) {
      ReviewSheet(browser: browser).appButtonShape()
    }
    .sheet(isPresented: $adding) {
      NewItemSheet(browser: browser).appButtonShape()
    }
    .confirmationDialog(
      "Delete \(browser.noun.count(deleting.count))?", isPresented: .init(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
      titleVisibility: .visible
    ) {
      Button("Add to Changes", role: .destructive) {
        browser.stageDelete(deleting)
        deleting = []
        browser.showsReview = true
      }
    } message: {
      Text("You'll see the change before anything is deleted.")
    }
    .overlay(alignment: .bottom) { ToastView(browser: browser) }
    .focusedSceneValue(\.deleteAction, browser.isEditable && !browser.selectedRecords.isEmpty ? { deleting = browser.selectedRecords } : nil)
  }

  private var subtitle: String {
    var parts = [browser.connection.profile.displayName]
    if !browser.ref.location.isEmpty { parts.append(browser.ref.location) }
    if let total = browser.exactTotal ?? browser.page?.total { parts.append(browser.noun.count(total)) }
    return parts.joined(separator: " › ")
  }

  private var inspectorShown: Binding<Bool> {
    Binding(
      get: { window.showsInspector && sizeClass != .compact && browser.mode == .find && !browser.collapsesInspector },
      set: { window.showsInspector = $0 })
  }

  @ViewBuilder private var content: some View {
    if let error = browser.errorMessage, browser.page == nil {
      ContentUnavailableView {
        Label("Couldn't Load \(browser.noun.pluralCapitalized)", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error)
      } actions: {
        Button("Try Again") { Task { await browser.reload() } }
      }
    } else if let runs = browser.customRunsForDisplay {
      QueryResultsView(outputs: runs, connection: browser.connection)
    } else if browser.page == nil {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if browser.records.isEmpty {
      ContentUnavailableView {
        Label(emptyTitle, systemImage: "doc.text.magnifyingglass")
      } description: {
        Text(emptyDescription)
      } actions: {
        if !browser.request.activeFilters.isEmpty || !browser.request.search.isEmpty {
          Button("Clear Filters") {
            browser.request.filters = []
            browser.request.search = ""
            Task { await browser.reload() }
          }
        }
      }
    } else if sizeClass == .compact {
      PhoneRecordList(browser: browser, window: window)
    } else {
      switch browser.viewMode {
      case .table: RecordTable(browser: browser, window: window, onDelete: { deleting = $0 })
      case .cards: CardsView(browser: browser)
      case .json: JSONListView(browser: browser)
      }
    }
  }

  private var emptyTitle: String {
    browser.request.activeFilters.isEmpty && browser.request.search.isEmpty
      ? "No \(browser.noun.pluralCapitalized)" : "No Matches"
  }

  private var emptyDescription: String {
    browser.request.activeFilters.isEmpty && browser.request.search.isEmpty
      ? "This \(browser.engine.collectionNoun.singular) is empty."
      : "Nothing matches the search and filters."
  }

  @ViewBuilder private var notices: some View {
    if let error = browser.errorMessage, browser.page != nil {
      Banner(text: error, systemImage: "exclamationmark.triangle.fill", color: .red) { browser.errorMessage = nil }
    }
    ForEach(browser.page?.notes ?? [], id: \.self) { note in
      Banner(text: note, systemImage: "info.circle", color: .secondary, onDismiss: nil)
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if sizeClass == .compact {
        compactViewMenu
      } else {
        viewControls
      }
      if !browser.pending.isEmpty {
        Button {
          browser.showsReview = true
        } label: {
          Label("Review \(browser.pending.count) Change\(browser.pending.count == 1 ? "" : "s")", systemImage: "checklist")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
      }
      Button("Refresh", systemImage: "arrow.clockwise") { Task { await browser.reload() } }
        .help("Refresh (⌘R)")
      if browser.isEditable && browser.mode == .find {
        Button("Add \(browser.noun.capitalized)", systemImage: "plus") { adding = true }
          .help("Add a \(browser.noun.singular)")
      }
    }
  }

  private var hasModes: Bool { browser.engine.family == .document || browser.engine.family == .sql }

  /// Mode, "show as" and the Query Editor toggle, side by side in a wide toolbar.
  @ViewBuilder private var viewControls: some View {
      if hasModes {
        Picker("Mode", selection: modeSelection) {
          ForEach(BrowserModel.Mode.allCases) { mode in
            Label(mode.rawValue, systemImage: mode == .find ? "magnifyingglass" : "square.stack.3d.up").tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .help("Find items, or build an aggregation pipeline")
      }
      if browser.mode == .find {
        Picker("Show As", selection: $browser.viewMode) {
          ForEach(availableModes) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("Show as table, cards or JSON")
        Toggle(isOn: $browser.showsQueryEditor) {
          Label("Query Editor", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .help("Show the query the simple bar writes")
      }
  }

  /// The same choices in one menu, for a phone's toolbar.
  private var compactViewMenu: some View {
    Menu {
      if hasModes {
        Picker("Mode", selection: modeSelection) {
          ForEach(BrowserModel.Mode.allCases) { mode in
            Label(mode.rawValue, systemImage: mode == .find ? "magnifyingglass" : "square.stack.3d.up").tag(mode)
          }
        }
        .pickerStyle(.inline)
      }
      if browser.mode == .find {
        Picker("Show As", selection: $browser.viewMode) {
          ForEach(availableModes) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.inline)
        Toggle("Query Editor", systemImage: "chevron.left.forwardslash.chevron.right", isOn: $browser.showsQueryEditor)
      }
    } label: {
      Label("View", systemImage: "line.3.horizontal.decrease")
    }
  }

  private var modeSelection: Binding<BrowserModel.Mode> {
    Binding(get: { browser.mode }, set: { mode in Task { await browser.switchMode(mode) } })
  }

  private var availableModes: [BrowserModel.ViewMode] {
    browser.engine.family == .document ? BrowserModel.ViewMode.allCases : [.table, .json]
  }

  @ViewBuilder private var inspector: some View {
    if browser.selectedRecords.count > 1 {
      MultiSelectionInspector(browser: browser) { deleting = $0 }
    } else if let record = browser.selectedRecord {
      if browser.engine.family == .document {
        DocumentInspector(browser: browser, record: record, onDelete: { deleting = [record] })
      } else {
        RecordInspector(browser: browser, record: record, window: window, onDelete: { deleting = [record] })
      }
    } else {
      ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a \(browser.noun.singular) to see its fields."))
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

/// A one-line notice above the list.
struct Banner: View {
  let text: String
  let systemImage: String
  let color: Color
  var onDismiss: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage).foregroundStyle(color)
      Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
      if let onDismiss {
        Button("Dismiss", systemImage: "xmark", action: onDismiss)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
  }
}

/// Counts, timing, safety notice and paging.
struct StatusBar: View {
  let browser: BrowserModel
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    HStack(spacing: 14) {
      if browser.isLoading {
        ProgressView().controlSize(.mini)
      }
      Text(browser.pageLabel)
      if let elapsed = browser.page?.elapsed {
        Text(formatDuration(elapsed))
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
        .labelStyle(.iconOnly)
        .disabled(browser.request.offset == 0)
      Button("Next Page", systemImage: "chevron.right") { Task { await browser.nextPage() } }
        .labelStyle(.iconOnly)
        .disabled(browser.page?.hasMore != true)
    }
    .buttonStyle(.borderless)
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }
}

/// "Saved 3 changes · Undo", for a few seconds after saving.
struct ToastView: View {
  @Bindable var browser: BrowserModel

  var body: some View {
    if let toast = browser.toast {
      HStack(spacing: 12) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text(toast)
        if browser.canUndo {
          Button("Undo") { Task { await browser.undo() } }
            .buttonStyle(.borderless)
            .fontWeight(.semibold)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.regularMaterial, in: Capsule())
      .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
      .padding(.bottom, 44)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .task(id: toast) {
        try? await Task.sleep(for: .seconds(8))
        withAnimation { browser.toast = nil }
      }
    }
  }
}
