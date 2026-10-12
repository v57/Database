import DatabaseCore
import Foundation
import Observation
import SwiftUI

/// State of one open table, collection or Redis database.
@Observable @MainActor
final class BrowserModel {
  enum ViewMode: String, CaseIterable, Identifiable {
    case table = "Table"
    case cards = "Cards"
    case json = "JSON"
    var id: String { rawValue }
  }

  enum Mode: String, CaseIterable, Identifiable {
    case find = "Find"
    case aggregate = "Aggregate"
    var id: String { rawValue }
  }

  let connection: LiveConnection
  let ref: ObjectRef
  var request: BrowseRequest
  private(set) var page: BrowsePage?
  private(set) var isLoading = false
  var errorMessage: String?
  private(set) var exactTotal: Int?

  var selection: Set<String> = []
  var viewMode: ViewMode
  private(set) var mode: Mode = .find
  /// True for a moment while switching to Aggregate; see `switchMode`.
  private(set) var collapsesInspector = false
  var showsQueryEditor = false
  /// The query as shown in the Query Editor strip; edits make it "custom".
  var queryText = ""
  private(set) var queryIsCustom = false
  private(set) var customRuns: [QueryRun]?

  /// Changes waiting for review.
  var pending: [RecordEdit] = []
  /// The last saved batch, for Undo.
  private(set) var lastSaved: (undo: [RecordEdit], summary: String)?
  var toast: String?
  var showsReview = false
  /// Set by a double-click: the inspector opens this item for editing.
  var editRequest: String?

  /// Pipeline state for Aggregate mode.
  @ObservationIgnored lazy var pipeline = PipelineModel(browser: self)


  /// Aggregate has no record inspector. The inspector closes first, without animation, and the builder replaces the
  /// list on the next update: with both on screen at once, macOS widens the window to fit them and it stays wide.
  func switchMode(_ newMode: Mode) async {
    guard newMode != mode else { return }
    if newMode == .aggregate {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { collapsesInspector = true }
      try? await Task.sleep(for: .milliseconds(30))
    }
    mode = newMode
    collapsesInspector = false
  }

  init(connection: LiveConnection, ref: ObjectRef) {
    self.connection = connection
    self.ref = ref
    var request = BrowseRequest(ref: ref, limit: 50)
    if connection.profile.engine == .redis { request.limit = 100 }
    self.request = request
    viewMode = connection.profile.engine == .mongodb ? .cards : .table
  }

  var engine: EngineKind { connection.profile.engine }
  var session: DatabaseSession? { connection.session }
  var fields: [FieldInfo] { page?.fields ?? [] }
  var records: [Record] { page?.records ?? [] }
  var noun: Noun { engine.itemNoun }
  var isEditable: Bool { ref.isWritable && !connection.profile.isReadOnly }

  var visibleFields: [FieldInfo] { fields.filter { !request.hiddenFields.contains($0.name) } }

  var selectedRecords: [Record] { records.filter { selection.contains($0.id) } }
  var selectedRecord: Record? { selection.count == 1 ? selectedRecords.first : nil }

  // MARK: Loading

  func load() async {
    guard let session else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let page = try await session.browse(request)
      self.page = page
      errorMessage = nil
      if !queryIsCustom { queryText = page.query }
      // Keep the selection on items that are still there.
      selection = selection.filter { id in page.records.contains { $0.id == id } }
      if selection.isEmpty, let first = page.records.first, Platform.isMac { selection = [first.id] }
      exactTotal = page.totalIsEstimate ? nil : page.total
      if page.total == nil && !request.activeFilters.isEmpty || !request.search.isEmpty && page.total == nil {
        Task { await countExactly() }
      }
    } catch {
      errorMessage = FriendlyError.message(error)
    }
  }

  func countExactly() async {
    guard let session else { return }
    exactTotal = try? await session.count(request)
  }

  /// Reloads from the first page (after a filter, sort or search change).
  func reload() async {
    request.offset = 0
    customRuns = nil
    queryIsCustom = false
    await load()
  }

  func nextPage() async {
    guard page?.hasMore == true else { return }
    request.offset += request.limit
    await load()
  }

  func previousPage() async {
    guard request.offset > 0 else { return }
    request.offset = max(0, request.offset - request.limit)
    await load()
  }

  var pageLabel: String {
    guard let page else { return "" }
    if page.records.isEmpty { return "No \(noun.plural)" }
    let first = request.offset + 1
    let last = request.offset + page.records.count
    var text = "\(first.formatted())–\(last.formatted())"
    if let total = exactTotal ?? page.total {
      text += " of \(page.totalIsEstimate && exactTotal == nil ? "about " : "")\(total.formatted())"
    }
    return text
  }

  // MARK: Filters, sort, fields

  func setSort(_ field: String) async {
    if let first = request.sort.first, first.field == field {
      request.sort = first.ascending ? [SortKey(field: field, ascending: false)] : []
    } else {
      request.sort = [SortKey(field: field, ascending: true)]
    }
    await reload()
  }

  func addFilter(_ filter: Filter) async {
    request.filters.append(filter)
    await reload()
  }

  func removeFilter(_ id: UUID) async {
    request.filters.removeAll { $0.id == id }
    await reload()
  }

  func toggleField(_ name: String) async {
    if request.hiddenFields.contains(name) {
      request.hiddenFields.remove(name)
    } else {
      request.hiddenFields.insert(name)
    }
    await reload()
  }

  func showAllFields() async {
    request.hiddenFields = []
    await reload()
  }

  func category(of field: String) -> ValueCategory {
    fields.first { $0.name == field }?.category ?? .text
  }

  // MARK: Query Editor strip

  func editQuery(_ text: String) {
    queryText = text
    queryIsCustom = text != page?.query
  }

  func resetQuery() {
    queryText = page?.query ?? ""
    queryIsCustom = false
    customRuns = nil
  }

  /// Runs the (possibly edited) query; results replace the list until reset.
  func runQuery() async {
    guard let session else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      customRuns = try await session.run(queryText, context: queryContext)
      errorMessage = nil
      queryIsCustom = true
    } catch {
      errorMessage = FriendlyError.message(error)
    }
  }

  var queryContext: QueryContext {
    QueryContext(
      database: ref.database, schema: ref.schema, collection: ref.kind == .collection ? ref.name : nil)
  }

  // MARK: Changes

  /// Adds an edit to the review queue, merging with an earlier edit of the same item.
  func stage(_ edit: RecordEdit) {
    if case .update(let changes) = edit.kind,
      let index = pending.firstIndex(where: { $0.key == edit.key && $0.ref == edit.ref }),
      case .update(var existing) = pending[index].kind
    {
      for change in changes {
        if let i = existing.firstIndex(where: { $0.field == change.field }) {
          existing[i].new = change.new
          if existing[i].new == existing[i].old { existing.remove(at: i) }
        } else {
          existing.append(change)
        }
      }
      if existing.isEmpty {
        pending.remove(at: index)
      } else {
        pending[index].kind = .update(existing)
      }
      return
    }
    if case .update(let changes) = edit.kind, changes.isEmpty { return }
    pending.append(edit)
  }

  func revert(_ id: UUID) {
    pending.removeAll { $0.id == id }
  }

  func discardChanges() { pending.removeAll() }

  /// The pending value for a field, if it was edited.
  func pendingValue(for record: Record, field: String) -> CellValue? {
    for edit in pending where edit.key == record.key && edit.ref == ref {
      if case .update(let changes) = edit.kind, let change = changes.first(where: { $0.field == field }) {
        return change.new
      }
    }
    return nil
  }

  func isPendingDelete(_ record: Record) -> Bool {
    pending.contains { edit in
      if case .delete = edit.kind { return edit.key == record.key && edit.ref == ref }
      return false
    }
  }

  func stageDelete(_ records: [Record]) {
    for record in records where record.key != nil && !isPendingDelete(record) {
      pending.removeAll { $0.key == record.key && $0.ref == ref }
      pending.append(RecordEdit(ref: ref, key: record.key, kind: .delete(record), title: title(for: record)))
    }
  }

  func statements() -> [String] {
    (try? session?.statements(for: pending)) ?? []
  }

  func save() async -> Bool {
    guard let session, !pending.isEmpty else { return false }
    do {
      let edits = pending
      let outcome = try await session.apply(edits)
      let count = edits.count
      pending.removeAll()
      lastSaved = (outcome.undo, "\(count) change\(count == 1 ? "" : "s")")
      toast = "Saved \(count) change\(count == 1 ? "" : "s") to \(ref.name)"
      await load()
      return true
    } catch {
      errorMessage = FriendlyError.message(error)
      return false
    }
  }

  var canUndo: Bool { lastSaved?.undo.isEmpty == false }

  func undo() async {
    guard let session, let saved = lastSaved, !saved.undo.isEmpty else { return }
    do {
      _ = try await session.apply(saved.undo)
      lastSaved = nil
      toast = "Undid \(saved.summary)"
      await load()
    } catch {
      errorMessage = "Couldn't undo: \(FriendlyError.message(error))"
    }
  }

  // MARK: Titles

  /// "Order 10476 · Elena Petrova": the key plus the first readable text field.
  func title(for record: Record) -> String {
    let singular = ref.name.hasSuffix("s") ? String(ref.name.dropLast()) : ref.name
    let label = singular.prefix(1).uppercased() + singular.dropFirst()
    var text = label
    if let key = record.key { text += " " + key.summary }
    if let name = displayName(for: record) { text += " · " + name }
    return text
  }

  func displayName(for record: Record) -> String? {
    let preferred = ["name", "title", "customer", "email", "username", "label", "subject"]
    for name in preferred {
      if let value = record[name], !value.isNull, case let text = value.displayText, !text.isEmpty { return text }
    }
    for field in fields
    where field.category == .text && !field.isPrimaryKey && !field.name.contains("status") && !field.name.contains("state") {
      if let value = record[field.name], !value.isNull {
        let text = value.displayText
        if !text.isEmpty && text.count < 60 { return text }
      }
    }
    return nil
  }
}

enum Platform {
  #if os(macOS)
    static let isMac = true
  #else
    static let isMac = false
  #endif
}
