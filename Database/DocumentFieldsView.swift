import MongoDB
import Observation
import SwiftUI

/// Query-derived state of one key row: which way it is sorted and whether the
/// Projection text hides it.
struct KeyMenuState: Equatable {
  var sortDirection: SortText.Direction?
  var isHidden: Bool
}

/// Flat field tree: a document flattens into one row per field.

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

  /// True for the types edited through a text field (and therefore the only
  /// ones that can hold unparseable input or lose keyboard focus).
  var usesTextField: Bool {
    switch self {
    case .string, .integer, .number, .objectId: true
    case .boolean, .date, .null: false
    }
  }

  /// The BSON value for the working inputs, or `nil` when `text` does not
  /// parse for this type. Shared by the inline editor and the add-field row so
  /// both accept exactly the same input.
  func value(text: String, date: Date, bool: Bool) -> BSON? {
    switch self {
    case .string: .string(text)
    case .integer: Int64(text.trimmingCharacters(in: .whitespaces)).map(BSON.int64)
    case .number: Double(text.trimmingCharacters(in: .whitespaces)).map(BSON.double)
    case .boolean: .bool(bool)
    case .date: .datetime(date)
    case .null: .null
    case .objectId: (try? BSONObjectID(text.trimmingCharacters(in: .whitespaces))).map(BSON.objectID)
    }
  }

  /// Caption shown under a text field whose input does not parse, so a
  /// rejected Return/Add is explained instead of silently ignored.
  var invalidMessage: String {
    switch self {
    case .integer: "Not a valid integer"
    case .number: "Not a valid number"
    case .objectId: "Not a valid ObjectId (24 hex characters)"
    case .string, .boolean, .date, .null: "Not a valid value"
    }
  }
}

extension View {
  /// Red outline drawn over a rounded-border text field holding input that
  /// does not parse for the selected type.
  func invalidOutline(_ isInvalid: Bool) -> some View {
    overlay {
      if isInvalid {
        RoundedRectangle(cornerRadius: 5).stroke(.red, lineWidth: 1).allowsHitTesting(false)
      }
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
    type.value(text: text, date: date, bool: bool)
  }
}

// MARK: - Row view

/// A single `$key, $value` row. Key and value are separate cells; the value
/// cell is color-coded (`.primary` strings, `.blue` everything else) and,
/// when `isEditable`, turns into an editor on double-click. Containers show a
/// summary badge and render their children as indented rows below.
struct KeyValueRow: View {
  let row: FieldRow
  let editor: ValueEditorState?
  let expandedKeys: Set<String>
  /// Whether double-click opens the inline editor. The pane passes true only
  /// in Edit mode for engines that can write a value back; otherwise no
  /// double-click recognizer is installed, so a single click (expand a string)
  /// is not delayed waiting to rule out a second one.
  var isEditable: Bool = false
  let onToggle: (String) -> Void
  let onStartEdit: () -> Void
  let onCommit: () -> Void
  let onCancel: () -> Void
  /// Query-derived state for this key, supplied by the pane (sort direction from
  /// the Sort text, hidden from the Projection text). Drives the menu's
  /// disabled items; never stored by the row itself.
  var keyMenuState: KeyMenuState = KeyMenuState(sortDirection: nil, isHidden: false)
  /// Every key gesture funnels through the pane's single action handler.
  var onColumnAction: ((ColumnAction) -> Void)? = nil

  /// Drives the hover pencil that makes double-click editing discoverable.
  @State private var isHovering = false

  private var isEditing: Bool { editor?.docIndex == row.docIndex && editor?.path == row.path }

  private var isExpanded: Bool { expandedKeys.contains(row.key) }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(row.key).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).frame(
        width: 190, alignment: .leading
      ).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      valueContent
    }.padding(.leading, CGFloat(row.depth) * 16).padding(.vertical, 2)
      .contextMenu {
        // Array element rows are keyed `[0]`, `[1]`, … — not field names, so they
        // get no sort/search/filter/hide actions.
        if let onColumnAction, !row.key.hasPrefix("[") {
          Button("Sort Ascending", systemImage: "arrow.up") {
            onColumnAction(.setSort(row.key, .ascending))
          }.disabled(keyMenuState.sortDirection == .ascending)
          Button("Sort Descending", systemImage: "arrow.down") {
            onColumnAction(.setSort(row.key, .descending))
          }.disabled(keyMenuState.sortDirection == .descending)
          Button("Disable Sorting", systemImage: "xmark.circle") {
            onColumnAction(.disableSort(row.key))
          }.disabled(keyMenuState.sortDirection == nil)
          Divider()
          Button("Search…", systemImage: "magnifyingglass") { onColumnAction(.search(row.key)) }
          Button("Filter by this value") {
            onColumnAction(
              .filter(row.key, FilterRule(field: row.key, op: .equal, value: row.bson)))
          }
          Button("Filter by this field…") {
            onColumnAction(
              .filter(row.key, FilterRule(field: row.key, op: .contains, value: .string(""))))
          }
          Divider()
          if keyMenuState.isHidden {
            Button("Show", systemImage: "eye") { onColumnAction(.show(row.key)) }
          } else {
            Button("Hide", systemImage: "eye.slash") { onColumnAction(.hide(row.key)) }
          }
        }
      }
  }

  @ViewBuilder private var valueContent: some View {
    if isEditing, let editor {
      ValueEditor(state: editor, onCommit: onCommit, onCancel: onCancel)
    } else if row.bson.isContainer {
      // Containers collapse by default; click toggles their children.
      HStack(spacing: 4) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        Image(systemName: row.bson.isDocument ? "curlybraces.square" : "list.number")
        Text(row.bson.containerSummary)
      }.font(.system(.body, design: .monospaced)).foregroundStyle(.blue).contentShape(Rectangle())
        .onTapGesture { onToggle(row.key) }
    } else {
      HStack(spacing: 6) {
        leafGestures(leafText)
        // Hover pencil: the visible hint that this value can be edited, and a
        // single-click way in for pointer users who don't think to double-click.
        if isEditable && isHovering {
          Button {
            onStartEdit()
          } label: {
            Image(systemName: "pencil").font(.caption)
          }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Edit value")
        }
      }.onHover { isHovering = $0 }
    }
  }

  /// Leaf value: strings are `.primary` and one line until clicked open;
  /// every other scalar is `.blue` and shown in full.
  private var leafText: some View {
    let isString = row.bson.isString
    return Text(BSONSupport.displayString(row.bson)).font(.system(.body, design: .monospaced))
      .foregroundStyle(isString ? Color.primary : Color.blue)
      .lineLimit(isString && !isExpanded ? 1 : nil).truncationMode(.tail)
      .textSelection(.enabled).contentShape(Rectangle())
  }

  /// Installs only the recognizers this row needs. A double-tap recognizer
  /// makes every single tap wait out the double-click interval, so it is added
  /// only when the value is editable; strings keep click-to-expand either way.
  @ViewBuilder private func leafGestures(_ content: some View) -> some View {
    switch (isEditable, row.bson.isString) {
    case (true, true):
      content.onTapGesture(count: 2) { onStartEdit() }.onTapGesture { onToggle(row.key) }
        .help("Click to expand, double-click to edit")
    case (true, false):
      content.onTapGesture(count: 2) { onStartEdit() }.help("Double-click to edit")
    case (false, true):
      content.onTapGesture { onToggle(row.key) }
    case (false, false):
      content
    }
  }
}

/// The inline editor: a type picker plus the matching control
/// (TextField / Toggle / DatePicker / static null), with explicit save/cancel
/// buttons (Escape and click-away are not available everywhere, e.g. iOS).
/// Input that doesn't parse for the type is outlined and captioned instead of
/// silently keeping the editor open.
struct ValueEditor: View {
  @Bindable var state: ValueEditorState
  let onCommit: () -> Void
  let onCancel: () -> Void
  @FocusState private var focused: Bool
  /// Set by the first commit/cancel. Return can resign focus, and the blur
  /// that follows would otherwise fire a second commit (or a cancel) for the
  /// same edit.
  @State private var isFinished = false
  /// iOS dismisses the keyboard on every Return; after a rejected Return that
  /// blur must not cancel the edit and throw away what was typed.
  @State private var ignoresNextBlur = false

  private var isValid: Bool { state.committedValue() != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Picker("Type", selection: $state.type) {
          ForEach(EditableType.allCases) { type in Text(type.label).tag(type) }
        }.labelsHidden().controlSize(.small).fixedSize()
        control
        Button {
          commit()
        } label: {
          Image(systemName: "checkmark.circle.fill")
        }.buttonStyle(.borderless).disabled(!isValid).help("Save (Return)")
        Button {
          cancel()
        } label: {
          Image(systemName: "xmark.circle")
        }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel (Escape)")
      }
      if state.type.usesTextField && !isValid {
        Text(state.type.invalidMessage).font(.caption).foregroundStyle(.red)
      }
    }
    .onAppear { focused = true }
    // Clicking elsewhere ends the edit rather than leaving a dangling editor:
    // keep a value that parses, drop one that doesn't. Switching the type to
    // Boolean/Date/Null removes the text field (and its focus) on purpose, so
    // that blur is not treated as leaving the editor.
    .onChange(of: focused) { _, isFocused in
      guard !isFocused, state.type.usesTextField else { return }
      if ignoresNextBlur {
        ignoresNextBlur = false
        return
      }
      if isValid { commit() } else { cancel() }
    }
    // Back on a text type (e.g. Boolean → String): the field is new, so give it
    // focus again; the text kept from before is revalidated for the new type.
    .onChange(of: state.type) { _, type in
      if type.usesTextField { focused = true }
    }
  }

  @ViewBuilder private var control: some View {
    switch state.type {
    case .string, .integer, .number, .objectId:
      TextField("Value", text: $state.text).textFieldStyle(.roundedBorder).focused($focused)
        .invalidOutline(!isValid)
        .onSubmit { submit() }
        .onKeyPress(.escape) {
          cancel()
          return .handled
        }
#if os(macOS)
        .onExitCommand { cancel() }
#endif
        .frame(minWidth: 220)
    case .boolean: Toggle("", isOn: $state.bool).labelsHidden().toggleStyle(.switch)
    case .date:
      DatePicker("", selection: $state.date, displayedComponents: [.date, .hourAndMinute])
        .labelsHidden()
#if os(macOS)
        .datePickerStyle(.field)
#endif
    case .null: Text("null").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
    }
  }

  private func submit() {
#if os(iOS)
    if !isValid { ignoresNextBlur = true }
#endif
    commit()
  }

  /// Commits once; invalid input keeps the editor open with its caption.
  private func commit() {
    guard !isFinished, isValid else { return }
    isFinished = true
    onCommit()
  }

  private func cancel() {
    guard !isFinished else { return }
    isFinished = true
    onCancel()
  }
}

// MARK: - Add-field row

/// Edit-mode row that inserts a new key/value field into a document. Shown at
/// the end of each document section when Edit mode is on. It never grabs
/// focus on its own: one row exists per document in a lazy list, so an
/// auto-focus would jump the keyboard to whichever row scrolled in last.
struct AddFieldRow: View {
  let onAdd: (String, BSON) -> Void
  @State private var key = ""
  @State private var type: EditableType = .string
  @State private var text = ""
  @State private var date = Date()
  @State private var bool = false

  private var trimmedKey: String { key.trimmingCharacters(in: .whitespaces) }
  private var value: BSON? { type.value(text: text, date: date, bool: bool) }
  /// Only flag input the user actually typed; an untouched empty Integer
  /// field is merely incomplete, and Add is disabled for it anyway.
  private var showsInvalid: Bool { type.usesTextField && !text.isEmpty && value == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        TextField("New field", text: $key, prompt: Text("New field")).textFieldStyle(.roundedBorder)
          .frame(width: 190)
        Picker("Type", selection: $type) {
          ForEach(EditableType.allCases) { t in Text(t.label).tag(t) }
        }.labelsHidden().controlSize(.small).fixedSize()
        valueControl
        Button("Add") { add() }.disabled(trimmedKey.isEmpty || value == nil)
      }
      if showsInvalid {
        Text(type.invalidMessage).font(.caption).foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder private var valueControl: some View {
    switch type {
    case .string, .integer, .number, .objectId:
      TextField("Value", text: $text).textFieldStyle(.roundedBorder).frame(minWidth: 140)
        .invalidOutline(showsInvalid)
        .onSubmit { add() }
    case .boolean: Toggle("", isOn: $bool).labelsHidden()
    case .date:
      DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
#if os(macOS)
        .datePickerStyle(.field)
#endif
    case .null: Text("null").foregroundStyle(.secondary)
    }
  }

  private func add() {
    let k = trimmedKey
    guard !k.isEmpty, let value else { return }
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
