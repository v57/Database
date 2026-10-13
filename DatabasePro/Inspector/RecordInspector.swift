import DatabaseProKit
import SwiftUI

/// A table row's fields, related rows and actions; Edit turns the fields into editors.
struct RecordInspector: View {
  let browser: BrowserModel
  let record: Record
  @Bindable var window: WindowModel
  let onDelete: () -> Void
  @State private var editing = false
  @State private var drafts: [String: FieldDraft] = [:]
  @State private var errors: [String: String] = [:]
  @State private var relations: [Relation] = []
  @State private var relatedCounts: [String: Int] = [:]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if editing {
          editor
        } else {
          fieldList
          related
          actions
        }
      }
      .padding(16)
    }
    .task(id: record.id) {
      editing = false
      await loadRelations()
    }
    .onChange(of: browser.editRequest) { _, id in
      if id == record.id, browser.isEditable, record.key != nil { startEditing() }
      browser.editRequest = nil
    }
    .onAppear {
      if browser.editRequest == record.id, browser.isEditable, record.key != nil { startEditing() }
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(browser.title(for: record)).font(.title3.bold()).lineLimit(2)
        Text("\(browser.noun.capitalized) in \(browser.ref.name) · \(browser.fields.count) fields")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if editing {
        Button("Cancel") { editing = false }.buttonStyle(.bordered)
        Button("Done") { finishEditing() }.buttonStyle(.borderedProminent)
      } else if browser.isEditable && record.key != nil {
        Button("Edit") { startEditing() }.buttonStyle(.bordered)
      }
    }
  }

  private var fieldList: some View {
    VStack(spacing: 0) {
      ForEach(Array(browser.fields.enumerated()), id: \.element.id) { index, field in
        if index > 0 { Divider().padding(.leading, 12) }
        FieldRow(browser: browser, record: record, field: field, window: window)
      }
    }
    .groupBox()
  }

  // MARK: Related

  @ViewBuilder private var related: some View {
    let incoming = relations.filter { $0.direction == .incoming }
    if !incoming.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Related").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
        VStack(spacing: 0) {
          ForEach(Array(incoming.enumerated()), id: \.element.id) { index, relation in
            if index > 0 { Divider().padding(.leading, 12) }
            Button {
              openRelated(relation)
            } label: {
              HStack {
                Text(relation.table.name)
                Spacer()
                if let count = relatedCounts[relation.id] {
                  Text(count == 0 ? "None" : "\(count) \(count == 1 ? "row" : "rows")").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 9)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .groupBox()
      }
    }
  }

  private func loadRelations() async {
    guard let session = browser.session else { return }
    relations = (try? await session.relations(of: browser.ref)) ?? []
    relatedCounts = [:]
    for relation in relations where relation.direction == .incoming {
      guard let value = record[relation.column], !value.isNull else { continue }
      var request = BrowseRequest(ref: relation.table)
      request.filters = [Filter(field: relation.otherColumn, op: .equals, value: value.editingText)]
      relatedCounts[relation.id] = try? await session.count(request)
    }
  }

  private func openRelated(_ relation: Relation) {
    guard let value = record[relation.column] else { return }
    let target = browser.connection.browser(for: relation.table)
    target.request.filters = [Filter(field: relation.otherColumn, op: .equals, value: value.editingText)]
    window.open(relation.table, in: browser.connection.id)
    Task { await target.reload() }
  }

  @ViewBuilder private var copyButtons: some View {
    Button("Copy as JSON", systemImage: "doc.on.doc") { Clipboard.copy(Exporter.json(record, fields: browser.fields)) }
      .lineLimit(1)
    Button("Copy as INSERT") { Clipboard.copy(Exporter.insert(record, browser: browser)) }
      .lineLimit(1)
  }
  private var actions: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Side by side when they fit; stacked in a narrow inspector.
      ViewThatFits(in: .horizontal) {
        HStack { copyButtons }
        VStack(alignment: .leading, spacing: 8) { copyButtons }
      }
      .buttonStyle(.bordered)
      if browser.isEditable && record.key != nil {
        Button("Delete \(browser.noun.capitalized)…", systemImage: "trash", role: .destructive, action: onDelete)
          .buttonStyle(.bordered)
          .foregroundStyle(.red)
      }
      if record.key == nil && browser.ref.kind == .table {
        Label("This table has no primary key, so its rows can't be changed here.", systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if browser.connection.profile.isReadOnly {
        Label("Read-only connection.", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Editing

  private var editor: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(browser.fields) { field in
        FieldEditorRow(field: field, draft: binding(for: field), error: errors[field.name], locked: isLocked(field))
      }
      Label("Key fields can't be changed. You'll review every change before it's saved.", systemImage: "info.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func isLocked(_ field: FieldInfo) -> Bool {
    field.isPrimaryKey || field.isGenerated || field.keyRole != nil
  }

  private func binding(for field: FieldInfo) -> Binding<FieldDraft> {
    Binding(get: { drafts[field.name] ?? FieldDraft(value: record[field.name] ?? .null) }, set: { drafts[field.name] = $0 })
  }

  private func startEditing() {
    drafts = [:]
    for field in browser.fields {
      let current = browser.pendingValue(for: record, field: field.name) ?? record[field.name] ?? .null
      drafts[field.name] = FieldDraft(value: current)
    }
    errors = [:]
    editing = true
  }

  private func finishEditing() {
    guard let session = browser.session else { return }
    var changes: [FieldChange] = []
    errors = [:]
    for field in browser.fields where !isLocked(field) {
      guard let draft = drafts[field.name], draft.changed(from: record[field.name] ?? .null) else { continue }
      do {
        let value = try session.parseInput(draft.text, isNull: draft.isNull, for: field)
        changes.append(FieldChange(field: field.name, old: record[field.name] ?? .null, new: value))
      } catch {
        errors[field.name] = FriendlyError.message(error)
      }
    }
    guard errors.isEmpty else { return }
    if !changes.isEmpty {
      browser.stage(RecordEdit(ref: browser.ref, key: record.key, kind: .update(changes), title: browser.title(for: record)))
    }
    editing = false
  }
}

/// One read-only field: name, key badge, value; foreign keys link to their row.
struct FieldRow: View {
  let browser: BrowserModel
  let record: Record
  let field: FieldInfo
  @Bindable var window: WindowModel

  var body: some View {
    let pending = browser.pendingValue(for: record, field: field.name)
    let value = pending ?? record[field.name] ?? .null
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      HStack(spacing: 5) {
        Text(field.name).foregroundStyle(.secondary)
        if field.isPrimaryKey || field.keyRole != nil {
          TagLabel(text: field.keyRole == .partition ? "Partition key" : field.keyRole == .clustering ? "Clustering" : "Key", color: .brown, systemImage: "key.fill")
        }
      }
      .help(field.typeName)
      Spacer(minLength: 8)
      Group {
        if value.isNull {
          Text("empty").italic().foregroundStyle(.tertiary)
        } else if let reference = field.references {
          Button {
            let target = browser.connection.browser(for: reference.target)
            target.request.filters = [Filter(field: reference.column, op: .equals, value: value.editingText)]
            window.open(reference.target, in: browser.connection.id)
            Task { await target.reload() }
          } label: {
            HStack(spacing: 3) {
              Text(value.displayText)
              Image(systemName: "arrow.up.right").imageScale(.small)
            }
          }
          .linkButtonStyle()
          .help("Open \(reference.target.name)")
        } else if field.category == .text, let color = StatusPill.color(for: value.displayText),
          field.name.contains("status") || field.name.contains("state")
        {
          TagLabel(text: value.displayText, color: color)
        } else {
          Text(value.fullText.count > 200 ? value.displayText : value.fullText)
            .font(field.category == .json || field.category == .document || field.category == .uuid ? .codeSmall : .body)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .lineLimit(6)
        }
      }
      .padding(.horizontal, pending != nil ? 4 : 0)
      .background(pending != nil ? Color.orange.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

/// An editor's working copy of one field.
struct FieldDraft: Equatable {
  var text: String
  var isNull: Bool
  var typeName: String?

  init(value: CellValue, typeName: String? = nil) {
    text = value.editingText
    isNull = value.isNull
    self.typeName = typeName ?? value.typeBadge
  }

  func changed(from original: CellValue) -> Bool {
    if isNull != original.isNull { return true }
    if isNull { return false }
    return text != original.editingText || (typeName != nil && typeName != original.typeBadge)
  }
}

/// A typed editor for one field.
struct FieldEditorRow: View {
  let field: FieldInfo
  @Binding var draft: FieldDraft
  var error: String?
  var locked: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(field.name).font(.callout.weight(.medium))
        Text(field.typeName).font(.caption).foregroundStyle(.tertiary)
        Spacer()
        if field.isNullable && !locked {
          Toggle("Empty", isOn: $draft.isNull)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("Store NULL")
        }
      }
      Group {
        if locked {
          Text(draft.isNull ? "empty" : draft.text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        } else if field.category == .boolean {
          Picker(field.name, selection: $draft.text) {
            Text("true").tag("true")
            Text("false").tag("false")
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .disabled(draft.isNull)
        } else if [.json, .document, .list].contains(field.category) || draft.text.count > 60 || draft.text.contains("\n") {
          TextEditor(text: $draft.text)
            .font(.code)
            .frame(minHeight: 70, maxHeight: 200)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .disabled(draft.isNull)
        } else {
          TextField(field.name, text: $draft.text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .disabled(draft.isNull)
        }
      }
      if let error {
        Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
      }
    }
  }

  private var prompt: String {
    switch field.category {
    case .date: "2026-10-12"
    case .dateTime: "2026-10-12 10:02:00"
    case .time: "10:02:00"
    case .uuid: "UUID"
    case .binary: "0xDEAD"
    case .integer, .decimal, .float: "0"
    default: ""
    }
  }
}

struct MultiSelectionInspector: View {
  let browser: BrowserModel
  let onDelete: ([Record]) -> Void

  var body: some View {
    let records = browser.selectedRecords
    VStack(spacing: 14) {
      Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(.secondary)
      Text("\(browser.noun.count(records.count)) selected").font(.headline)
      Button("Copy as JSON", systemImage: "doc.on.doc") {
        Clipboard.copy("[\n" + records.map { Exporter.json($0, fields: browser.fields) }.joined(separator: ",\n") + "\n]")
      }
      .buttonStyle(.bordered)
      if browser.isEditable {
        Button("Delete \(browser.noun.count(records.count))…", systemImage: "trash", role: .destructive) { onDelete(records) }
          .buttonStyle(.bordered)
          .foregroundStyle(.red)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

/// iPhone: one item on its own screen, with Edit.
struct RecordDetailScreen: View {
  let browser: BrowserModel
  let record: Record
  @Bindable var window: WindowModel
  @State private var deleting = false

  var body: some View {
    Group {
      if browser.engine.family == .document {
        DocumentInspector(browser: browser, record: record, onDelete: { deleting = true })
      } else {
        RecordInspector(browser: browser, record: record, window: window, onDelete: { deleting = true })
      }
    }
    .navigationTitle(browser.title(for: record))
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .confirmationDialog("Delete this \(browser.noun.singular)?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Add to Changes", role: .destructive) {
        browser.stageDelete([record])
        browser.showsReview = true
      }
    }
    .sheet(isPresented: Binding(get: { browser.showsReview }, set: { browser.showsReview = $0 })) {
      ReviewSheet(browser: browser).appButtonShape()
    }
  }
}

/// A new row or document, staged for review like any change.
struct NewItemSheet: View {
  let browser: BrowserModel
  @Environment(\.dismiss) private var dismiss
  @State private var drafts: [String: FieldDraft] = [:]
  @State private var errors: [String: String] = [:]
  @State private var documentText = "{\n  \n}"
  @State private var documentError: String?

  var body: some View {
    NavigationStack {
      Form {
        if browser.engine.family == .document {
          Section {
            CodeEditor(text: $documentText, language: EngineKind.mongodb.highlighting, completions: [])
              .frame(minHeight: 220)
            if let documentError {
              Label(documentError, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.caption)
            }
          } footer: {
            Text("Write the document in MongoDB Shell syntax, e.g. { name: \"Lamp\", price: 59.0 }. An _id is added if you leave it out.")
          }
        } else {
          ForEach(browser.fields.filter { !$0.isGenerated }) { field in
            FieldEditorRow(field: field, draft: binding(field), error: errors[field.name], locked: false)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Add \(browser.noun.capitalized)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Add to Changes", action: add) }
      }
    }
    .frame(minWidth: 460, minHeight: 420)
    .onAppear {
      if browser.engine.family == .document, let sample = browser.fields.filter({ $0.name != "_id" }).first {
        documentText = "{\n  \(sample.name): \n}"
      }
    }
  }

  private func binding(_ field: FieldInfo) -> Binding<FieldDraft> {
    Binding(
      get: { drafts[field.name] ?? FieldDraft(value: field.isNullable && field.defaultValue != nil ? .null : .db(.text(""))) },
      set: { drafts[field.name] = $0 })
  }

  private func add() {
    guard let session = browser.session else { return }
    if browser.engine.family == .document {
      do {
        let doc = try BSONDocument(parsing: documentText)
        var values: [String: CellValue] = [:]
        for (key, value) in doc { values[key] = .bson(value) }
        browser.stage(RecordEdit(ref: browser.ref, key: nil, kind: .insert(values), title: "New document"))
        browser.showsReview = true
        dismiss()
      } catch {
        documentError = FriendlyError.message(error)
      }
      return
    }
    var values: [String: CellValue] = [:]
    errors = [:]
    for field in browser.fields where !field.isGenerated {
      let draft = drafts[field.name] ?? FieldDraft(value: .db(.text("")))
      // Leave untouched optional fields to their defaults.
      if draft.text.isEmpty && !draft.isNull && (field.isNullable || field.defaultValue != nil) { continue }
      do {
        values[field.name] = try session.parseInput(draft.text, isNull: draft.isNull, for: field)
      } catch {
        errors[field.name] = FriendlyError.message(error)
      }
    }
    guard errors.isEmpty else { return }
    let title = "New \(browser.noun.singular)" + (values.first { $0.key.contains("name") }.map { " · \($0.value.displayText)" } ?? "")
    browser.stage(RecordEdit(ref: browser.ref, key: nil, kind: .insert(values), title: title))
    browser.showsReview = true
    dismiss()
  }
}

extension View {
  /// The grouped, rounded container used for field lists.
  func groupBox() -> some View {
    background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
  }
}

#if os(iOS)
  extension ToggleStyle where Self == SwitchToggleStyle {
    static var checkbox: SwitchToggleStyle { .switch }
  }
#endif
