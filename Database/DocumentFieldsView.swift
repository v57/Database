import MongoDB
import Observation
import SwiftUI

// MARK: - Flat field tree

/// One flattened key/value row of a document: a single field (leaf or
/// container) with its path, display key, nesting depth, and BSON value.
/// Containers are followed by their children rows (always expanded).
struct FieldRow: Identifiable {
  let id: String
  let docIndex: Int
  let path: [BSONPathSegment]
  let key: String
  let depth: Int
  let bson: BSON
}

/// Flattens a document into display rows: every field becomes a row.
/// Nested documents/arrays are rendered collapsed by default — a container's
/// child rows are only included when its key is in `expandedKeys`, so an
/// expansion applies to every entry sharing that key across the whole list.
enum FieldTree {
  static func rows(for doc: BSONDocument, docIndex: Int, expandedKeys: Set<String>) -> [FieldRow] {
    var rows: [FieldRow] = []
    func walk(_ bson: BSON, path: [BSONPathSegment], depth: Int) {
      switch bson {
      case .document(let d):
        for key in d.keys {
          guard let value = d[key] else { continue }
          let p = path + [.key(key)]
          rows.append(
            FieldRow(
              id: id(for: p, docIndex: docIndex), docIndex: docIndex, path: p, key: key,
              depth: depth, bson: value))
          if expandedKeys.contains(key) { walk(value, path: p, depth: depth + 1) }
        }
      case .array(let items):
        for (i, value) in items.enumerated() {
          let p = path + [.index(i)]
          rows.append(
            FieldRow(
              id: id(for: p, docIndex: docIndex), docIndex: docIndex, path: p, key: "[\(i)]",
              depth: depth, bson: value))
          if expandedKeys.contains("[\(i)]") { walk(value, path: p, depth: depth + 1) }
        }
      default: break
      }
    }
    walk(.document(doc), path: [], depth: 0)
    return rows
  }

  private static func id(for path: [BSONPathSegment], docIndex: Int) -> String {
    "\(docIndex)\u{1F}" + path.map(\.description).joined(separator: "\u{1F}")
  }
}

// MARK: - Inline value editing

/// Editable value types, chosen by the type picker next to the editor.
enum EditableType: String, CaseIterable, Identifiable {
  case string, integer, number, boolean, date, null, objectId

  var id: String { rawValue }

  var label: String {
    switch self {
    case .string: "String"
    case .integer: "Integer"
    case .number: "Number"
    case .boolean: "Boolean"
    case .date: "Date"
    case .null: "Null"
    case .objectId: "ObjectId"
    }
  }

  static func matching(_ bson: BSON) -> EditableType {
    switch bson {
    case .string: .string
    case .int32, .int64: .integer
    case .double, .decimal128: .number
    case .bool: .boolean
    case .datetime: .date
    case .null: .null
    case .objectID: .objectId
    default: .string
    }
  }
}

/// Live editor state for one value: which document/path is being edited plus
/// the working text/date/bool per the selected type. A class so rows can
/// share the same mutable state while typing.
@Observable final class ValueEditorState {
  let docIndex: Int
  let path: [BSONPathSegment]
  var type: EditableType
  var text: String
  var date: Date
  var bool: Bool

  init(docIndex: Int, path: [BSONPathSegment], bson: BSON) {
    self.docIndex = docIndex
    self.path = path
    self.type = EditableType.matching(bson)
    self.text = ""
    self.date = Date()
    self.bool = false
    switch bson {
    case .string(let s): text = s
    case .int32(let i): text = String(i)
    case .int64(let i): text = String(i)
    case .double(let d): text = String(d)
    case .decimal128(let d): text = d.description
    case .bool(let b): bool = b
    case .datetime(let date): self.date = date
    case .objectID(let oid): text = oid.hex
    default: break
    }
  }

  /// The BSON value to write back, or `nil` when the current text does not
  /// parse for the selected type (integer/number/objectId).
  func committedValue() -> BSON? {
    switch type {
    case .string: return .string(text)
    case .integer: return Int64(text).map(BSON.int64)
    case .number: return Double(text).map(BSON.double)
    case .boolean: return .bool(bool)
    case .date: return .datetime(date)
    case .null: return .null
    case .objectId: return (try? BSONObjectID(text)).map(BSON.objectID)
    }
  }
}

// MARK: - Row view

/// A single `$key, $value` row. Key and value are separate cells; the value
/// cell is color-coded (`.primary` strings, `.blue` everything else) and
/// turns into an editor on double-click. Containers show a summary badge and
/// render their children as indented rows below.
struct KeyValueRow: View {
  let row: FieldRow
  let editor: ValueEditorState?
  let expandedKeys: Set<String>
  let onToggle: (String) -> Void
  let onStartEdit: () -> Void
  let onCommit: () -> Void
  let onCancel: () -> Void

  private var isEditing: Bool { editor?.docIndex == row.docIndex && editor?.path == row.path }

  private var isExpanded: Bool { expandedKeys.contains(row.key) }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(row.key).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).frame(
        width: 190, alignment: .leading
      ).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      valueContent
    }.padding(.leading, CGFloat(row.depth) * 16).padding(.vertical, 2)
  }

  @ViewBuilder private var valueContent: some View {
    if isEditing, let editor {
      ValueEditor(state: editor, onCommit: onCommit, onCancel: onCancel)
    } else if row.bson.isString {
      // Strings are one line by default; click to expand to full text.
      Text(BSONSupport.displayString(row.bson)).font(.system(.body, design: .monospaced))
        .foregroundStyle(.primary).lineLimit(isExpanded ? nil : 1).truncationMode(.tail)
        .textSelection(.enabled).contentShape(Rectangle()).onTapGesture(count: 2) { onStartEdit() }
        .onTapGesture { onToggle(row.key) }
    } else if row.bson.isContainer {
      // Containers collapse by default; click toggles their children.
      HStack(spacing: 4) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        Image(systemName: row.bson.isDocument ? "curlybraces.square" : "list.number")
        Text(row.bson.containerSummary)
      }.font(.system(.body, design: .monospaced)).foregroundStyle(.blue).contentShape(Rectangle())
        .onTapGesture { onToggle(row.key) }
    } else {
      // Non-string leaf: color-coded, selectable, double-click editable.
      Text(BSONSupport.displayString(row.bson)).font(.system(.body, design: .monospaced))
        .foregroundStyle(.blue).textSelection(.enabled).contentShape(Rectangle()).onTapGesture(
          count: 2
        ) { onStartEdit() }
    }
  }
}

/// The inline editor: a type picker plus the matching control
/// (TextField / Toggle / DatePicker / static null).
struct ValueEditor: View {
  @Bindable var state: ValueEditorState
  let onCommit: () -> Void
  let onCancel: () -> Void
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Picker("Type", selection: $state.type) {
        ForEach(EditableType.allCases) { type in Text(type.label).tag(type) }
      }.labelsHidden().controlSize(.small).fixedSize()
      control
    }.onAppear { focused = true }
  }

  @ViewBuilder private var control: some View {
    switch state.type {
    case .string, .integer, .number, .objectId:
      TextField("Value", text: $state.text).textFieldStyle(.roundedBorder).focused($focused)
        .onSubmit { onCommit() }.onExitCommand { onCancel() }.frame(minWidth: 220)
    case .boolean: Toggle("", isOn: $state.bool).labelsHidden().toggleStyle(.switch)
    case .date:
      DatePicker("", selection: $state.date, displayedComponents: [.date, .hourAndMinute])
        .labelsHidden().datePickerStyle(.field)
    case .null: Text("null").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
    }
  }
}

// MARK: - Add-field row

/// Edit-mode row that inserts a new key/value field into a document. Shown at
/// the end of each document section when Edit mode is on.
struct AddFieldRow: View {
  let onAdd: (String, BSON) -> Void
  @State private var key = ""
  @State private var type: EditableType = .string
  @State private var text = ""
  @State private var date = Date()
  @State private var bool = false
  @FocusState private var keyFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      TextField("New field", text: $key, prompt: Text("New field")).textFieldStyle(.roundedBorder)
        .frame(width: 190).focused($keyFocused)
      Picker("Type", selection: $type) {
        ForEach(EditableType.allCases) { t in Text(t.label).tag(t) }
      }.labelsHidden().controlSize(.small).fixedSize()
      valueControl
      Button("Add") { add() }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
    }.onAppear { keyFocused = true }
  }

  @ViewBuilder private var valueControl: some View {
    switch type {
    case .string, .integer, .number, .objectId:
      TextField("Value", text: $text).textFieldStyle(.roundedBorder).frame(minWidth: 140)
    case .boolean: Toggle("", isOn: $bool).labelsHidden()
    case .date:
      DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
        .datePickerStyle(.field)
    case .null: Text("null").foregroundStyle(.secondary)
    }
  }

  private func add() {
    let k = key.trimmingCharacters(in: .whitespaces)
    guard !k.isEmpty else { return }
    let value: BSON? =
      switch type {
      case .string: .string(text)
      case .integer: Int64(text).map(BSON.int64)
      case .number: Double(text).map(BSON.double)
      case .boolean: .bool(bool)
      case .date: .datetime(date)
      case .null: .null
      case .objectId: (try? BSONObjectID(text)).map(BSON.objectID)
      }
    guard let value else { return }
    onAdd(k, value)
    key = ""
    text = ""
  }
}

// MARK: - BSON display helpers (UI-facing)

extension BSON {
  var isString: Bool { if case .string = self { true } else { false } }
  var isDocument: Bool { if case .document = self { true } else { false } }
  var isArray: Bool { if case .array = self { true } else { false } }
  var isContainer: Bool { isDocument || isArray }

  /// `{3}` for a document, `[2]` for an array.
  var containerSummary: String {
    switch self {
    case .document(let d): return "{\(d.count)}"
    case .array(let a): return "[\(a.count)]"
    default: return ""
    }
  }
}
