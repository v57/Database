import ComponentKit
import CodeHighlighting
import DatabaseKit
import SwiftUI
import UniformTypeIdentifiers

struct QueryEditorView: View {
  @Bindable var workspace: QueryWorkspace
  @Bindable var window: WindowModel
  @Environment(DatabaseModel.self) private var app
  @State private var saving = false
  @State private var savingTitle = ""
  @State private var exporting: ExportDocument?

  var body: some View {
    VStack(spacing: 0) {
      QueryTabStrip(workspace: workspace, window: window)
      if let tab = workspace.selected {
        QueryTabView(tab: tab, workspace: workspace, onExport: { exporting = $0 })
          .id(tab.id)
      } else {
        EmptyState(systemImage: "terminal", title: "No Query Open") {
          Button("New Query") { window.newQuery() }.buttonStyle(.kitPrimary)
        }
      }
    }
    .kitPane(.content)
    .modifier(QueryToolbar(workspace: workspace, onSave: save, onNew: { window.newQuery() }))
    .kitPrompt(
      "Save Query", isPresented: $saving, text: $savingTitle, message: "Saved queries show under Queries in the sidebar.",
      systemImage: "bookmark", confirm: "Save"
    ) { title in
      if let tab = workspace.selected { workspace.save(tab, title: title, in: app) }
    }
    .fileExporter(
      isPresented: .init(get: { exporting != nil }, set: { if !$0 { exporting = nil } }), document: exporting,
      contentType: exporting?.type ?? .commaSeparatedText, defaultFilename: exporting?.name
    ) { _ in exporting = nil }
    .task { await workspace.connection.connect() }
  }

  private func save(_ tab: QueryTab) {
    savingTitle = tab.savedID == nil ? "" : tab.title
    saving = true
  }

}

/// The query tabs over the editor. A view of its own, so a title or an edited dot changing (the first keystroke in a
/// saved query) redraws the strip, not the editor and results under it. On iPhone a single query shows no strip (a row
/// holding a lone + took the editor's room): New Query is in the toolbar there.
private struct QueryTabStrip: View {
  @Bindable var workspace: QueryWorkspace
  let window: WindowModel
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if idiom != .phone || workspace.tabs.count > 1 {
      KitTabStrip(
        tabs: workspace.tabs.map { KitTab(id: $0.id, title: $0.displayTitle, isEdited: $0.isDirty && $0.savedID != nil) },
        selection: $workspace.selectedID, onClose: { workspace.close($0) }, onAdd: { window.newQuery() })
    }
  }
}

/// The query pane's title bar and tools. A modifier of its own: the running tab's state and title read in the pane's
/// body rebuilt the editor and the results on every run.
private struct QueryToolbar: ViewModifier {
  let workspace: QueryWorkspace
  let onSave: (QueryTab) -> Void
  let onNew: () -> Void
  @Environment(\.kitIdiom) private var idiom

  func body(content: Content) -> some View {
    content.kitToolbar(
      workspace.selected.map(\.displayTitle) ?? "Query", meta: [workspace.connection.profile.displayName], systemImage: "bolt",
      hue: workspace.connection.profile.engine.hue, status: workspace.selected?.isRunning == true ? .working : .idle
    ) {
      tools
    }
  }

  /// Format and Explain fold into "…" first, then Save; Run never folds. On iPhone New Query is a tool too (the tab
  /// strip, and its +, shows only with two queries open there).
  @ToolbarSlotBuilder private var tools: [ToolbarSlot] {
    if idiom == .phone {
      ToolbarSlot(priority: 0) {
        ToolGroup(iconOnly: true) {
          Button("New Query", systemImage: "plus", action: onNew)
        }
      } menu: {
        Button("New Query", systemImage: "plus", action: onNew)
      }
    }
    if let tab = workspace.selected {
      let formats = workspace.connection.profile.engine.family == .sql || workspace.connection.profile.engine.family == .wideColumn
      ToolbarSlot(priority: 0) {
        ToolGroup {
          Chip(workspace.connection.profile.engine.queryLanguage, hue: workspace.connection.profile.engine.hue)
            .padding(.horizontal, 4)
          if formats {
            Button("Format") { tab.text = SQLFormatter.format(tab.text) }
          }
          Button("Explain") { Task { await workspace.explainSelected() } }
            .disabled(tab.isRunning)
        }
      } menu: {
        if formats {
          Button("Format", systemImage: "text.alignleft") { tab.text = SQLFormatter.format(tab.text) }
        }
        Button("Explain", systemImage: "list.bullet.indent") { Task { await workspace.explainSelected() } }
          .disabled(tab.isRunning)
          .kitMenuPreview("Shows how the database plans to run this query.")
      }
      ToolbarSlot(priority: 1) {
        // A bookmark, not a tray: the tray read as download or import.
        ToolGroup(iconOnly: true) {
          Button("Save…", systemImage: "bookmark") { onSave(tab) }
        }
      } menu: {
        Button("Save…", systemImage: "bookmark") { onSave(tab) }
          .kitMenuPreview("Keeps this query under a name in the sidebar.")
      }
      Button("Run", systemImage: "play.fill") {
        // On iPhone the keyboard would cover the results.
        if idiom == .phone { KitDevice.dismissKeyboard() }
        Task { await workspace.runSelected() }
      }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(tab.isRunning)
        .kitHelp("Run", shortcut: "⌘↩", systemImage: "play.fill")
    }
  }
}

/// One query tab: editor on top, results below. The two are views of their own: a keystroke updates the editor alone,
/// and a run the results alone (the text's binding, made in one body for both, rebuilt the results on every keystroke).
struct QueryTabView: View {
  let tab: QueryTab
  let workspace: QueryWorkspace
  let onExport: (ExportDocument) -> Void
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    #if os(macOS)
      ResizableSplit("queryEditorHeight", pane: .top, height: 240, range: 120...420, mainMinHeight: 200, showsLine: true) {
        QueryTabResults(tab: tab, workspace: workspace, onExport: onExport)
      } pane: {
        QueryTabEditor(tab: tab, workspace: workspace)
      }
    #else
      VStack(spacing: 0) {
        // On iPhone the results get the room: a query is a line or a few.
        QueryTabEditor(tab: tab, workspace: workspace).frame(minHeight: 120, maxHeight: idiom == .phone ? 200 : 300)
        QueryTabResults(tab: tab, workspace: workspace, onExport: onExport)
      }
    #endif
  }
}

/// A query tab's editor, with where it runs above it.
private struct QueryTabEditor: View {
  @Bindable var tab: QueryTab
  let workspace: QueryWorkspace

  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    VStack(spacing: 0) {
      ContextBar(tab: tab, workspace: workspace)
      editor
    }
    .kitPane(.content)
  }

  /// On iPhone and iPad the editor is a card, so it reads as the place to type (on the pane's own ground it was
  /// invisible); on the Mac it fills its split pane.
  @ViewBuilder private var editor: some View {
    let editor = CodeEditor(
      text: $tab.text, language: workspace.connection.profile.engine.highlighting, completions: workspace.completions,
      onRun: { Task { await workspace.runSelected() } })
    if idiom == .phone || idiom == .pad {
      editor
        .padding(.vertical, 4)
        .kitSurface(.card)
        .padding(.horizontal, KitMetrics.gutter)
        .padding(.vertical, 6)
    } else {
      editor
    }
  }
}

/// A query tab's results, messages or plan, with the run's status and Export.
private struct QueryTabResults: View {
  @Bindable var tab: QueryTab
  let workspace: QueryWorkspace
  let onExport: (ExportDocument) -> Void

  var body: some View {
    VStack(spacing: 0) {
      // The status beside the tabs where it fits; on iPhone it goes on a line of its own under them (it wrapped a
      // word a line between the tabs and Export).
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          KitSegmented(selection: $tab.output, options: QueryTab.Output.allCases.map { ($0.rawValue, $0) })
          status
          Spacer(minLength: 0)
          export
        }
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 10) {
            KitSegmented(selection: $tab.output, options: QueryTab.Output.allCases.map { ($0.rawValue, $0) })
            Spacer(minLength: 0)
            export
          }
          status
        }
      }
      .padding(.horizontal, KitMetrics.gutter)
      .padding(.vertical, 6)
      output
    }
  }

  @ViewBuilder private var status: some View {
    if tab.isRunning {
      HStack(spacing: 6) {
        LiveIcon(systemImage: "play.fill", status: .working, size: 18)
        Text("Running…").kitFont(.caption)
      }
      .fixedSize()
    } else if let elapsed = tab.lastElapsed {
      Text(statusText + " · " + formatDuration(elapsed)).kitFont(.caption).lineLimit(1).fixedSize()
    }
  }

  @ViewBuilder private var export: some View {
    if let table = currentTable {
      KitMenuButton("Export", systemImage: "square.and.arrow.up") {
        Button("CSV…") { onExport(ExportDocument(text: Export.csv(fields: table.0, rows: table.1), type: .commaSeparatedText, name: tab.title + ".csv")) }
          .kitMenuPreview("Saves the results as \(tab.title).csv. You pick where.")
        Button("JSON…") { onExport(ExportDocument(text: Export.json(fields: table.0, rows: table.1), type: .json, name: tab.title + ".json")) }
        Divider()
        Button("Copy as CSV", systemImage: "doc.on.doc") { KitPasteboard.copy(Export.csv(fields: table.0, rows: table.1)) }
      }
      .controlSize(.small)
    }
  }

  @ViewBuilder private var output: some View {
    switch tab.output {
    case .results:
      if tab.resultOutputs.isEmpty {
        EmptyState(systemImage: tab.error == nil ? "play" : "exclamationmark.triangle", title: tab.error.map { "\($0)" } ?? "Run a query to see results")
      } else {
        QueryResultsView(outputs: tab.resultOutputs, connection: workspace.connection)
      }
    case .messages:
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(tab.messages.enumerated()), id: \.offset) { _, line in
            Text(line).kitFont(.mono).textSelection(.enabled)
              .foregroundStyle(line == tab.error ? AnyShapeStyle(Hue.red.text) : AnyShapeStyle(.kitLabel))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
    case .plan:
      if let plan = tab.plan {
        ScrollView([.vertical, .horizontal]) {
          Text(plan)
            .kitFont(.mono)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
      } else {
        // Explain is in the toolbar's "…" on iPhone, so the empty plan offers it.
        EmptyState(systemImage: "list.bullet.indent", title: "No Plan", message: "See how the database plans to run this query.") {
          Button("Explain") { Task { await workspace.explainSelected() } }
            .buttonStyle(.kit)
            .disabled(tab.isRunning)
        }
      }
    }
  }

  private var statusText: String {
    if tab.error != nil { return String(localized: "Failed") }
    let rows = tab.resultOutputs.compactMap { output -> Int? in
      switch output {
      case .table(_, let rows, _): rows.count
      case .documents(let docs, _): docs.count
      default: nil
      }
    }
    if let last = rows.last { return String(localized: "\(last) rows") }
    return String(localized: "Done")
  }

  private var currentTable: ([FieldInfo], [[CellValue]])? {
    for output in tab.resultOutputs.reversed() {
      if case .table(let fields, let rows, _) = output { return (fields, rows) }
    }
    return nil
  }
}

/// Where the query runs.
struct ContextBar: View {
  @Bindable var tab: QueryTab
  let workspace: QueryWorkspace

  private var databases: [TreeNode] {
    workspace.connection.children[LiveConnection.rootID]?.filter { [.database, .keyspace, .redisDatabase].contains($0.kind) } ?? []
  }

  /// Where it runs, when there's a choice or one was made: a SQLite file has one database, so "Runs in the default
  /// database" said nothing there.
  private var showsWhere: Bool {
    !databases.isEmpty || tab.context.database != nil || tab.context.schema != nil
  }

  @ViewBuilder var body: some View {
    if showsWhere || KitDevice.hasKeyboard { bar }
  }

  private var bar: some View {
    HStack(spacing: 8) {
      if !databases.isEmpty {
        KitMenuButton("Runs in \(tab.context.database ?? "the default database")", systemImage: "cylinder") {
          KitMenuOptions(
            selection: Binding(
              get: { tab.context.database ?? "" },
              set: { name in
                tab.context.database = name.isEmpty ? nil : name
                tab.context.schema = nil
                Task { await workspace.loadCompletions(for: tab.context) }
              }),
            options: [("Default", "")] + databases.map { ($0.title, $0.database ?? $0.title) })
        }
        .controlSize(.small)
      } else if showsWhere {
        Text(tab.context.database.map { "Runs in \($0)" } ?? "Runs in the default database")
      }
      if let schema = tab.context.schema {
        Text("› \(schema)")
      }
      Spacer()
      KeyHints([("⌘↩", "runs"), ("Tab", "completes")])
    }
    .kitFont(.caption)
    .padding(.horizontal, KitMetrics.gutter)
    .padding(.vertical, 6)
  }
}

/// A file to save from the exporter.
struct ExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.commaSeparatedText, .json, .plainText] }
  var text: String
  var type: UTType
  var name: String

  init(text: String, type: UTType, name: String) {
    self.text = text
    self.type = type
    self.name = name
  }

  init(configuration: ReadConfiguration) throws {
    text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    type = .plainText
    name = "Export"
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

/// A light SQL tidy-up: keywords upper-case, main clauses on their own lines.
enum SQLFormatter {
  static let clauses = [
    "SELECT", "FROM", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "OFFSET", "LEFT JOIN", "RIGHT JOIN",
    "INNER JOIN", "JOIN", "UNION ALL", "UNION", "VALUES", "SET", "RETURNING",
  ]

  /// SQL's keywords (from CodeHighlighting) and its aggregate functions, upper-cased.
  static let keywords = (CodeHighlighter.spec(forLanguage: "sql")?.keywords ?? []).union([
    "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE",
  ])

  static func format(_ sql: String) -> String {
    var text = sql
    // Upper-case keywords outside quotes.
    var out = ""
    var word = ""
    var quote: Character?
    func flush() {
      if keywords.contains(word.uppercased()) { out += word.uppercased() } else { out += word }
      word = ""
    }
    for ch in text {
      if let q = quote {
        out.append(ch)
        if ch == q { quote = nil }
        continue
      }
      if ch == "'" || ch == "\"" || ch == "`" {
        flush()
        quote = ch
        out.append(ch)
      } else if ch.isLetter || ch.isNumber || ch == "_" {
        word.append(ch)
      } else {
        flush()
        out.append(ch)
      }
    }
    flush()
    text = out
    for clause in clauses {
      text = text.replacingOccurrences(
        of: "\\s+\(clause.replacingOccurrences(of: " ", with: "\\s+"))\\b", with: "\n\(clause)", options: .regularExpression)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
