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

  /// Expansion identity: the path WITHOUT the document index, so expanding
  /// `address` opens it in every document — but not some other field's
  /// nested `address`, nor `[0]` of every unrelated array.
  var expansionKey: String { FieldTree.expansionKey(for: path) }

  /// The dotted path queries use (`address.city`, `tags.0.name`); nil for an
  /// array element itself (`[0]` is not a field).
  var queryPath: String? {
    guard case .key = path.last else { return nil }
    return path.map { segment in
      switch segment {
      case .key(let key): key
      case .index(let i): String(i)
      }
    }.joined(separator: ".")
  }
}

/// Flattens a document into display rows: every field becomes a row.
/// Nested documents/arrays are rendered collapsed by default — a container's
/// child rows are only included when its path is in `expandedKeys`, so an
/// expansion applies to that same field in every entry of the list.
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
          if expandedKeys.contains(expansionKey(for: p)) { walk(value, path: p, depth: depth + 1) }
        }
      case .array(let items):
        for (i, value) in items.enumerated() {
          let p = path + [.index(i)]
          rows.append(
            FieldRow(
              id: id(for: p, docIndex: docIndex), docIndex: docIndex, path: p, key: "[\(i)]",
              depth: depth, bson: value))
          if expandedKeys.contains(expansionKey(for: p)) { walk(value, path: p, depth: depth + 1) }
        }
      default: break
      }
    }
    walk(.document(doc), path: [], depth: 0)
    return rows
  }

  static func expansionKey(for path: [BSONPathSegment]) -> String {
    path.map(\.description).joined(separator: "\u{1F}")
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

  /// Whether the inline editor can write `bson` back unchanged in kind.
  /// Binary, regex, decimal128, timestamps and the like have no editor here:
  /// they used to open as an EMPTY string field that saved "" on blur.
  static func canEdit(_ bson: BSON) -> Bool {
    switch bson {
    case .string, .int32, .int64, .double, .bool, .datetime, .null, .objectID: true
    default: false
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
  /// An int32 stays int32 when edited (if the new value still fits), instead
  /// of silently widening the stored type to int64.
  private let keepsInt32: Bool

  init(docIndex: Int, path: [BSONPathSegment], bson: BSON) {
    self.docIndex = docIndex
    self.path = path
    if case .int32 = bson { keepsInt32 = true } else { keepsInt32 = false }
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
    let value = type.value(text: text, date: date, bool: bool)
    if keepsInt32, case .int64(let n)? = value, let small = Int32(exactly: n) { return .int32(small) }
    return value
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

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  /// Drives the hover pencil that makes double-click editing discoverable.
  @State private var isHovering = false

  private var isEditing: Bool { editor?.docIndex == row.docIndex && editor?.path == row.path }

  private var isExpanded: Bool { expandedKeys.contains(row.expansionKey) }

  /// Edit mode is on AND this value's type has an editor. A document's own
  /// `_id` is immutable on the server, so it never gets one.
  private var canEditValue: Bool {
    isEditable && EditableType.canEdit(row.bson) && !isDocumentID
  }

  private var isDocumentID: Bool { row.depth == 0 && row.key == "_id" }

  /// Why a value in Edit mode has no editor (shown as a lock tooltip).
  private var readOnlyReason: String {
    isDocumentID ? "_id can't be changed" : "\(row.bson.typeName) values can't be edited here"
  }

  private var isCompact: Bool { horizontalSizeClass == .compact }

  /// Narrower key column on iPhone, where 190pt left values about half the row.
  private var keyWidth: CGFloat { horizontalSizeClass == .compact ? 110 : 190 }

  var body: some View {
    Group {
      if isEditing && isCompact {
        // The editor (type picker, field, save/cancel) needs the full row
        // width on iPhone; beside the key column it ran off screen.
        VStack(alignment: .leading, spacing: 4) {
          keyLabel
          valueContent
        }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          keyLabel.frame(width: max(keyWidth - CGFloat(row.depth) * 16, 60), alignment: .leading)
          valueContent
        }
      }
    }.padding(.leading, CGFloat(row.depth) * 16).padding(.vertical, 2)
      .accessibilityElement(children: .combine)
      .accessibilityValue(row.bson.isString || row.bson.isContainer ? "" : row.bson.typeName)
      .contextMenu {
        if !row.bson.isContainer {
          Button("Copy Value", systemImage: "doc.on.doc") {
            Clipboard.copy(BSONSupport.displayString(row.bson))
          }
        } else {
          Button("Copy as JSON", systemImage: "doc.on.doc") {
            Clipboard.copy(JSONText.pretty(row.bson))
          }
        }
        if canEditValue {
          Button("Edit Value", systemImage: "pencil") { onStartEdit() }
        }
        // Array elements (`[0]`, `[1]`, …) are not fields, so they get no
        // sort/search/filter/hide actions. Nested fields use their full
        // dotted path (`address.city`), never the bare key.
        if let onColumnAction, let field = row.queryPath {
          Divider()
          Button("Sort Ascending", systemImage: "arrow.up") {
            onColumnAction(.setSort(field, .ascending))
          }.disabled(keyMenuState.sortDirection == .ascending)
          Button("Sort Descending", systemImage: "arrow.down") {
            onColumnAction(.setSort(field, .descending))
          }.disabled(keyMenuState.sortDirection == .descending)
          Button("Disable Sorting", systemImage: "xmark.circle") {
            onColumnAction(.disableSort(field))
          }.disabled(keyMenuState.sortDirection == nil)
          Divider()
          Button("Search…", systemImage: "magnifyingglass") { onColumnAction(.search(field)) }
          Button("Filter by this value") {
            onColumnAction(.filter(field, FilterRule(field: field, op: .equal, value: row.bson)))
          }
          Button("Filter by this field…") {
            onColumnAction(
              .filter(field, FilterRule(field: field, op: .contains, value: .string(""))))
          }
          // Hide/Show write the projection over the top-level field list.
          if row.depth == 0 {
            Divider()
            if keyMenuState.isHidden {
              Button("Show", systemImage: "eye") { onColumnAction(.show(field)) }
            } else {
              Button("Hide", systemImage: "eye.slash") { onColumnAction(.hide(field)) }
            }
          }
        }
      }
  }

  private var keyLabel: some View {
    Text(row.key).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
      .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
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
        .onTapGesture { onToggle(row.expansionKey) }
    } else {
      HStack(spacing: 6) {
        leafGestures(leafText)
        // Hover pencil: the visible hint that this value can be edited, and a
        // single-click way in for pointer users who don't think to double-click.
        // iOS has no hover, so the pencil stays visible there in Edit mode.
        if canEditValue && (isHovering || Self.isTouchPlatform) {
          Button {
            onStartEdit()
          } label: {
            Image(systemName: "pencil").font(.caption)
          }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Edit value")
            .accessibilityLabel("Edit \(row.key)")
        } else if isEditable && !canEditValue {
          Image(systemName: "lock").font(.caption).foregroundStyle(.tertiary)
            .help(readOnlyReason)
            .accessibilityLabel(readOnlyReason)
        }
      }.onHover { isHovering = $0 }
    }
  }

#if os(iOS)
  private static let isTouchPlatform = true
#else
  private static let isTouchPlatform = false
#endif

  /// Leaf value: strings are `.primary` and one line until clicked open;
  /// every other scalar is `.blue` on one line, shrinking rather than
  /// wrapping (a 24-digit ObjectId broke mid-word in a narrow column).
  private var leafText: some View {
    let isString = row.bson.isString
    return Text(BSONSupport.displayString(row.bson)).font(.system(.body, design: .monospaced))
      .foregroundStyle(isString ? Color.primary : Color.blue)
      .lineLimit(isString && isExpanded ? nil : 1).truncationMode(.tail)
      .minimumScaleFactor(isString ? 1 : 0.6)
      .textSelection(.enabled).contentShape(Rectangle())
  }

  /// Installs only the recognizers this row needs. A double-tap recognizer
  /// makes every single tap wait out the double-click interval, so it is added
  /// only when the value is editable; strings keep click-to-expand either way.
  @ViewBuilder private func leafGestures(_ content: some View) -> some View {
    switch (canEditValue, row.bson.isString) {
    case (true, true):
      content.onTapGesture(count: 2) { onStartEdit() }.onTapGesture { onToggle(row.expansionKey) }
        .help("Click to expand, double-click to edit")
    case (true, false):
      content.onTapGesture(count: 2) { onStartEdit() }.help("Double-click to edit")
    case (false, true):
      content.onTapGesture { onToggle(row.expansionKey) }
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
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
          Label("Save", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).touchTarget(32)
        }.buttonStyle(.borderless).disabled(!isValid).help("Save (Return)")
        Button {
          cancel()
        } label: {
          Label("Cancel", systemImage: "xmark.circle").labelStyle(.iconOnly).touchTarget(32)
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
        .plainTextEntry()
        .invalidOutline(!isValid)
        .onSubmit { submit() }
        .onKeyPress(.escape) {
          cancel()
          return .handled
        }
#if os(macOS)
        .onExitCommand { cancel() }
#endif
        .frame(minWidth: horizontalSizeClass == .compact ? 120 : 220)
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
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
      if horizontalSizeClass == .compact {
        // Two lines on iPhone: in one row the Add button ended up off screen.
        HStack(spacing: 6) {
          keyField
          typePicker
        }
        HStack(spacing: 6) {
          valueControl
          addButton
        }
      } else {
        HStack(spacing: 6) {
          keyField.frame(width: 190)
          typePicker
          valueControl
          addButton
        }
      }
      if showsInvalid {
        Text(type.invalidMessage).font(.caption).foregroundStyle(.red)
      }
    }
  }

  private var keyField: some View {
    TextField("New field", text: $key, prompt: Text("New field")).textFieldStyle(.roundedBorder)
      .plainTextEntry()
  }

  private var typePicker: some View {
    Picker("Type", selection: $type) {
      ForEach(EditableType.allCases) { t in Text(t.label).tag(t) }
    }.labelsHidden().controlSize(.small).fixedSize()
  }

  private var addButton: some View {
    Button("Add") { add() }.disabled(trimmedKey.isEmpty || value == nil)
  }

  @ViewBuilder private var valueControl: some View {
    switch type {
    case .string, .integer, .number, .objectId:
      TextField("Value", text: $text).textFieldStyle(.roundedBorder)
        .frame(minWidth: horizontalSizeClass == .compact ? 100 : 140)
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

  /// Spoken/tooltip name of the value's type ("Integer", "Binary", …).
  var typeName: String {
    switch self {
    case .string: "String"
    case .int32: "32-bit integer"
    case .int64: "Integer"
    case .double: "Number"
    case .decimal128: "Decimal128"
    case .bool: "Boolean"
    case .objectID: "ObjectId"
    case .datetime: "Date"
    case .binary: "Binary"
    case .symbol: "Symbol"
    case .regex: "Regular expression"
    case .document: "Document"
    case .array: "Array"
    case .null: "Null"
    case .undefined: "Undefined"
    case .minKey: "MinKey"
    case .maxKey: "MaxKey"
    }
  }

  /// `{3}` for a document, `[2]` for an array.
  var containerSummary: String {
    switch self {
    case .document(let d): return "{\(d.count)}"
    case .array(let a): return "[\(a.count)]"
    default: return ""
    }
  }
}
