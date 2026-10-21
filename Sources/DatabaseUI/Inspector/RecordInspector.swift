import ComponentKit
import DatabaseKit
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
    KitInspector(width: nil) {
      InspectorHeader(
        browser.title(for: record), meta: ["\(browser.noun.capitalized) in \(browser.ref.name)", "\(browser.fields.count) fields"],
        systemImage: browser.ref.symbol, hue: browser.engine.hue)
      if editing {
        editor
      } else {
        KitSection("Fields", meta: "\(browser.fields.count) fields", systemImage: browser.ref.symbol, hue: browser.engine.hue) {
          ForEach(browser.fields) { field in
            FieldRow(browser: browser, record: record, field: field, window: window)
          }
        }
        related
        actions
        note
      }
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

  // MARK: Related

  @ViewBuilder private var related: some View {
    let incoming = relations.filter { $0.direction == .incoming }
    if !incoming.isEmpty {
      KitSection("Related", meta: "\(incoming.count) \(incoming.count == 1 ? "table" : "tables")", systemImage: "link", hue: .teal) {
        ForEach(incoming) { relation in
          Button {
            openRelated(relation)
          } label: {
            InspectorRow(relation.table.name) {
              HStack(spacing: 4) {
                if let count = relatedCounts[relation.id] {
                  Text(count == 0 ? "None" : "\(count) \(count == 1 ? "row" : "rows")")
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.kitTertiary)
              }
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private func loadRelations() async {
    guard let session = browser.session else { return }
    Activity.begin()
    defer { Activity.end() }
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

  private var actions: some View {
    ActionBar {
      if browser.isEditable && record.key != nil {
        Button("Edit") { startEditing() }
      }
      Button("Copy as JSON") { KitPasteboard.copy(Exporter.json(record, fields: browser.fields)) }
      Button("Copy as INSERT") { KitPasteboard.copy(Exporter.insert(record, browser: browser)) }
      if browser.isEditable && record.key != nil {
        Button("Delete \(browser.noun.capitalized)…", systemImage: "trash", role: .destructive, action: onDelete)
          .labelStyle(.iconOnly)
      }
    }
  }

  @ViewBuilder private var note: some View {
    if record.key == nil && browser.ref.kind == .table {
      InspectorNote("This table has no primary key, so its rows can't be changed here.")
    } else if browser.connection.profile.isReadOnly {
      InspectorNote("Read-only connection.", systemImage: "lock")
    }
  }

  // MARK: Editing

  private var editor: some View {
    Group {
      KitSection("Edit", meta: "\(browser.fields.count) fields", systemImage: "pencil", hue: .orange) {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(browser.fields) { field in
            FieldEditorRow(field: field, draft: binding(for: field), error: errors[field.name], locked: isLocked(field))
          }
        }
        .padding(6)
      }
      ActionBar {
        Button("Cancel") { editing = false }
        Button("Done") { finishEditing() }
          .keyboardShortcut(.defaultAction)
      }
      InspectorNote("Key fields can't be changed. You'll review every change before it's saved.")
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

/// One read-only field: name, key chip, value; foreign keys link to their row.
struct FieldRow: View {
  let browser: BrowserModel
  let record: Record
  let field: FieldInfo
  @Bindable var window: WindowModel

  var body: some View {
    let pending = browser.pendingValue(for: record, field: field.name)
    let value = pending ?? record[field.name] ?? .null
    InspectorRow(field.name, copyText: value.isNull ? nil : value.fullText) {
      HStack(spacing: 6) {
        if field.isPrimaryKey || field.keyRole != nil {
          Chip(
            field.keyRole == .partition ? "Partition key" : field.keyRole == .clustering ? "Clustering" : "Key",
            systemImage: "key", hue: .brown
          )
          .controlSize(.small)
        }
        Spacer(minLength: 0)
        Group {
          if value.isNull {
            Chip(Text("NULL").monospaced(), style: .quiet).controlSize(.small)
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
            .buttonStyle(.plain)
            .foregroundStyle(Hue.accent.text)
            .accessibilityHint("Opens \(reference.target.name)")
          } else if field.isStatus {
            Chip(status: value.displayText)
          } else {
            Text(value.displayText)
              .kitFont(field.isMono ? .mono : .body)
          }
        }
        .padding(.horizontal, pending != nil ? 4 : 0)
        .background(pending != nil ? AnyShapeStyle(Hue.orange.soft()) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: KitMetrics.radiusXS))
      }
    }
  }
}

/// A quiet note under an inspector's cards.
struct InspectorNote: View {
  let text: String
  var systemImage = "info.circle"

  init(_ text: String, systemImage: String = "info.circle") {
    self.text = text
    self.systemImage = systemImage
  }

  var body: some View {
    Label(text, systemImage: systemImage)
      .kitFont(.caption)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)
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
      HStack(spacing: 6) {
        Text(field.name).kitFont(.headline)
        Chip(type: field.typeName).controlSize(.small)
        Spacer()
        if field.isNullable && !locked {
          Toggle("Empty", isOn: $draft.isNull)
            .toggleStyle(.kitCheckbox)
            .kitFont(.caption)
            .accessibilityHint("Store NULL")
        }
      }
      Group {
        if locked {
          Text(draft.isNull ? "empty" : draft.text)
            .foregroundStyle(.kitSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(minHeight: KitMetrics.controlRegular)
            .background(.kitFillSoft, in: RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
        } else if field.category == .boolean {
          KitSegmented(selection: $draft.text, options: [("true", "true"), ("false", "false")])
            .kitSegmentedStyle(.wide)
            .disabled(draft.isNull)
        } else if [.json, .document, .list].contains(field.category) || draft.text.count > 60 || draft.text.contains("\n") {
          TextEditor(text: $draft.text)
            .kitFont(.mono)
            .frame(minHeight: 70, maxHeight: 200)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.kitField, in: RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
            .disabled(draft.isNull)
        } else {
          TextField(field.name, text: $draft.text, prompt: Text(prompt))
            .kitField(status: error == nil ? .none : .error, mono: field.isMono)
            .disabled(draft.isNull)
        }
      }
      .kitFieldError(error)
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
    KitInspector(width: nil) {
      InspectorHeader(
        "\(browser.noun.count(records.count)) selected", meta: ["In \(browser.ref.name)"],
        systemImage: "square.stack.3d.up", hue: browser.engine.hue)
      ActionBar {
        Button("Copy as JSON") {
          KitPasteboard.copy("[\n" + records.map { Exporter.json($0, fields: browser.fields) }.joined(separator: ",\n") + "\n]")
        }
        if browser.isEditable {
          Button("Delete \(browser.noun.count(records.count))…", systemImage: "trash", role: .destructive) { onDelete(records) }
            .labelStyle(.iconOnly)
        }
      }
    }
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
    .kitConfirmation(
      "Delete this \(browser.noun.singular)?", isPresented: $deleting,
      message: "You'll see the change before anything is deleted.", systemImage: "trash", confirm: "Add to Changes"
    ) {
      browser.stageDelete([record])
      browser.showsReview = true
    }
    .sheet(isPresented: Binding(get: { browser.showsReview }, set: { browser.showsReview = $0 })) {
      ReviewSheet(browser: browser).componentKit(accent: .databaseAccent)
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
    KitSheet(
      title: "Add \(browser.noun.capitalized)",
      meta: "In \(browser.ref.name). It joins the changes you review before saving.",
      systemImage: "plus", hue: browser.engine.hue, width: 520
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if browser.engine.family == .document {
            CodeEditor(text: $documentText, language: EngineKind.mongodb.highlighting, completions: [])
              .frame(minHeight: 220)
              .background(.kitField, in: RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
              .clipShape(RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
              .kitFieldError(documentError)
            Text("Write the document in MongoDB Shell syntax, e.g. { name: \"Lamp\", price: 59.0 }. An _id is added if you leave it out.")
              .kitFont(.caption)
          } else {
            ForEach(browser.fields.filter { !$0.isGenerated }) { field in
              FieldEditorRow(field: field, draft: binding(field), error: errors[field.name], locked: false)
            }
          }
        }
        .padding(12)
      }
      .frame(minHeight: 260, maxHeight: 520)
      .kitSurface(.card)
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Add to Changes", action: add)
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
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


