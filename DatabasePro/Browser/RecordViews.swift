import DatabaseCore
import SwiftUI

/// Sorts records by a field (the Table's sort descriptor; the server does the real sorting).
struct FieldComparator: SortComparator {
  var field: String
  var order: SortOrder = .forward
  func compare(_ lhs: Record, _ rhs: Record) -> ComparisonResult {
    let a = lhs[field]?.displayText ?? ""
    let b = rhs[field]?.displayText ?? ""
    let result = a.localizedStandardCompare(b)
    return order == .forward ? result : result.reversed
  }
}

extension ComparisonResult {
  var reversed: ComparisonResult {
    switch self {
    case .orderedAscending: .orderedDescending
    case .orderedDescending: .orderedAscending
    case .orderedSame: .orderedSame
    }
  }
}

/// The rows as a native table with one column per field.
struct RecordTable: View {
  @Bindable var browser: BrowserModel
  @Bindable var window: WindowModel
  let onDelete: ([Record]) -> Void

  private var sortOrder: Binding<[FieldComparator]> {
    Binding(
      get: { browser.request.sort.map { FieldComparator(field: $0.field, order: $0.ascending ? .forward : .reverse) } },
      set: { new in
        browser.request.sort = new.prefix(1).map { SortKey(field: $0.field, ascending: $0.order == .forward) }
        Task { await browser.reload() }
      })
  }

  var body: some View {
    Table(browser.records, selection: $browser.selection, sortOrder: sortOrder) {
      TableColumnForEach(browser.visibleFields) { field in
        TableColumn(Text(columnTitle(field)), sortUsing: FieldComparator(field: field.name)) { record in
          CellView(browser: browser, record: record, field: field)
        }
        .width(min: 50, ideal: idealWidth(field))
        .customizationID(field.name)
      }
    }
    .stripedTableStyle()
    .contextMenu(forSelectionType: Record.ID.self) { ids in
      RecordMenu(browser: browser, ids: ids, onDelete: onDelete)
    } primaryAction: { ids in
      if let id = ids.first {
        browser.selection = [id]
        window.showsInspector = true
        browser.editRequest = id
      }
    }
  }

  private func columnTitle(_ field: FieldInfo) -> String {
    field.isPrimaryKey ? "🔑\u{FE0E} " + field.name : field.name
  }

  private func idealWidth(_ field: FieldInfo) -> CGFloat {
    if field.isPrimaryKey { return 90 }
    switch field.category {
    case .integer, .boolean: return 80
    case .decimal, .float: return 100
    case .date: return 110
    case .dateTime, .time: return 180
    case .uuid: return 280
    case .document, .list, .json: return 220
    default: return 170
    }
  }
}

/// Context menu for selected rows.
struct RecordMenu: View {
  let browser: BrowserModel
  let ids: Set<Record.ID>
  let onDelete: ([Record]) -> Void

  var body: some View {
    let records = browser.records.filter { ids.contains($0.id) }
    if records.count == 1, let record = records.first {
      Button("Copy as JSON", systemImage: "doc.on.doc") { Clipboard.copy(Exporter.json(record, fields: browser.fields)) }
      if browser.engine.family == .sql || browser.engine.family == .wideColumn {
        Button("Copy as INSERT") { Clipboard.copy(Exporter.insert(record, browser: browser)) }
      }
      Menu("Filter by Value") {
        ForEach(browser.visibleFields.prefix(12)) { field in
          if let value = record[field.name], !value.isNull, field.category != .list, field.category != .document {
            Button("\(field.name) is \(value.displayText)") {
              Task { await browser.addFilter(Filter(field: field.name, op: .equals, value: value.editingText)) }
            }
          }
        }
      }
    } else if !records.isEmpty {
      Button("Copy \(records.count) as JSON", systemImage: "doc.on.doc") {
        Clipboard.copy("[\n" + records.map { Exporter.json($0, fields: browser.fields) }.joined(separator: ",\n") + "\n]")
      }
    }
    if browser.isEditable, records.contains(where: { $0.key != nil }) {
      Divider()
      Button("Delete \(records.count == 1 ? browser.noun.capitalized : browser.noun.count(records.count))…", systemImage: "trash", role: .destructive) {
        onDelete(records)
      }
    }
  }
}

/// One cell: the value, a status pill, NULL in grey, and pending edits highlighted.
struct CellView: View {
  let browser: BrowserModel
  let record: Record
  let field: FieldInfo

  var body: some View {
    let pending = browser.pendingValue(for: record, field: field.name)
    let value = pending ?? record[field.name]
    Group {
      if let value, !value.isNull {
        let text = value.displayText
        if field.category == .text, (field.name.contains("status") || field.name.contains("state")),
          let color = StatusPill.color(for: text)
        {
          Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
        } else if field.category.isNumeric {
          Text(text).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        } else if field.isPrimaryKey || field.category == .uuid || value.bsonValue.map({ if case .objectId = $0 { true } else { false } }) == true {
          Text(text).font(.codeSmall).foregroundStyle(.secondary)
        } else {
          Text(text)
        }
      } else if value == .unset || value == nil {
        Text("—").foregroundStyle(.tertiary)
      } else {
        Text("NULL").italic().foregroundStyle(.tertiary)
      }
    }
    .lineLimit(1)
    .strikethrough(browser.isPendingDelete(record), color: .red)
    .padding(.horizontal, pending != nil ? 4 : 0)
    .background(pending != nil ? Color.orange.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
    .help(pending != nil ? "Changed, not saved yet" : "")
  }
}

/// Documents as cards: a title, a few fields, and chips for arrays and sub-documents.
struct CardsView: View {
  @Bindable var browser: BrowserModel

  var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
        ForEach(browser.records) { record in
          card(record)
        }
      }
      .padding(16)
    }
  }

  private func card(_ record: Record) -> some View {
    let selected = browser.selection.contains(record.id)
    let fields = browser.visibleFields.filter { $0.name != "_id" }
    let scalars = fields.filter { field in
      guard let value = record[field.name]?.bsonValue ?? (record[field.name]?.isNull == false ? .string("") : nil) else { return false }
      return !value.isContainer
    }
    let containers = fields.filter { record[$0.name]?.bsonValue?.isContainer == true }
    return Button {
      browser.selection = [record.id]
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text(browser.displayName(for: record) ?? record.key?.summary ?? "Document")
            .font(.headline)
            .lineLimit(1)
          Spacer()
          if let id = record["_id"] {
            Text(shortID(id.displayText)).font(.codeSmall).foregroundStyle(.secondary)
          }
        }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
          GridRow {
            ForEach(scalars.filter { $0.name != titleField(record) }.prefix(3)) { field in
              VStack(alignment: .leading, spacing: 1) {
                Text(field.name).font(.caption).foregroundStyle(.secondary)
                Text(record[field.name]?.displayText ?? "—").monospacedDigit().lineLimit(1)
              }
            }
          }
        }
        if !containers.isEmpty {
          FlowChips(items: containers.prefix(4).map { "\($0.name) \(record[$0.name]?.displayText ?? "")" })
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1)
      )
      .shadow(color: selected ? Color.accentColor.opacity(0.2) : .black.opacity(0.04), radius: selected ? 4 : 1, y: 1)
    }
    .buttonStyle(.plain)
    .strikethrough(browser.isPendingDelete(record), color: .red)
  }

  private func titleField(_ record: Record) -> String? {
    ["name", "title", "customer", "email", "label"].first { record[$0] != nil }
  }

  private func shortID(_ text: String) -> String { text.count > 10 ? "…" + text.suffix(4) : text }
}

/// Small grey chips laid out on one line.
struct FlowChips: View {
  let items: [String]
  var body: some View {
    HStack(spacing: 6) {
      ForEach(items, id: \.self) { item in
        Text(item)
          .font(.codeSmall)
          .lineLimit(1)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
    }
  }
}

/// Each item as pretty JSON (Extended JSON for documents).
struct JSONListView: View {
  @Bindable var browser: BrowserModel

  var body: some View {
    List(selection: $browser.selection) {
      ForEach(browser.records) { record in
        Text(Exporter.json(record, fields: browser.fields))
          .font(.codeSmall)
          .textSelection(.enabled)
          .padding(.vertical, 4)
          .tag(record.id)
      }
    }
    .listStyle(.inset)
  }
}

/// iPhone: one row per item, tapping opens it.
struct PhoneRecordList: View {
  @Bindable var browser: BrowserModel
  @Bindable var window: WindowModel

  var body: some View {
    List {
      Section {
        ForEach(browser.records) { record in
          NavigationLink {
            RecordDetailScreen(browser: browser, record: record, window: window)
          } label: {
            PhoneRecordRow(browser: browser, record: record)
          }
        }
        if browser.page?.hasMore == true {
          Button("Load More") { Task { await browser.nextPage() } }
        }
      }
    }
    #if os(iOS)
      .listStyle(.insetGrouped)
    #endif
    .refreshable { await browser.reload() }
  }
}

struct PhoneRecordRow: View {
  let browser: BrowserModel
  let record: Record

  var body: some View {
    let title = browser.displayName(for: record) ?? record.key?.summary ?? "Item"
    // An amount reads better than an id: prefer decimals, and skip keys and references.
    let amounts = browser.fields.filter { $0.category.isNumeric && !$0.isPrimaryKey && $0.references == nil && $0.keyRole == nil }
    let numeric = amounts.first { $0.category == .decimal } ?? amounts.first
    let key = record.key.map(\.summary).flatMap { $0 == title ? nil : "#" + $0 }
    let status = browser.fields.first { $0.name.contains("status") || $0.name.contains("state") }
    let date = browser.fields.first { $0.category.isTemporal }
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.semibold).lineLimit(1)
        Text([key, date.flatMap { record[$0.name]?.displayText }].compactMap { $0 }.joined(separator: " · "))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        if let numeric, let value = record[numeric.name], !value.isNull {
          Text(value.displayText).monospacedDigit()
        }
        if let status, let text = record[status.name]?.displayText, let color = StatusPill.color(for: text) {
          Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
        }
      }
    }
    .strikethrough(browser.isPendingDelete(record), color: .red)
  }
}

/// Copy helpers.
enum Exporter {
  static func json(_ record: Record, fields: [FieldInfo]) -> String {
    if let doc = record.document { return doc.text(.extendedJSON, indent: 2) }
    var doc = BSONDocument()
    for field in fields {
      guard let value = record[field.name] else { continue }
      doc[field.name] = bson(value)
    }
    return doc.text(.extendedJSON, indent: 2)
  }

  static func bson(_ value: CellValue) -> BSON {
    switch value {
    case .bson(let b): return b
    case .unset: return .null
    case .db(let v):
      switch v {
      case .null: return .null
      case .bool(let b): return .bool(b)
      case .int(let i): return Int32(exactly: i).map(BSON.int32) ?? .int64(i)
      case .double(let d): return .double(d)
      case .decimal(let s): return Decimal128(s).map(BSON.decimal128) ?? .string(s)
      case .json(let s):
        if let parsed = try? BSON(parsing: s) { return parsed }
        return .string(s)
      case .list(let items): return .array(items.map { bson(.db($0)) })
      case .map(let pairs): return .document(BSONDocument(pairs.map { ($0.key.displayText, bson(.db($0.value))) }))
      default: return .string(v.displayText)
      }
    }
  }

  @MainActor static func insert(_ record: Record, browser: BrowserModel) -> String {
    let edit = RecordEdit(ref: browser.ref, key: nil, kind: .insert(record.values), title: "")
    return (try? browser.session?.statements(for: [edit]).first) ?? ""
  }
}
