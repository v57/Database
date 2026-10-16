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

/// Query rows in the kit's grid.
struct ResultTable: View {
  let fields: [FieldInfo]
  let rows: [[CellValue]]
  @State private var selection: Set<Int> = []

  var body: some View {
    KitGrid(
      rows.enumerated().map { ResultRow(id: $0.offset, cells: $0.element) },
      columns: fields.enumerated().map { index, field in
        KitGridColumn<ResultRow>(
          field.name, id: "\(index)", width: field.category.isNumeric ? 100 : 160,
          alignment: field.category.isNumeric ? .trailing : .leading, mono: field.isMono
        ) { row in
          let value = index < row.cells.count ? row.cells[index] : .null
          return value.isNull ? nil : value.displayText
        }
      },
      selection: $selection
    )
    .rowContextMenu { ids in
      let picked = ids.sorted().compactMap { rows.indices.contains($0) ? rows[$0] : nil }
      Button("Copy \(picked.count == 1 ? "Row" : "\(picked.count) Rows") as CSV") {
        KitPasteboard.copy(Export.csv(fields: fields, rows: picked))
      }
      Button("Copy \(picked.count == 1 ? "Row" : "\(picked.count) Rows") as JSON") {
        KitPasteboard.copy(Export.json(fields: fields, rows: picked))
      }
    }
    .padding(.horizontal, KitMetrics.gutter)
    .padding(.bottom, KitMetrics.gutter)
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
