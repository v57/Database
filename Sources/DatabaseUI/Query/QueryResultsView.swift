import ComponentKit
import DatabaseKit
import SwiftUI

/// Results of a query: tables, documents, text, with export.
struct QueryResultsView: View {
  let outputs: [QueryOutput]
  let connection: LiveConnection
  @State private var index = 0

  private var shown: [QueryOutput] {
    outputs.filter { if case .message = $0 { false } else { true } }
  }

  var body: some View {
    VStack(spacing: 0) {
      if shown.count > 1 {
        KitSegmented(selection: $index, options: shown.indices.map { ("Result \($0 + 1)", $0) })
          .padding(KitMetrics.gutter)
      }
      if shown.indices.contains(index) {
        OutputView(output: shown[index])
      } else if let message = outputs.compactMap({ if case .message(let m) = $0 { m } else { nil } }).last {
        EmptyState(systemImage: "checkmark.circle", title: message)
      } else {
        EmptyState(systemImage: "tray", title: "No Results")
      }
    }
    .onChange(of: outputs.count) { index = max(0, shown.count - 1) }
  }
}

/// One output.
struct OutputView: View {
  let output: QueryOutput

  var body: some View {
    switch output {
    case .table(let fields, let rows, _):
      ResultTable(fields: fields, rows: rows)
    case .documents(let docs, _):
      ScrollView {
        LazyVStack(spacing: KitMetrics.gutter) {
          ForEach(Array(docs.enumerated()), id: \.offset) { _, doc in
            Text(doc.text(.shell, indent: 2))
              .kitFont(.monoSmall)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
              .kitSurface(.card)
          }
        }
        .padding(KitMetrics.gutter)
      }
    case .text(let text):
      ScrollView {
        Text(text)
          .kitFont(.mono)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
    case .message(let text):
      EmptyState(systemImage: "checkmark.circle", title: text)
    }
  }
}

struct ResultRow: Identifiable {
  let id: Int
  let cells: [CellValue]
}

/// Query rows in the kit's grid. The rows and columns are made here, once per result; the selection lives in
/// `ResultGrid`, so a click doesn't wrap every row of a long result again.
struct ResultTable: View {
  let fields: [FieldInfo]
  let rows: [[CellValue]]
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let widths = Self.fittedWidths(fields: fields, rows: rows, idiom: idiom)
    ResultGrid(
      fields: fields, rows: rows,
      gridRows: rows.enumerated().map { ResultRow(id: $0.offset, cells: $0.element) },
      columns: fields.enumerated().map { index, field in
        KitGridColumn<ResultRow>(
          field.name, id: "\(index)", width: widths[index],
          alignment: field.category.isNumeric ? .trailing : .leading, mono: field.isMono
        ) { row in
          let value = index < row.cells.count ? row.cells[index] : .null
          return value.isNull ? nil : value.displayText
        }
      })
  }
}

extension ResultTable {
  /// Each column as wide as its title or its longest value in the first 200 rows, from the number of characters,
  /// 48 to 320 points. Fixed widths (100 for a number, 160 for text) left an id far from its row's start and cut a
  /// product's name, worst on iPhone's larger type.
  static func fittedWidths(fields: [FieldInfo], rows: [[CellValue]], idiom: KitIdiom) -> [CGFloat] {
    let sample = rows.prefix(200)
    return fields.indices.map { index in
      let field = fields[index]
      var characters = field.name.count
      for row in sample where index < row.count {
        let value = row[index]
        characters = max(characters, value.isNull ? 4 : value.displayText.prefix(60).count)
      }
      let touch = idiom == .phone || idiom == .pad
      let character: CGFloat = field.isMono ? (touch ? 10 : 7.8) : (touch ? 9 : 7)
      return min(max(CGFloat(characters) * character + (touch ? 28 : 20), 48), 320)
    }
  }
}

private struct ResultGrid: View {
  let fields: [FieldInfo]
  let rows: [[CellValue]]
  let gridRows: [ResultRow]
  let columns: [KitGridColumn<ResultRow>]
  @State private var selection: Set<Int> = []
  @State private var shownRow: ShownRow?
  @Environment(\.kitIdiom) private var idiom

  struct ShownRow: Identifiable {
    let id: Int
  }

  var body: some View {
    KitGrid(gridRows, columns: columns, selection: $selection)
    .rowContextMenu { ids in
      let picked = ids.sorted().compactMap { rows.indices.contains($0) ? rows[$0] : nil }
      Button(picked.count == 1 ? "Copy Row as CSV" : "Copy \(picked.count) Rows as CSV") {
        KitPasteboard.copy(Export.csv(fields: fields, rows: picked))
      }
      Button(picked.count == 1 ? "Copy Row as JSON" : "Copy \(picked.count) Rows as JSON") {
        KitPasteboard.copy(Export.json(fields: fields, rows: picked))
      }
    }
    // On iPhone a tapped row opens in a sheet: its values are cut to their columns, and the row is wider than the
    // screen.
    .onChange(of: selection) { _, picked in
      if idiom == .phone, picked.count == 1, let id = picked.first { shownRow = ShownRow(id: id) }
    }
    .kitSheet(item: $shownRow, onDismiss: { selection = [] }) { shown in
      if rows.indices.contains(shown.id) {
        ResultRowSheet(fields: fields, row: rows[shown.id], number: shown.id + 1)
      }
    }
    .padding(.horizontal, KitMetrics.gutter)
    .padding(.bottom, KitMetrics.gutter)
  }
}

/// A result row's values, one under another, whole (iPhone: a tap on a row).
private struct ResultRowSheet: View {
  let fields: [FieldInfo]
  let row: [CellValue]
  let number: Int
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    KitSheet(title: "Row \(number)", meta: "\(fields.count) fields", systemImage: "tablecells") {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
          let value = index < row.count ? row[index] : .null
          VStack(alignment: .leading, spacing: 3) {
            Text(field.name).kitFont(.caption).foregroundStyle(.kitSecondary)
            if value.isNull {
              Text(verbatim: "NULL").kitFont(.mono).foregroundStyle(.kitTertiary)
            } else {
              Text(value.displayText)
                .kitFont(field.isMono ? .mono : .body)
                .textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(12)
      .kitSurface(.card)
    } footer: {
      Button("Copy as JSON") { KitPasteboard.copy(Export.json(fields: fields, rows: [row])) }
      Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }
}

struct IndexedField: Identifiable {
  let index: Int
  let field: FieldInfo
  var id: Int { index }
}

/// CSV and JSON for results.
enum Export {
  static func csv(fields: [FieldInfo], rows: [[CellValue]]) -> String {
    func quote(_ text: String) -> String {
      text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
    var lines = [fields.map { quote($0.name) }.joined(separator: ",")]
    for row in rows {
      lines.append(row.map { $0.isNull ? "" : quote($0.editingText) }.joined(separator: ","))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  static func json(fields: [FieldInfo], rows: [[CellValue]]) -> String {
    let docs = rows.map { row in
      BSONDocument(fields.enumerated().map { index, field in (field.name, Exporter.bson(index < row.count ? row[index] : .null)) })
    }
    return BSON.array(docs.map(BSON.document)).text(.extendedJSON, indent: 2)
  }
}
