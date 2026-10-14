import DatabaseKit
import SwiftUI

/// A document as a tree of typed fields; Edit gives each top-level field a type and a value.
struct DocumentInspector: View {
  let browser: BrowserModel
  let record: Record
  let onDelete: () -> Void
  @State private var editing = false
  @State private var rows: [EditableField] = []
  @State private var errors: [UUID: String] = [:]

  struct EditableField: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var type: String
    var text: String
    var original: CellValue?
  }

  private var document: BSONDocument {
    record.document ?? BSONDocument(record.values.compactMap { key, value in value.bsonValue.map { (key, $0) } })
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        if editing {
          editor
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(document.elements, id: \.key) { element in
              BSONTreeRow(key: element.key, value: element.value, level: 0, pending: browser.pendingValue(for: record, field: element.key))
            }
          }
          .padding(.vertical, 4)
          .groupBox()
          actions
        }
      }
      .padding(16)
    }
    .task(id: record.id) { editing = false }
    .onChange(of: browser.editRequest) { _, id in
      if id == record.id, browser.isEditable { startEditing() }
      browser.editRequest = nil
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(browser.displayName(for: record) ?? "Document").font(.title3.bold()).lineLimit(2)
        Text("Document in \(browser.ref.name) · \(document.count) fields").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if editing {
        Button("Cancel") { editing = false }.buttonStyle(.bordered)
        Button("Done", action: finishEditing).buttonStyle(.borderedProminent)
      } else if browser.isEditable && record.key != nil {
        Button("Edit", action: startEditing).buttonStyle(.bordered)
      }
    }
  }

  private var actions: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button("Copy as JSON", systemImage: "doc.on.doc") { Clipboard.copy(document.text(.extendedJSON, indent: 2)) }
        .buttonStyle(.bordered)
      if browser.isEditable && record.key != nil {
        Button("Delete Document…", systemImage: "trash", role: .destructive, action: onDelete)
          .buttonStyle(.bordered)
          .foregroundStyle(.red)
      }
      Label("_id can't be changed. Every other field is editable, and you see the change before it's saved.", systemImage: "info.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Editing

  private var editor: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach($rows) { $row in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            if row.name == "_id" {
              Text(row.name).font(.callout.weight(.medium))
            } else {
              TextField("Field", text: $row.name)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .frame(maxWidth: 160)
            }
            Picker("Type", selection: $row.type) {
              ForEach(documentFieldTypes, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(row.name == "_id")
            Spacer()
            if row.name != "_id" {
              Button("Remove \(row.name)", systemImage: "minus.circle.fill") { rows.removeAll { $0.id == row.id } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
          }
          if row.name == "_id" {
            Text(row.text).font(.codeSmall).foregroundStyle(.secondary)
          } else if row.type == "Boolean" {
            Picker("Value", selection: $row.text) {
              Text("true").tag("true")
              Text("false").tag("false")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
          } else if row.type == "Null" {
            Text("null").italic().foregroundStyle(.secondary)
          } else if ["Object", "Array"].contains(row.type) || !documentFieldTypes.contains(row.type) || row.text.contains("\n") {
            TextEditor(text: $row.text)
              .font(.code)
              .frame(minHeight: 60, maxHeight: 220)
              .scrollContentBackground(.hidden)
              .padding(4)
              .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
          } else {
            TextField("Value", text: $row.text, prompt: Text(row.type == "Date" ? "2026-10-12T10:02:00Z" : ""))
              .textFieldStyle(.roundedBorder)
              .font(row.type == "String" ? .body : .code)
          }
          if let error = errors[row.id] {
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
          }
        }
        .padding(10)
        .groupBox()
      }
      Button("Add Field", systemImage: "plus") {
        rows.append(EditableField(name: "", type: "String", text: "", original: nil))
      }
      .buttonStyle(DashedCapsuleStyle())
    }
  }

  private func startEditing() {
    rows = document.elements.map { element in
      let value = browser.pendingValue(for: record, field: element.key) ?? .bson(element.value)
      return EditableField(
        name: element.key, type: value.typeBadge ?? "String", text: value.editingText, original: .bson(element.value))
    }
    errors = [:]
    editing = true
  }

  private func finishEditing() {
    guard let session = browser.session else { return }
    var changes: [FieldChange] = []
    errors = [:]
    var seen: Set<String> = []
    for row in rows where row.name != "_id" {
      let name = row.name.trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else {
        errors[row.id] = "Give the field a name."
        continue
      }
      seen.insert(name)
      let field = FieldInfo(name: name, typeName: row.type)
      do {
        let value = try session.parseInput(row.text, isNull: row.type == "Null", for: field)
        let old = record[name] ?? .unset
        if value != old { changes.append(FieldChange(field: name, old: old, new: value)) }
      } catch {
        errors[row.id] = FriendlyError.message(error)
      }
    }
    // Fields that were removed.
    for key in document.keys where key != "_id" && !seen.contains(key) {
      changes.append(FieldChange(field: key, old: record[key] ?? .unset, new: .unset))
    }
    guard errors.isEmpty else { return }
    if !changes.isEmpty {
      browser.stage(RecordEdit(ref: browser.ref, key: record.key, kind: .update(changes), title: browser.title(for: record)))
    }
    editing = false
  }
}

/// One BSON field with its type badge; documents and arrays expand.
struct BSONTreeRow: View {
  let key: String
  let value: BSON
  let level: Int
  var pending: CellValue?
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Group {
          if value.isContainer {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.secondary)
          } else {
            Color.clear
          }
        }
        .frame(width: 10)
        Text(key).foregroundStyle(.secondary)
        TypeBadge(value.typeName)
        Spacer(minLength: 8)
        Text(pending.map { $0 == .unset ? "(removed)" : $0.displayText } ?? summary)
          .font(.codeSmall)
          .foregroundStyle(value.isContainer ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .padding(.horizontal, pending != nil ? 4 : 0)
          .background(pending != nil ? Color.orange.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
      }
      .padding(.leading, CGFloat(12 + level * 16))
      .padding(.trailing, 12)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
      .onTapGesture { if value.isContainer { withAnimation(.snappy) { expanded.toggle() } } }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(value.isContainer ? .isButton : [])
      if expanded {
        switch value {
        case .document(let doc):
          ForEach(doc.elements, id: \.key) { element in
            BSONTreeRow(key: element.key, value: element.value, level: level + 1)
          }
        case .array(let items):
          ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            BSONTreeRow(key: String(index), value: item, level: level + 1)
          }
        default:
          EmptyView()
        }
      }
    }
  }

  private var summary: String {
    switch value {
    case .string(let s): "\"\(s.count > 80 ? String(s.prefix(80)) + "…" : s)\""
    default: CellValue.bson(value).displayText
    }
  }
}
