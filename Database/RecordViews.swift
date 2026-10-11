import Database
import MongoDB
import SwiftUI

// MARK: - Record details

/// One record laid out to be read: every field's name above its value in
/// plain words ("Yes", a local date, "Empty"), nested objects folded open
/// on demand. The pane's inspector on macOS/iPad, a sheet on iPhone.
struct RecordDetailView: View {
  @Environment(DatabaseModel.self) private var model
  let index: Int
  let onSelect: (Int) -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void
  let onUndo: () -> Void

  var body: some View {
    content.safeAreaInset(edge: .bottom) {
      // Repeated here: on iPhone this view is a sheet covering the pane's bar.
      if let change = model.lastChange { UndoBar(change: change, onUndo: onUndo) }
    }
  }

  @ViewBuilder private var content: some View {
    if model.documents.indices.contains(index) {
      let document = model.documents[index]
      List {
        Section {
          ForEach(Array(document.all.enumerated()), id: \.offset) { _, field in
            FieldDetailRow(name: field.key, value: field.value)
          }
        } header: {
          header(for: document)
        }
      }
      // At the top, so they stay visible in the half-height sheet on iPhone.
      .safeAreaInset(edge: .top, spacing: 0) { actions(for: document) }
    } else {
      ContentUnavailableView(
        "No \(model.itemNoun.singular.capitalized) Selected", systemImage: "doc.text",
        description: Text("Select a row to see all of its fields here."))
    }
  }

  private func header(for document: BSONDocument) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(RecordName.of(document) ?? "\(model.itemNoun.singular.capitalized) \(index + 1)")
          .font(.headline).foregroundStyle(.primary).textCase(nil)
        Text("\(index + 1) of \(model.documents.count)\(model.hasMore ? "+" : "")")
          .font(.caption).foregroundStyle(.secondary).textCase(nil)
      }
      Spacer()
      Button("Previous", systemImage: "chevron.up") { onSelect(index - 1) }
        .disabled(index == 0).keyboardShortcut(.upArrow, modifiers: .command)
      Button("Next", systemImage: "chevron.down") { onSelect(index + 1) }
        .disabled(index + 1 >= model.documents.count).keyboardShortcut(.downArrow, modifiers: .command)
    }
    .labelStyle(.iconOnly).buttonStyle(.borderless)
  }

  /// Edit/Delete, or why this record can't be changed.
  private func actions(for document: BSONDocument) -> some View {
    let blocker = model.editBlocker(forRecordAt: index)
    return VStack(alignment: .leading, spacing: 6) {
      if let blocker, !blocker.isEmpty {
        Label(blocker, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Group {
          Button("Edit…", systemImage: "pencil", action: onEdit)
          Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
        }.disabled(blocker != nil)
        Spacer()
        Menu {
          Button("Copy as JSON", systemImage: "curlybraces") {
            Clipboard.copy(JSONText.pretty(.document(document)))
          }
        } label: {
          Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }.menuStyle(.borderlessButton).fixedSize()
      }
    }
    .padding(10)
    .background(.bar)
  }
}

/// A field name over its readable value; documents and arrays fold open.
private struct FieldDetailRow: View {
  let name: String
  let value: BSON

  var body: some View {
    switch value {
    case .document(let document):
      DisclosureGroup {
        ForEach(Array(document.all.enumerated()), id: \.offset) { _, field in
          AnyView(FieldDetailRow(name: field.key, value: field.value))
        }
      } label: {
        labelled(Text(ReadableValue.text(value)).foregroundStyle(.secondary))
      }
    case .array(let items):
      DisclosureGroup {
        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
          AnyView(FieldDetailRow(name: "Item \(i + 1)", value: item))
        }
      } label: {
        labelled(Text(ReadableValue.text(value)).foregroundStyle(.secondary))
      }
    default:
      labelled(
        Text(ReadableValue.isBlank(value) && !value.isString ? "Empty" : displayText)
          .foregroundStyle(ReadableValue.isBlank(value) ? .secondary : .primary)
          .textSelection(.enabled)
      )
      .contextMenu {
        Button("Copy Value", systemImage: "doc.on.doc") { Clipboard.copy(BSONSupport.displayString(value)) }
      }
    }
  }

  private var displayText: String {
    if case .string(let text) = value, text.isEmpty { return "Empty text" }
    return ReadableValue.text(value)
  }

  private func labelled(_ valueView: some View) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name).font(.caption).foregroundStyle(.secondary)
      valueView
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Record editor

/// What the record editor sheet opens for.
struct RecordEditorTarget: Identifiable {
  enum Mode: Equatable {
    case edit(Int)
    case add
  }

  let id = UUID()
  let mode: Mode
}

/// Edits one record (or fills in a new one) as a form: one control per field
/// that suits its value (text, number, switch, date). Saving first shows what
/// will change, old value → new value, and only writes after a second click.
struct RecordEditorView: View {
  @Environment(DatabaseModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let target: RecordEditorTarget
  /// Field names/kinds of the loaded records (new records and empty values
  /// take their control type from these).
  let fields: [FieldInfo]

  @State private var drafts: [FieldDraft] = []
  @State private var isReviewing = false
  @State private var isSaving = false
  @State private var error: FriendlyError?
  @State private var newFieldName = ""

  private var isAdding: Bool { target.mode == .add }
  private var noun: String { model.itemNoun.singular }

  var body: some View {
    NavigationStack {
      Group {
        if isReviewing { review } else { form }
      }
      .navigationTitle(title)
#if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
#endif
      .toolbar { toolbar }
    }
#if os(macOS)
    .frame(minWidth: 480, idealWidth: 520, minHeight: 460, idealHeight: 560)
#endif
    .onAppear(perform: makeDrafts)
  }

  private var title: String {
    if isReviewing { return "Review" }
    return isAdding ? "New \(noun.capitalized)" : "Edit \(noun.capitalized)"
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      if isReviewing {
        Button("Back") {
          isReviewing = false
          error = nil
        }
      } else {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    ToolbarItem(placement: .confirmationAction) {
      if isReviewing {
        Button(confirmTitle) { save() }.keyboardShortcut(.defaultAction).disabled(isSaving)
      } else {
        Button("Review…") {
          error = nil
          isReviewing = true
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canReview)
      }
    }
  }

  private var confirmTitle: String {
    if isAdding { return "Add \(noun.capitalized)" }
    let count = changes.count
    return count == 1 ? "Save 1 Change" : "Save \(count) Changes"
  }

  // MARK: Form

  private var form: some View {
    Form {
#if os(macOS)
      Text(title).font(.headline).listRowBackground(Color.clear)
#endif
      Section {
        ForEach($drafts) { $draft in
          FieldDraftRow(draft: $draft, isAdding: isAdding)
        }
      } footer: {
        Text(formFooter).font(.footnote).foregroundStyle(.secondary)
      }
      if isAdding && model.activeEngine == .mongodb {
        Section("Another Field") {
          HStack {
            TextField("Field name", text: $newFieldName).plainTextEntry()
            Button("Add Field") { addCustomField() }
              .disabled(!canAddCustomField)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var formFooter: String {
    if isAdding {
      return "Leave a field empty to let the database fill it in, or to leave it out."
    }
    return "Nothing is saved until you review the changes and confirm them."
  }

  private var canAddCustomField: Bool {
    let name = newFieldName.trimmingCharacters(in: .whitespaces)
    return !name.isEmpty && !name.hasPrefix("$") && !name.contains(".")
      && !drafts.contains { $0.name == name }
  }

  private func addCustomField() {
    let name = newFieldName.trimmingCharacters(in: .whitespaces)
    drafts.append(FieldDraft(name: name, original: nil, type: .string, isKey: false))
    newFieldName = ""
  }

  // MARK: Review

  private var review: some View {
    Form {
#if os(macOS)
      Text(title).font(.headline).listRowBackground(Color.clear)
#endif
      Section {
        if isAdding {
          ForEach(Array(newValues.all.enumerated()), id: \.offset) { _, field in
            LabeledContent(field.key, value: ReadableValue.text(field.value))
          }
          if newValues.isEmpty {
            Text("All fields are empty, so the database fills in its defaults.")
              .foregroundStyle(.secondary)
          }
        } else {
          ForEach(Array(changes.all.enumerated()), id: \.offset) { _, field in
            ChangeRow(
              name: field.key, old: originalValue(of: field.key), new: field.value)
          }
        }
      } header: {
        Text(reviewHeader)
      } footer: {
        if !isAdding { Text("You can undo this right after saving.") }
      }
      if let error {
        Section { FriendlyErrorView(error: error) }
      }
    }
    .formStyle(.grouped)
  }

  private var reviewHeader: String {
    let place = model.selectedCollection.map { " in “\($0)”" } ?? ""
    if isAdding { return "A new \(noun)\(place) with:" }
    let name = recordIndex.flatMap { i in
      model.documents.indices.contains(i) ? RecordName.of(model.documents[i]) : nil
    }
    return "\(name.map { "“\($0)”" } ?? "This \(noun)")\(place) changes:"
  }

  // MARK: Values

  private var recordIndex: Int? {
    if case .edit(let index) = target.mode { return index }
    return nil
  }

  private func originalValue(of name: String) -> BSON? {
    drafts.first { $0.name == name }?.original
  }

  /// Every editable field whose value differs from what was loaded.
  private var changes: BSONDocument {
    var result = BSONDocument()
    for draft in drafts where draft.isEditable {
      guard let value = draft.value(isAdding: false) else { continue }
      if value != draft.original { result[draft.name] = value }
    }
    return result
  }

  /// The filled-in fields of a new record.
  private var newValues: BSONDocument {
    var result = BSONDocument()
    for draft in drafts {
      if let value = draft.value(isAdding: true) { result[draft.name] = value }
    }
    return result
  }

  private var canReview: Bool {
    guard drafts.allSatisfy({ $0.isValid(isAdding: isAdding) }) else { return false }
    return isAdding || !changes.isEmpty
  }

  private func makeDrafts() {
    guard drafts.isEmpty else { return }
    let kinds = Dictionary(fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    switch target.mode {
    case .edit(let index):
      guard model.documents.indices.contains(index) else { return }
      let document = model.documents[index]
      let key = model.recordKey(of: document) ?? BSONDocument()
      drafts = document.all.map { field in
        FieldDraft(
          name: field.key, original: field.value,
          type: FieldDraft.type(for: field.value, info: kinds[field.key]),
          isKey: key[field.key] != nil)
      }
    case .add:
      let keyColumns: [String] =
        if case .editable(let key) = model.recordAccess { key } else { [] }
      drafts = fields.filter { !(model.activeEngine == .mongodb && $0.name == "_id") }.map { info in
        FieldDraft(
          name: info.name, original: nil, type: FieldDraft.type(for: nil, info: info),
          isKey: keyColumns.contains(info.name))
      }
    }
  }

  private func save() {
    isSaving = true
    Task {
      defer { isSaving = false }
      do {
        if let index = recordIndex {
          try await model.saveRecord(at: index, changes: changes)
        } else {
          try await model.insertRecord(newValues)
        }
        dismiss()
      } catch {
        self.error = FriendlyError(error, while: .saving)
      }
    }
  }
}

/// "rating   4 → 5" in the review step.
private struct ChangeRow: View {
  let name: String
  let old: BSON?
  let new: BSON

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name).font(.caption).foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(old.map { ReadableValue.text($0) } ?? "Not set").strikethrough().foregroundStyle(.secondary)
        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
          .accessibilityLabel("becomes")
        Text(ReadableValue.text(new)).fontWeight(.medium)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// The working value of one field in the record editor.
struct FieldDraft: Identifiable {
  let name: String
  let original: BSON?
  var type: EditableType
  let isKey: Bool
  var text = ""
  var date = Date()
  var bool = false
  var id: String { name }

  init(name: String, original: BSON?, type: EditableType, isKey: Bool) {
    self.name = name
    self.original = original
    self.type = type
    self.isKey = isKey
    switch original {
    case .string(let s): text = s
    case .int32(let i): text = String(i)
    case .int64(let i): text = String(i)
    case .double(let d): text = ReadableValue.text(.double(d))
    case .bool(let b): bool = b
    case .datetime(let d): date = d
    case .objectID(let id): text = id.hex
    default: break
    }
  }

  /// Key fields find the record and can't change; values without an editor
  /// here (nested objects, binary…) are shown but left alone.
  var isEditable: Bool {
    guard !isKey else { return false }
    guard let original else { return true }
    return EditableType.canEdit(original)
  }

  /// The control type for a value, or for a new/empty value the kind seen
  /// in the other loaded records.
  static func type(for value: BSON?, info: FieldInfo?) -> EditableType {
    if let value, !ReadableValue.isBlank(value) || value.isString { return EditableType.matching(value) }
    switch info?.kind {
    case .number:
      let allIntegers = info?.values.allSatisfy {
        if case .int32 = $0 { true } else if case .int64 = $0 { true } else { false }
      } ?? false
      return allIntegers ? .integer : .number
    case .boolean: return .boolean
    case .date: return .date
    case .objectID: return .objectId
    default: return .string
    }
  }

  /// The value to write. Adding: an empty text field means "leave it out"
  /// (nil). Editing: a cleared value is stored as empty (null).
  func value(isAdding: Bool) -> BSON? {
    if isAdding && type.usesTextField && text.trimmingCharacters(in: .whitespaces).isEmpty {
      return nil
    }
    let value = type.value(text: text, date: date, bool: bool)
    // An int32 stays int32 when the new number still fits.
    if case .int32? = original, case .int64(let n)? = value, let small = Int32(exactly: n) {
      return .int32(small)
    }
    return value
  }

  func isValid(isAdding: Bool) -> Bool {
    guard isEditable || isAdding, type.usesTextField else { return true }
    if isAdding && text.trimmingCharacters(in: .whitespaces).isEmpty { return true }
    return type.value(text: text, date: date, bool: bool) != nil
  }
}

/// One field of the record editor: its name, a control for its type, and a
/// menu to empty it (or give an empty field a value).
private struct FieldDraftRow: View {
  @Binding var draft: FieldDraft
  let isAdding: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(draft.name).font(.subheadline.weight(.medium))
        if draft.isKey {
          Image(systemName: "key.fill").font(.caption).foregroundStyle(.secondary)
            .help("Identifies this record")
            .accessibilityLabel("Key field")
        }
        Spacer()
        if draft.isEditable && !isAdding { emptyMenu }
      }
      control
      if !draft.isValid(isAdding: isAdding) {
        Text(draft.type.invalidMessage).font(.caption).foregroundStyle(.red)
      } else if let note {
        Text(note).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }

  private var note: String? {
    if draft.isKey && !isAdding { return "Identifies this record, so it can’t be changed." }
    if draft.isKey && isAdding { return "Leave empty to have the database number it." }
    if !draft.isEditable { return "This kind of value can’t be edited here." }
    return nil
  }

  @ViewBuilder private var control: some View {
    if !draft.isEditable && !isAdding {
      Text(draft.original.map { ReadableValue.text($0) } ?? "").foregroundStyle(.secondary)
        .textSelection(.enabled)
    } else {
      switch draft.type {
      case .string:
        TextField(draft.name, text: $draft.text, prompt: Text(isAdding ? "Empty" : ""), axis: .vertical)
          .labelsHidden().lineLimit(1...6).textFieldStyle(.roundedBorder)
      case .integer, .number, .objectId:
        TextField(draft.name, text: $draft.text, prompt: Text(prompt)).labelsHidden()
          .textFieldStyle(.roundedBorder).plainTextEntry()
          .invalidOutline(!draft.isValid(isAdding: isAdding))
#if os(iOS)
          .keyboardType(draft.type == .integer ? .numberPad : draft.type == .number ? .decimalPad : .default)
#endif
      case .boolean:
        Picker(draft.name, selection: $draft.bool) {
          Text("Yes").tag(true)
          Text("No").tag(false)
        }.labelsHidden().pickerStyle(.segmented).fixedSize()
      case .date:
        DatePicker(draft.name, selection: $draft.date, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
      case .null:
        Text("Empty").foregroundStyle(.secondary)
      }
    }
  }

  private var prompt: String {
    switch draft.type {
    case .integer: isAdding ? "Empty" : "Whole number"
    case .number: isAdding ? "Empty" : "Number"
    default: isAdding ? "Empty" : ""
    }
  }

  /// "Make Empty" stores null; an empty field gets back a control of the
  /// type its column usually holds.
  private var emptyMenu: some View {
    Menu {
      if draft.type == .null {
        ForEach([EditableType.string, .integer, .number, .boolean, .date], id: \.self) { type in
          Button("Enter \(type.plainName)") { draft.type = type }
        }
      } else {
        Button("Make Empty", systemImage: "xmark.circle") { draft.type = .null }
      }
    } label: {
      Label("Options for \(draft.name)", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
  }
}

extension EditableType {
  /// "a Number" etc. for the record editor's menus.
  var plainName: String {
    switch self {
    case .string: "Text"
    case .integer: "a Whole Number"
    case .number: "a Number"
    case .boolean: "Yes or No"
    case .date: "a Date"
    case .null: "Nothing"
    case .objectId: "an ObjectId"
    }
  }
}

// MARK: - Errors

/// A plain-language error: what happened, what to try, and the original
/// message folded away under Details. A missing-encryption error also
/// offers Database Pro, once it exists.
struct FriendlyErrorView: View {
  let error: FriendlyError

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(error.title, systemImage: "exclamationmark.triangle.fill")
        .font(.headline).foregroundStyle(.red)
      if !error.message.isEmpty && error.message != error.title {
        Text(error.message).fixedSize(horizontal: false, vertical: true)
      }
      if let suggestion = error.suggestion {
        Text(suggestion).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if error.requiresEncryption { UpgradeButton() }
      if !error.detailsRepeatMessage {
        DisclosureGroup("Details") {
          Text(error.details).font(.caption.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
      }
    }
  }
}

/// "Get Database Pro" — nothing until `EncryptionNotice.upgradeURL` is set.
struct UpgradeButton: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    if let url = EncryptionNotice.upgradeURL {
      Button("Get \(EncryptionNotice.upgradeName)…") { openURL(url) }
        .buttonStyle(.borderless)
    }
  }
}

/// The missing-encryption notice shown before connecting, when the form
/// points at a server that requires encryption.
struct EncryptionNoticeView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(EncryptionNotice.title, systemImage: "lock.trianglebadge.exclamationmark")
        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
      Text(EncryptionNotice.message).font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      UpgradeButton()
    }
  }
}
