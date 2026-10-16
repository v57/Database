import ComponentKit
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
    KitInspector(width: nil) {
      InspectorHeader(
        browser.displayName(for: record) ?? "Document", meta: ["Document in \(browser.ref.name)", "\(document.count) fields"],
        systemImage: browser.ref.symbol, hue: browser.engine.hue)
      if editing {
        editor
        ActionBar {
          Button("Cancel") { editing = false }
          Button("Done", action: finishEditing)
            .keyboardShortcut(.defaultAction)
        }
      } else {
        KitSection("Fields", meta: "\(document.count) fields", systemImage: browser.ref.symbol, hue: browser.engine.hue) {
          ForEach(document.elements, id: \.key) { element in
            BSONTreeRow(key: element.key, value: element.value, level: 0, pending: browser.pendingValue(for: record, field: element.key))
          }
        }
        ActionBar {
          if browser.isEditable && record.key != nil {
            Button("Edit", action: startEditing)
          }
          Button("Copy as JSON") { KitPasteboard.copy(document.text(.extendedJSON, indent: 2)) }
          if browser.isEditable && record.key != nil {
            Button("Delete Document…", systemImage: "trash", role: .destructive, action: onDelete)
              .labelStyle(.iconOnly)
          }
        }
        InspectorNote("_id can't be changed. Every other field is editable, and you see the change before it's saved.")
      }
    }
    .task(id: record.id) { editing = false }
    .onChange(of: browser.editRequest) { _, id in
      if id == record.id, browser.isEditable { startEditing() }
      browser.editRequest = nil
    }
  }

  // MARK: Editing

  private var editor: some View {
    KitSection("Edit", meta: "\(rows.count) fields", systemImage: "pencil", hue: .orange) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach($rows) { $row in
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              if row.name == "_id" {
                Text(row.name).kitFont(.headline)
              } else {
                TextField("Field", text: $row.name)
                  .kitField(mono: true)
                  .frame(maxWidth: 160)
              }
              KitPicker("Type", selection: $row.type, options: documentFieldTypes.map { ($0, $0) })
              .disabled(row.name == "_id")
              Spacer()
              if row.name != "_id" {
                Button("Remove \(row.name)", systemImage: "minus.circle", role: .destructive) { rows.removeAll { $0.id == row.id } }
                  .buttonStyle(.kitIcon)
              }
            }
            if row.name == "_id" {
              Text(row.text).kitFont(.monoSmall).foregroundStyle(.kitSecondary)
            } else if row.type == "Boolean" {
              KitSegmented(selection: $row.text, options: [("true", "true"), ("false", "false")])
                .kitSegmentedStyle(.wide)
            } else if row.type == "Null" {
              Text("null").italic().foregroundStyle(.kitSecondary)
            } else if ["Object", "Array"].contains(row.type) || !documentFieldTypes.contains(row.type) || row.text.contains("\n") {
              TextEditor(text: $row.text)
                .kitFont(.mono)
                .frame(minHeight: 60, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.kitField, in: RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
            } else {
              TextField("Value", text: $row.text, prompt: Text(row.type == "Date" ? "2026-10-12T10:02:00Z" : ""))
                .kitField(status: errors[row.id] == nil ? .none : .error, mono: row.type != "String")
            }
          }
          .kitFieldError(errors[row.id])
          .padding(.vertical, 4)
        }
        Button("Add Field", systemImage: "plus") {
          rows.append(EditableField(name: "", type: "String", text: "", original: nil))
        }
        .buttonStyle(.kit)
        .controlSize(.small)
      }
      .padding(6)
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
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.kitTertiary)
              .rotationEffect(.degrees(expanded ? 90 : 0))
          } else {
            Color.clear
          }
        }
        .frame(width: 10)
        Text(key).foregroundStyle(.kitSecondary).lineLimit(1)
        Chip(type: value.typeName).controlSize(.small)
        Spacer(minLength: 8)
        Text(pending.map { $0 == .unset ? "(removed)" : $0.displayText } ?? summary)
          .kitFont(.monoSmall)
          .foregroundStyle(value.isContainer ? AnyShapeStyle(.kitSecondary) : AnyShapeStyle(.kitLabel))
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .padding(.horizontal, pending != nil ? 4 : 0)
          .background(pending != nil ? AnyShapeStyle(Hue.orange.soft()) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: KitMetrics.radiusXS))
      }
      .padding(.leading, CGFloat(4 + level * 14))
      .padding(.trailing, 6)
      .frame(minHeight: 30)
      .contentShape(Rectangle())
      .onTapGesture { if value.isContainer { withKitAnimation { expanded.toggle() } } }
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
