import ComponentKit
import DatabaseKit
import SwiftUI

/// The rows in the kit's grid: one column per field, edited in place (Return or a double click), with unsaved rows
/// marked in the gutter.
struct RecordTable: View {
  @Bindable var browser: BrowserModel
  @Bindable var window: WindowModel
  let onDelete: ([Record]) -> Void

  private var sort: Binding<KitGridSort?> {
    Binding(
      get: { browser.request.sort.first.map { KitGridSort($0.field, ascending: $0.ascending) } },
      set: { new in
        browser.request.sort = new.map { [SortKey(field: $0.column, ascending: $0.ascending)] } ?? []
        Task { await browser.reload() }
      })
  }

  var body: some View {
    KitGrid(
      browser.records, columns: browser.visibleFields.map(column), selection: $browser.selection, sort: sort,
      rowState: rowState)
    .contextMenu {
      RecordMenu(browser: browser, ids: browser.selection, onDelete: onDelete)
    }
  }

  private func rowState(_ record: Record) -> KitGridRowState? {
    if browser.isPendingDelete(record) { return .deleted }
    return browser.isPendingUpdate(record) ? .edited : nil
  }

  private func column(_ field: FieldInfo) -> KitGridColumn<Record> {
    let width = idealWidth(field)
    let image = field.isPrimaryKey || field.keyRole != nil ? "key" : nil
    if field.isStatus {
      return KitGridColumn(field.name, id: field.name, systemImage: image, width: width, content: { record in
        StatusCell(value: browser.pendingValue(for: record, field: field.name) ?? record[field.name])
      })
    }
    let editable = browser.isEditable && !field.isPrimaryKey && !field.isGenerated && field.keyRole == nil
    return KitGridColumn(
      field.name, id: field.name, systemImage: image, width: width,
      alignment: field.category.isNumeric ? .trailing : .leading, mono: field.isMono,
      value: { record in
        let value = browser.pendingValue(for: record, field: field.name) ?? record[field.name]
        guard let value, !value.isNull, value != .unset else { return nil }
        return value.displayText
      },
      edit: editable ? { record, text in browser.stageCell(record, field: field, text: text) } : nil)
  }

  private func idealWidth(_ field: FieldInfo) -> CGFloat {
    if field.isPrimaryKey { return 90 }
    switch field.category {
    case .integer, .boolean: return 90
    case .decimal, .float: return 100
    case .date: return 110
    case .dateTime, .time: return 200
    case .uuid: return 280
    case .document, .list, .json: return 220
    default: return field.isStatus ? 110 : 160
    }
  }
}

/// A status word as a chip, or NULL.
private struct StatusCell: View {
  let value: CellValue?

  var body: some View {
    if let value, !value.isNull {
      Chip(status: value.displayText)
    } else {
      Text("NULL").kitFont(.monoSmall).foregroundStyle(.kitQuiet)
    }
  }
}

extension FieldInfo {
  /// A text field named like a status ("status", "state"): its words show as chips.
  var isStatus: Bool { category == .text && (name.contains("status") || name.contains("state")) }

  /// Values that read better monospaced: ids, dates, JSON.
  var isMono: Bool {
    isPrimaryKey || category == .uuid || category.isTemporal || category == .json || category == .binary
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
      .padding(KitMetrics.gutter)
    }
    .kitPane(.content)
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
            .kitFont(.headline)
            .lineLimit(1)
          Spacer()
          if let id = record["_id"] {
            Text(shortID(id.displayText)).kitFont(.monoSmall).foregroundStyle(.kitSecondary)
          }
        }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
          GridRow {
            ForEach(scalars.filter { $0.name != titleField(record) }.prefix(3)) { field in
              VStack(alignment: .leading, spacing: 1) {
                Text(field.name).kitFont(.caption)
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
      .kitSurface(.card)
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous)
            .strokeBorder(Hue.accent.fill, lineWidth: 2)
        }
      }
      .opacity(browser.isPendingDelete(record) ? 0.5 : 1)
    }
    .buttonStyle(.plain)
    .strikethrough(browser.isPendingDelete(record), color: .red)
  }

  private func titleField(_ record: Record) -> String? {
    ["name", "title", "customer", "email", "label"].first { record[$0] != nil }
  }

  private func shortID(_ text: String) -> String { text.count > 10 ? "…" + text.suffix(4) : text }
}

/// Arrays and sub-documents as quiet chips on one line.
struct FlowChips: View {
  let items: [String]
  var body: some View {
    HStack(spacing: 6) {
      ForEach(items, id: \.self) { item in
        Chip(Text(item).monospaced(), style: .quiet)
      }
    }
  }
}

/// Each item as pretty JSON (Extended JSON for documents), each a card; the selected one ringed.
struct JSONListView: View {
  @Bindable var browser: BrowserModel

  var body: some View {
    ScrollView {
      LazyVStack(spacing: KitMetrics.gutter) {
        ForEach(browser.records) { record in
          let selected = browser.selection.contains(record.id)
          Text(Exporter.json(record, fields: browser.fields))
            .kitFont(.monoSmall)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .kitSurface(.card)
            .overlay {
              if selected {
                RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous)
                  .strokeBorder(Hue.accent.fill, lineWidth: 2)
              }
            }
            .contentShape(Rectangle())
            .onTapGesture { browser.selection = [record.id] }
        }
      }
      .padding(KitMetrics.gutter)
    }
    .kitPane(.content)
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
          Button("Load More") { Task { await browser.nextPage() } }.buttonStyle(.kitPlain)
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
        Text(title).kitFont(.headline).lineLimit(1)
        Text([key, date.flatMap { record[$0.name]?.displayText }].compactMap { $0 }.joined(separator: " · "))
          .kitFont(.callout)
          .foregroundStyle(.kitSecondary)
          .lineLimit(1)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        if let numeric, let value = record[numeric.name], !value.isNull {
          Text(value.displayText).monospacedDigit()
        }
        if let status, let text = record[status.name]?.displayText {
          Chip(status: text)
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
