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
        Picker("Result", selection: $index) {
          ForEach(shown.indices, id: \.self) { Text("Result \($0 + 1)").tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(8)
      }
      if shown.indices.contains(index) {
        OutputView(output: shown[index])
      } else if let message = outputs.compactMap({ if case .message(let m) = $0 { m } else { nil } }).last {
        ContentUnavailableView(message, systemImage: "checkmark.circle")
      } else {
        ContentUnavailableView("No Results", systemImage: "tray")
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
      List {
        ForEach(Array(docs.enumerated()), id: \.offset) { _, doc in
          Text(doc.text(.shell, indent: 2))
            .font(.codeSmall)
            .textSelection(.enabled)
            .padding(.vertical, 3)
        }
      }
      .listStyle(.inset)
    case .text(let text):
      ScrollView {
        Text(text)
          .font(.code)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
    case .message(let text):
      ContentUnavailableView(text, systemImage: "checkmark.circle")
    }
  }
}

struct ResultRow: Identifiable {
  let id: Int
  let cells: [CellValue]
}

/// Query rows in a native table.
struct ResultTable: View {
  let fields: [FieldInfo]
  let rows: [[CellValue]]
  @State private var selection: Set<Int> = []

  private var indexedFields: [IndexedField] { fields.enumerated().map { IndexedField(index: $0.offset, field: $0.element) } }

  var body: some View {
    Table(rows.enumerated().map { ResultRow(id: $0.offset, cells: $0.element) }, selection: $selection) {
      TableColumnForEach(indexedFields) { column in
        TableColumn(Text(column.field.name)) { row in
          let value = column.index < row.cells.count ? row.cells[column.index] : .null
          if value.isNull {
            Text("NULL").italic().foregroundStyle(.tertiary)
          } else if column.field.category.isNumeric {
            Text(value.displayText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
          } else {
            Text(value.displayText).lineLimit(1)
          }
        }
        .width(min: 50, ideal: column.field.category.isNumeric ? 100 : 160)
      }
    }
    .stripedTableStyle()
    .contextMenu(forSelectionType: Int.self) { ids in
      Button("Copy Rows as CSV") {
        let picked = ids.sorted().compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        Clipboard.copy(Export.csv(fields: fields, rows: picked))
      }
      Button("Copy Rows as JSON") {
        let picked = ids.sorted().compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        Clipboard.copy(Export.json(fields: fields, rows: picked))
      }
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
