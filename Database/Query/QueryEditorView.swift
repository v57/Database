import ComponentKit
import CodeHighlighting
import DatabaseKit
import SwiftUI
import UniformTypeIdentifiers

struct QueryEditorView: View {
  @Bindable var workspace: QueryWorkspace
  @Bindable var window: WindowModel
  @Environment(AppModel.self) private var app
  @State private var savingTitle: String?
  @State private var exporting: ExportDocument?

  var body: some View {
    VStack(spacing: 0) {
      tabBar
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
    .navigationMeta(workspace.connection.profile.displayName)
    #if os(macOS)
      .kitToolbarTitle(
        workspace.selected?.title ?? "Query", meta: [workspace.connection.profile.displayName], systemImage: "bolt",
        hue: workspace.connection.profile.engine.hue, status: workspace.selected?.isRunning == true ? .working : .idle)
    #else
      .navigationTitle(workspace.selected?.title ?? "Query")
    #endif
    .toolbar { toolbar }
    .sheet(isPresented: .init(get: { savingTitle != nil }, set: { if !$0 { savingTitle = nil } })) {
      KitSheet(title: "Save Query", meta: "Saved queries show under Queries in the sidebar.", systemImage: "square.and.arrow.down", width: 420) {
        TextField("Name", text: Binding(get: { savingTitle ?? "" }, set: { savingTitle = $0 }))
          .kitField()
      } footer: {
        Button("Cancel") { savingTitle = nil }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          if let tab = workspace.selected, let title = savingTitle, !title.isEmpty { workspace.save(tab, title: title, in: app) }
          savingTitle = nil
        }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(savingTitle?.isEmpty != false)
      }
      .componentKit(accent: .databaseAccent)
    }
    .fileExporter(
      isPresented: .init(get: { exporting != nil }, set: { if !$0 { exporting = nil } }), document: exporting,
      contentType: exporting?.type ?? .commaSeparatedText, defaultFilename: exporting?.name
    ) { _ in exporting = nil }
    .task { await workspace.connection.connect() }
  }

  private var tabBar: some View {
    KitTabStrip(
      tabs: workspace.tabs.map { KitTab(id: $0.id, title: $0.title, isEdited: $0.isDirty && $0.savedID != nil) },
      selection: $workspace.selectedID, onClose: { workspace.close($0) }, onAdd: { window.newQuery() })
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    #if os(macOS)
      if #available(macOS 26, *) {
        ToolbarSpacer(.flexible)
      }
    #endif
    ToolbarItemGroup(placement: .primaryAction) {
      if let tab = workspace.selected {
        ToolGroup {
          Chip(workspace.connection.profile.engine.queryLanguage, hue: workspace.connection.profile.engine.hue)
            .padding(.horizontal, 4)
          if workspace.connection.profile.engine.family == .sql || workspace.connection.profile.engine.family == .wideColumn {
            Button("Format") { tab.text = SQLFormatter.format(tab.text) }
          }
          Button("Explain") { Task { await workspace.explainSelected() } }
            .disabled(tab.isRunning)
        }
        ToolGroup(iconOnly: true) {
          Button("Save…", systemImage: "square.and.arrow.down") { savingTitle = tab.savedID == nil ? "" : tab.title }
        }
        Button("Run", systemImage: "play.fill") { Task { await workspace.runSelected() } }
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(tab.isRunning)
          .kitHelp("Run", shortcut: "⌘↩", systemImage: "play.fill")
      }
    }
    .kitToolbarItem()
  }
}

/// One query tab: editor on top, results below.
struct QueryTabView: View {
  @Bindable var tab: QueryTab
  let workspace: QueryWorkspace
  let onExport: (ExportDocument) -> Void

  var body: some View {
    #if os(macOS)
      VSplitView {
        editor.frame(minHeight: 120, idealHeight: 240, maxHeight: 420)
        results.frame(minHeight: 200).layoutPriority(1)
      }
    #else
      VStack(spacing: 0) {
        editor.frame(minHeight: 160, maxHeight: 300)
        results
      }
    #endif
  }

  private var editor: some View {
    VStack(spacing: 0) {
      ContextBar(tab: tab, workspace: workspace)
      CodeEditor(
        text: $tab.text, language: workspace.connection.profile.engine.highlighting, completions: workspace.completions,
        onRun: { Task { await workspace.runSelected() } })
    }
    .kitPane(.content)
  }

  private var results: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        KitSegmented(selection: $tab.output, options: QueryTab.Output.allCases.map { ($0.rawValue, $0) })
        if tab.isRunning {
          LiveIcon(systemImage: "play.fill", status: .working, size: 18)
          Text("Running…").kitFont(.caption)
        } else if let elapsed = tab.lastElapsed {
          Text(statusText + " · " + formatDuration(elapsed)).kitFont(.caption)
        }
        Spacer()
        if let table = currentTable {
          Menu {
            Button("CSV…") { onExport(ExportDocument(text: Export.csv(fields: table.0, rows: table.1), type: .commaSeparatedText, name: tab.title + ".csv")) }
            Button("JSON…") { onExport(ExportDocument(text: Export.json(fields: table.0, rows: table.1), type: .json, name: tab.title + ".json")) }
            Button("Copy as CSV") { KitPasteboard.copy(Export.csv(fields: table.0, rows: table.1)) }
          } label: {
            Label("Export", systemImage: "square.and.arrow.up")
          }
          .menuStyle(.button)
          .buttonStyle(.kit)
          .menuIndicator(.hidden)
          .controlSize(.small)
          .fixedSize()
        }
      }
      .padding(.horizontal, KitMetrics.gutter)
      .padding(.vertical, 6)
      switch tab.output {
      case .results:
        if tab.resultOutputs.isEmpty {
          EmptyState(systemImage: tab.error == nil ? "play" : "exclamationmark.triangle", title: tab.error ?? "Run a query to see results")
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
        ScrollView([.vertical, .horizontal]) {
          Text(tab.plan ?? "Press Explain to see how the server will run this query.")
            .kitFont(.mono)
            .textSelection(.enabled)
            .foregroundStyle(tab.plan == nil ? AnyShapeStyle(.kitSecondary) : AnyShapeStyle(.kitLabel))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
      }
    }
  }

  private var statusText: String {
    if tab.error != nil { return "Failed" }
    let rows = tab.resultOutputs.compactMap { output -> Int? in
      switch output {
      case .table(_, let rows, _): rows.count
      case .documents(let docs, _): docs.count
      default: nil
      }
    }
    if let last = rows.last { return "\(last) row\(last == 1 ? "" : "s")" }
    return "Done"
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

  var body: some View {
    HStack(spacing: 8) {
      if !databases.isEmpty {
        Picker("Run in", selection: Binding(
          get: { tab.context.database ?? "" },
          set: { name in
            tab.context.database = name.isEmpty ? nil : name
            tab.context.schema = nil
            Task { await workspace.loadCompletions(for: tab.context) }
          })
        ) {
          Text("Default").tag("")
          ForEach(databases) { Text($0.title).tag($0.database ?? $0.title) }
        }
        .fixedSize()
      } else {
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
