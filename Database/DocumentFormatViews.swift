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
  /// A column has ONE width shared by its header and every row (sizing cells
  /// to their content let rows drift apart from the header). The default
  /// follows the field's kind — a boolean needs far less room than text —
  /// and dragging the header's right edge resizes it.
  static func defaultWidth(for kind: FieldKind?) -> CGFloat {
    switch kind {
    case .boolean: 90
    case .number: 120
    case .date: 210
    case .objectID: 230
    case .string: 220
    default: 200
    }
  }
  static let minColumnWidth: CGFloat = 60
  /// The leading `#` row-number column.
  static let indexWidth: CGFloat = 44

  let documents: [BSONDocument]
  /// Fields/kinds/sample values of the loaded rows (drives the header menus).
  let fields: [FieldInfo]
  /// Arrow per column, DERIVED from the Sort text by the owner (not stored here).
  let sortDirections: [String: SortText.Direction]
  /// Hidden columns, DERIVED from the Projection text by the owner.
  let hiddenFields: Set<String>
  /// Every column gesture funnels through this one callback. nil when the
  /// rows aren't a query the column UI can rewrite (aggregation output): the
  /// headers are then plain titles.
  let onColumnAction: ((ColumnAction) -> Void)?

  /// Widths the user dragged, by column name.
  @State private var columnWidths: [String: CGFloat] = [:]
  /// The column being resized and its width when the drag began.
  @State private var resizing: (name: String, startWidth: CGFloat)?
  @State private var selectedRow: Int?

  private func width(of name: String) -> CGFloat {
    columnWidths[name] ?? Self.defaultWidth(for: fields.first { $0.name == name }?.kind)
  }

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
          if let onColumnAction {
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
            columnMenu(column.name, onColumnAction: onColumnAction)
          } else {
            Text(column.name).font(.caption).bold().lineLimit(1).truncationMode(.tail)
          }
        }.padding(.horizontal, 6).frame(width: width(of: column.name), alignment: .leading)
          .overlay(alignment: .trailing) { resizeHandle(column.name) }
      }
    }
    .padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  /// Invisible grab strip on a header's right edge: dragging it resizes the
  /// column in the header and every row together.
  private func resizeHandle(_ name: String) -> some View {
    Color.clear.frame(width: 10).contentShape(Rectangle())
#if os(macOS)
      .pointerStyle(.columnResize)
#endif
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            if resizing?.name != name { resizing = (name, width(of: name)) }
            let start = resizing?.startWidth ?? width(of: name)
            columnWidths[name] = max(Self.minColumnWidth, start + drag.translation.width)
          }
          .onEnded { _ in resizing = nil }
      )
      .offset(x: 5)
      .accessibilityHidden(true)
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
  private func columnMenu(_ name: String, onColumnAction: @escaping (ColumnAction) -> Void)
    -> some View
  {
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
      Label("\(name) column options", systemImage: "chevron.down").labelStyle(.iconOnly)
        .font(.caption2).foregroundStyle(.secondary).touchTarget(32)
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help("Sort, search, filter or hide \(name)")
  }

  private func rowView(_ row: TableRow, columns cols: [Column]) -> some View {
    let doc = row.document
    var displays: [DisplayCell] = []
    for column in cols {
      if let value = doc[column.name] {
        // Strings read as plain text, as in the List format; only nested
        // documents/arrays use (escaped) JSON.
        let text = value.isContainer ? JSONText.compact(value) : BSONSupport.displayString(value)
        displays.append(DisplayCell(text: text, isString: value.isString))
      } else {
        displays.append(DisplayCell(text: "—", isString: nil))
      }
    }
    let isSelected = selectedRow == row.id
    return HStack(spacing: 0) {
      Text("\(row.id + 1)").font(.caption.monospacedDigit())
        .foregroundStyle(.secondary).frame(width: Self.indexWidth, alignment: .center)
      ForEach(cols) { column in
        columnDivider
        cellView(displays[column.id], width: width(of: column.name))
          .contextMenu {
            if displays[column.id].isString != nil {
              Button("Copy Value", systemImage: "doc.on.doc") {
                Clipboard.copy(displays[column.id].text)
              }
            }
            Button("Copy Row as JSON", systemImage: "curlybraces") {
              Clipboard.copy(JSONText.pretty(.document(doc)))
            }
          }
      }
    }
    .padding(.vertical, 3)
    .background {
      if isSelected {
        Color.accentColor.opacity(0.18)
      } else if !row.id.isMultiple(of: 2) {
        Color.primary.opacity(0.03)
      }
    }
    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    .contentShape(Rectangle())
    .onTapGesture { selectedRow = isSelected ? nil : row.id }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// One table cell (text + how to color it). `isString` nil = key missing.
  private struct DisplayCell {
    let text: String
    let isString: Bool?
  }

  @ViewBuilder
  private func cellView(_ cell: DisplayCell, width: CGFloat) -> some View {
    if let isString = cell.isString {
      Text(cell.text).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
        .foregroundStyle(isString ? Color.primary : Color.blue)
        .padding(.horizontal, 6).frame(width: width, alignment: .leading)
        .help(cell.text)
    } else {
      Text(cell.text).foregroundStyle(.secondary)
        .padding(.horizontal, 6).frame(width: width, alignment: .leading)
        .help("Field not present in this document")
        .accessibilityLabel("Missing")
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
        } else if let error = model.loadMoreError {
          // The scroll trigger already fired; without a button the list would
          // stay stuck on a footer that never loads.
          Label("Couldn't load more: \(error)", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.red).lineLimit(2)
          Button("Retry") { Task { await model.loadMoreDocuments() } }
            .font(.caption).buttonStyle(.borderless)
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
  /// Block caption ("<_id> · #3", "Row 3"), shared with the List format.
  let header: (BSONDocument, Int) -> String

  private var blocks: [JSONBlock] {
    documents.enumerated().map { JSONBlock(id: $0.offset, document: $0.element) }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        ForEach(blocks) { block in
          VStack(alignment: .leading, spacing: 4) {
            Text(header(block.document, block.id)).font(.caption).foregroundStyle(.secondary)
            Text(JSONText.pretty(.document(block.document)))
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(10)
          .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
          .contextMenu {
            Button("Copy JSON", systemImage: "doc.on.doc") {
              Clipboard.copy(JSONText.pretty(.document(block.document)))
            }
          }
        }
        LoadMoreFooter()
      }
      .padding(10)
    }
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
