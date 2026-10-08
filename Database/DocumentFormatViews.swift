import Foundation
import MongoDB
import SwiftUI

/// What one column/key UI gesture asks the pane to do. Every case is answered by
/// rewriting query text in DocumentsView (see `handle`) — the table itself owns
/// nothing, so arrows and hidden columns are always derived from the text.
enum ColumnAction: Equatable {
  case cycleSort(String)
  case setSort(String, SortText.Direction)
  case disableSort(String)
  case hide(String)
  case show(String)
  case showAllFields
  /// Add a ready-made filter chip; when its value is still blank (`contains…`,
  /// `Search…`) the owner opens the chip editor instead.
  case filter(String, FilterRule)
  /// Open the "Search…" fragment box for a field (`{ $gt: 15 }`, `15`).
  case search(String)
}

/// How the document list is displayed in the main pane. `list` is the
/// historical default (key/value sections with expand/collapse + editing);
/// `table` renders rows as a spreadsheet grid (union of keys as columns);
/// `json` shows each document as pretty-printed JSON text.
enum DisplayFormat: String, CaseIterable, Identifiable {
  case list
  case table
  case json

  var id: String { rawValue }

  var name: String {
    switch self {
    case .list: "List"
    case .table: "Table"
    case .json: "JSON"
    }
  }

  /// Segmented-picker symbol (house rule: segmented pickers carry SF Symbols).
  var symbol: String {
    switch self {
    case .list: "list.bullet"
    case .table: "tablecells"
    case .json: "curlybraces"
    }
  }
}

// MARK: - Table mode

/// Documents as a spreadsheet: one column per key (ordered by first
/// appearance across the loaded rows), one row per document. Two-axis
/// scrolling with a pinned header row; cells truncate to one line.
struct TableDocumentsView: View {
  /// Every data column shares this width in the header and every row. Sizing
  /// cells to their content let long values push their row's columns right, so
  /// rows drifted apart and away from the header; long text truncates instead
  /// and the full value is in the cell's tooltip.
  static let columnWidth: CGFloat = 200
  /// The leading `#` row-number column.
  static let indexWidth: CGFloat = 44

  let documents: [BSONDocument]
  /// Fields/kinds/sample values of the loaded rows (drives the header menus).
  let fields: [FieldInfo]
  /// Arrow per column, DERIVED from the Sort text by the owner (not stored here).
  let sortDirections: [String: SortText.Direction]
  /// Hidden columns, DERIVED from the Projection text by the owner.
  let hiddenFields: Set<String>
  /// Every column gesture funnels through this one callback.
  let onColumnAction: (ColumnAction) -> Void

  /// Snapshot (index, document) pairs so rows never re-index a live array.
  private var rows: [TableRow] {
    documents.enumerated().map { TableRow(id: $0.offset, document: $0.element) }
  }

  /// Column keys in first-seen order across the loaded documents, minus the
  /// fields the Projection text hides: a hidden column disappears immediately
  /// and stays gone while the text says so, independent of the re-query.
  private var columns: [String] {
    var seen: [String] = []
    for doc in documents {
      for key in doc.keys where !seen.contains(key) && !hiddenFields.contains(key) {
        seen.append(key)
      }
    }
    return seen
  }

  var body: some View {
    let cols = columns.enumerated().map { Column(id: $0.offset, name: $0.element) }
    ScrollView([.horizontal, .vertical]) {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        Section {
          ForEach(rows) { row in
            rowView(row, columns: cols)
          }
          LoadMoreFooter()
        } header: {
          headerView(cols)
        }
      }
    }
  }

  private func headerView(_ cols: [Column]) -> some View {
    HStack(spacing: 0) {
      Text("#").font(.caption).bold().frame(width: Self.indexWidth, alignment: .center)
      ForEach(cols) { column in
        columnDivider
        HStack(spacing: 2) {
          // The whole title is one click target: clicking cycles this column's
          // sort. The chevron menu keeps the other gestures (search/hide/…).
          Button {
            onColumnAction(.cycleSort(column.name))
          } label: {
            HStack(spacing: 3) {
              Text(column.name).font(.caption).bold().lineLimit(1).truncationMode(.tail)
              sortArrow(column.name)
            }
          }.buttonStyle(.plain).help("Sort by \(column.name) — click to cycle asc/desc/off")
          columnMenu(column.name)
        }.padding(.horizontal, 6).frame(width: Self.columnWidth, alignment: .leading)
      }
    }
    .padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  /// Arrow for a column: derived from the Sort text parsed by the owner, so a
  /// hand-typed `{ age: -1 }` shows here with no extra state.
  @ViewBuilder private func sortArrow(_ name: String) -> some View {
    switch sortDirections[name] {
    case .some(.ascending): Image(systemName: "arrow.up").font(.caption2).foregroundStyle(.blue)
    case .some(.descending): Image(systemName: "arrow.down").font(.caption2).foregroundStyle(.blue)
    case .none: EmptyView()
    }
  }

  /// Per-column menu. Every item reports a ColumnAction; DocumentsView turns it
  /// into Sort/Project/Filter text. Values come from the loaded rows (page-local).
  private func columnMenu(_ name: String) -> some View {
    let info = fields.first { $0.name == name }
    let direction = sortDirections[name]
    return Menu {
      Button("Sort Ascending", systemImage: "arrow.up") {
        onColumnAction(.setSort(name, .ascending))
      }.disabled(direction == .ascending)
      Button("Sort Descending", systemImage: "arrow.down") {
        onColumnAction(.setSort(name, .descending))
      }.disabled(direction == .descending)
      Button("Disable Sorting", systemImage: "xmark.circle") {
        onColumnAction(.disableSort(name))
      }.disabled(direction == nil)
      Divider()
      Button("Search…", systemImage: "magnifyingglass") { onColumnAction(.search(name)) }
      if let info, !info.values.isEmpty {
        Menu("Filter: is") {
          ForEach(Array(info.values.prefix(20).enumerated()), id: \.offset) { _, value in
            Button(FilterText.display(value)) {
              onColumnAction(.filter(name, FilterRule(field: name, op: .equal, value: value)))
            }
          }
        }
      }
      Button("Filter: contains…") {
        onColumnAction(.filter(name, FilterRule(field: name, op: .contains, value: .string(""))))
      }
      Button("Filter: is empty") {
        onColumnAction(.filter(name, FilterRule(field: name, op: .isEmpty)))
      }
      Button("Filter: is not empty") {
        onColumnAction(.filter(name, FilterRule(field: name, op: .isNotEmpty)))
      }
      Divider()
      if hiddenFields.contains(name) {
        Button("Show", systemImage: "eye") { onColumnAction(.show(name)) }
      } else {
        Button("Hide", systemImage: "eye.slash") { onColumnAction(.hide(name)) }
      }
      Button("Show All Fields", systemImage: "eye") { onColumnAction(.showAllFields) }
    } label: {
      Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help("Sort, search, filter or hide \(name)")
  }

  private func rowView(_ row: TableRow, columns cols: [Column]) -> some View {
    let doc = row.document
    var displays: [DisplayCell] = []
    for column in cols {
      if let value = doc[column.name] {
        displays.append(DisplayCell(text: JSONText.compact(value), isString: value.isString))
      } else {
        displays.append(DisplayCell(text: "—", isString: nil))
      }
    }
    return HStack(spacing: 0) {
      Text("\(row.id + 1)").font(.caption.monospacedDigit())
        .foregroundStyle(.secondary).frame(width: Self.indexWidth, alignment: .center)
      ForEach(cols) { column in
        columnDivider
        cellView(displays[column.id])
      }
    }
    .padding(.vertical, 3)
    .background(row.id.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
  }

  /// One table cell (text + how to color it). `isString` nil = key missing.
  private struct DisplayCell {
    let text: String
    let isString: Bool?
  }

  @ViewBuilder
  private func cellView(_ cell: DisplayCell) -> some View {
    if let isString = cell.isString {
      Text(cell.text).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
        .foregroundStyle(isString ? Color.primary : Color.blue)
        .padding(.horizontal, 6).frame(width: Self.columnWidth, alignment: .leading)
        .help(cell.text)
    } else {
      Text(cell.text).foregroundStyle(.secondary)
        .padding(.horizontal, 6).frame(width: Self.columnWidth, alignment: .leading)
        .help("Field not present in this document")
    }
  }

  private var columnDivider: some View {
    Rectangle().fill(.quaternary).frame(width: 1).frame(maxHeight: .infinity)
  }
}

// MARK: - Load more

/// Bottom-of-list sentinel shared by the document formats. It renders only
/// while the model has another page to fetch (Redis has no paging here), and
/// its `.onAppear` — the user scrolled to the end — loads that page; a
/// spinner shows while the fetch runs.
struct LoadMoreFooter: View {
  @Environment(DatabaseModel.self) private var model

  var body: some View {
    if model.hasMore && model.activeEngine != .redis {
      HStack(spacing: 8) {
        if model.isLoadingMore {
          ProgressView().controlSize(.small)
          Text("Loading…").font(.caption).foregroundStyle(.secondary)
        } else {
          Text("Scroll to load more").font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity).padding(.vertical, 8)
      .onAppear { Task { await model.loadMoreDocuments() } }
    }
  }
}

/// One table row: (index, document) snapshotted per body evaluation.
private struct TableRow: Identifiable {
  let id: Int
  let document: BSONDocument
}

/// One grid column: (index, name) snapshot — Identifiable so ForEach never
/// needs an id keypath (the 2026 SwiftUI SDK dropped the plain-array overload).
private struct Column: Identifiable {
  let id: Int
  let name: String
}

// MARK: - JSON mode

/// Every document as pretty-printed JSON text (monospaced, selectable).
struct JSONDocumentsView: View {
  let documents: [BSONDocument]

  private var blocks: [JSONBlock] {
    documents.enumerated().map { JSONBlock(id: $0.offset, document: $0.element) }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        ForEach(blocks) { block in
          VStack(alignment: .leading, spacing: 4) {
            Text(header(for: block)).font(.caption).foregroundStyle(.secondary)
            Text(JSONText.pretty(.document(block.document)))
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(10)
          .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        LoadMoreFooter()
      }
      .padding(10)
    }
  }

  private func header(for block: JSONBlock) -> String {
    let index = block.id + 1
    if let id = block.document["_id"], !BSONSupport.displayString(id).isEmpty {
      return "\(BSONSupport.displayString(id)) · #\(index)"
    }
    return "Document \(index)"
  }
}

/// One JSON block: (index, document) snapshotted per body evaluation.
private struct JSONBlock: Identifiable {
  let id: Int
  let document: BSONDocument
}

// MARK: - Value rendering helpers

/// Compact and pretty renderers for BSON values in the Table/JSON modes.
/// Leaf scalars use the display rules of `BSONSupport.displayString`;
/// strings and keys are JSON-escaped. Backslashes are assembled from
/// UnicodeScalar(92) so no escaping can be lost in transit.
enum JSONText {
  /// One-line rendering for table cells: containers flatten to
  /// `{"key": "value", ...}` / `["a", 1]`, leaves stay display strings.
  static func compact(_ bson: BSON) -> String {
    switch bson {
    case .document(let doc):
      guard !doc.isEmpty else { return "{}" }
      var items: [String] = []
      for (key, value) in doc.all { items.append("\(escaped(key)): \(compact(value))") }
      return "{ " + items.joined(separator: ", ") + " }"
    case .array(let values):
      guard !values.isEmpty else { return "[]" }
      var items: [String] = []
      for value in values { items.append(compact(value)) }
      return "[ " + items.joined(separator: ", ") + " ]"
    case .string:
      return escapedLeaf(bson)
    default:
      return BSONSupport.displayString(bson)
    }
  }

  /// Multi-line, 2-space-indented JSON for the JSON mode.
  static func pretty(_ bson: BSON, depth: Int = 0) -> String {
    let pad = String(repeating: "  ", count: depth)
    switch bson {
    case .document(let doc):
      guard !doc.isEmpty else { return "{}" }
      let inner = String(repeating: "  ", count: depth + 1)
      var lines: [String] = []
      for (key, value) in doc.all {
        lines.append("\(inner)\(escaped(key)): \(pretty(value, depth: depth + 1))")
      }
      return "{\n" + lines.joined(separator: ",\n") + "\n" + pad + "}"
    case .array(let values):
      guard !values.isEmpty else { return "[]" }
      let inner = String(repeating: "  ", count: depth + 1)
      var lines: [String] = []
      for value in values { lines.append("\(inner)\(pretty(value, depth: depth + 1))") }
      return "[\n" + lines.joined(separator: ",\n") + "\n" + pad + "]"
    case .string:
      return escapedLeaf(bson)
    default:
      return BSONSupport.displayString(bson)
    }
  }

  private static func escapedLeaf(_ bson: BSON) -> String {
    if case .string(let text) = bson { return escaped(text) }
    return BSONSupport.displayString(bson)
  }

  /// JSON-escapes and double-quotes a string. Control characters become
  /// \uXXXX escapes; the backslash itself is appended via UnicodeScalar(92).
  static func escaped(_ text: String) -> String {
    let backslash = Character(UnicodeScalar(92)!)
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x22: out.append(backslash); out.append("\"")
      case 0x5C: out.append(backslash); out.append(backslash)
      case 0x08: out.append(backslash); out.append("b")
      case 0x0C: out.append(backslash); out.append("f")
      case 0x0A: out.append(backslash); out.append("n")
      case 0x0D: out.append(backslash); out.append("r")
      case 0x09: out.append(backslash); out.append("t")
      case 0x00...0x1F:
        out.append(backslash); out.append("u")
        out += String(format: "%04X", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    out.append("\"")
    return out
  }
}
