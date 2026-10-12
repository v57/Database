import DatabaseProKit
import Foundation
import Observation

/// One open query: its text, where it runs, and its last results.
@Observable @MainActor
final class QueryTab: Identifiable {
  enum Output: String, CaseIterable, Identifiable {
    case results = "Results"
    case messages = "Messages"
    case plan = "Plan"
    var id: String { rawValue }
  }

  let id = UUID()
  var title: String
  var text: String {
    didSet { if text != oldValue { isDirty = true } }
  }
  var context: QueryContext
  var savedID: UUID?
  private(set) var isDirty = false
  var runs: [QueryRun] = []
  var plan: String?
  var error: String?
  var isRunning = false
  var output: Output = .results
  var lastElapsed: TimeInterval?
  /// Which result set is shown when a run produced several.
  var resultIndex = 0

  init(title: String, text: String, context: QueryContext, savedID: UUID? = nil) {
    self.title = title
    self.text = text
    self.context = context
    self.savedID = savedID
  }

  func markSaved() { isDirty = false }

  var messages: [String] {
    var lines: [String] = []
    for run in runs {
      for output in run.outputs {
        switch output {
        case .message(let text): lines.append(text)
        case .table(_, let rows, _): lines.append("\(rows.count) row\(rows.count == 1 ? "" : "s")")
        case .documents(let docs, _): lines.append("\(docs.count) document\(docs.count == 1 ? "" : "s")")
        case .text: break
        }
      }
    }
    if let error { lines.append(error) }
    return lines
  }

  /// Result sets worth showing in the Results tab.
  var resultOutputs: [QueryOutput] {
    runs.flatMap(\.outputs).filter {
      switch $0 {
      case .message: false
      default: true
      }
    }
  }
}

/// The open query tabs of one connection.
@Observable @MainActor
final class QueryWorkspace {
  @ObservationIgnored unowned let connection: LiveConnection
  private(set) var tabs: [QueryTab] = []
  var selectedID: UUID?
  private(set) var completions: [Completion] = []

  init(connection: LiveConnection) { self.connection = connection }

  var selected: QueryTab? { tabs.first { $0.id == selectedID } ?? tabs.first }

  @discardableResult
  func newTab(context: QueryContext, text: String? = nil) -> QueryTab {
    let number = tabs.count + 1
    let tab = QueryTab(title: number == 1 ? "Untitled" : "Untitled \(number)", text: text ?? starter(context), context: context)
    tabs.append(tab)
    selectedID = tab.id
    Task { await loadCompletions(for: context) }
    return tab
  }

  /// A first line that runs as-is in the engine's language.
  func starter(_ context: QueryContext) -> String {
    switch connection.profile.engine {
    case .mongodb: return "db.\(context.collection ?? "collection").find({}).limit(20)"
    case .redis: return "INFO keyspace"
    case .cassandra, .scylla: return "SELECT * FROM system.local;"
    default: return ""
    }
  }

  func open(_ saved: SavedQuery) {
    if let existing = tabs.first(where: { $0.savedID == saved.id }) {
      selectedID = existing.id
      return
    }
    let tab = QueryTab(
      title: saved.title, text: saved.text, context: QueryContext(database: saved.database, schema: saved.schema),
      savedID: saved.id)
    tab.markSaved()
    tabs.append(tab)
    selectedID = tab.id
    Task { await loadCompletions(for: tab.context) }
  }

  func close(_ id: UUID) {
    tabs.removeAll { $0.id == id }
    if selectedID == id { selectedID = tabs.last?.id }
  }

  func loadCompletions(for context: QueryContext) async {
    guard let session = connection.session else { return }
    completions = await session.completions(context: context)
  }

  func runSelected(text override: String? = nil) async {
    guard let tab = selected else { return }
    await connection.connect()
    guard let session = connection.session else {
      tab.error = "Not connected."
      return
    }
    let text = override ?? tab.text
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    tab.isRunning = true
    defer { tab.isRunning = false }
    let start = Date()
    do {
      tab.runs = try await session.run(text, context: tab.context)
      tab.error = nil
      tab.resultIndex = max(0, tab.resultOutputs.count - 1)
      tab.output = tab.resultOutputs.isEmpty ? .messages : .results
    } catch {
      tab.runs = []
      tab.error = FriendlyError.message(error)
      tab.output = .messages
    }
    tab.lastElapsed = Date().timeIntervalSince(start)
  }

  func explainSelected() async {
    guard let tab = selected, let session = connection.session else { return }
    tab.isRunning = true
    defer { tab.isRunning = false }
    do {
      tab.plan = try await session.explain(tab.text, context: tab.context)
      tab.error = nil
    } catch {
      tab.plan = nil
      tab.error = FriendlyError.message(error)
    }
    tab.output = .plan
  }

  func save(_ tab: QueryTab, title: String, in app: AppModel) {
    tab.title = title
    let saved = SavedQuery(
      id: tab.savedID ?? UUID(), profileID: connection.id, title: title, text: tab.text, database: tab.context.database,
      schema: tab.context.schema)
    tab.savedID = saved.id
    app.saveQuery(saved)
    tab.markSaved()
  }
}
