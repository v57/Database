import MongoDB
import Redis
import SwiftUI

/// UI-driven filter builder: one chip per rule (ANDed, in order) compiled into
/// the query bar's Filter text. Chips are created and edited through a sheet so
/// the value control can follow the field's inferred kind (text field, boolean
/// picker, value suggestions from the rows already loaded).
struct FilterBuilderView: View {
  let fields: [FieldInfo]
  @Binding var rules: [FilterRule]
  /// The chip editor sheet is driven by the PANE's state, so a table column menu
  /// or a List key menu can open it prefilled for its field (see `handle` in
  /// DocumentsView). Writing `editing` presents the sheet.
  @Binding var editing: FilterRule?
  @Binding var isCreating: Bool
  let dialect: FilterDialect
  /// Called after every rule change so the owner re-renders the text and applies it.
  let onChange: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      ForEach(rules) { rule in chip(rule) }
      addMenu
      if !rules.isEmpty {
        Button {
          rules = []
          onChange()
        } label: {
          Label("Clear filters", systemImage: "xmark.circle")
        }.buttonStyle(.plain).labelStyle(.iconOnly)
          .help("Clear all filter chips")
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8).padding(.vertical, 4)
    .sheet(item: $editing) { rule in
      FilterRuleEditor(
        rule: rule,
        fields: fields,
        dialect: dialect,
        isCreating: isCreating,
        onCancel: { editing = nil },
        onSave: { edited in
          if let index = rules.firstIndex(where: { $0.id == edited.id }) {
            rules[index] = edited
          } else {
            rules.append(edited)
          }
          editing = nil
          onChange()
        })
    }
  }

  // MARK: - Chips

  private func chip(_ rule: FilterRule) -> some View {
    HStack(spacing: 4) {
      Button {
        isCreating = false
        editing = rule
      } label: {
        Label(rule.summary, systemImage: "line.3.horizontal.decrease.circle")
          .font(.caption)
      }.buttonStyle(.plain)

      Button {
        rules.removeAll { $0.id == rule.id }
        onChange()
      } label: {
        Image(systemName: "xmark.circle.fill").font(.caption)
      }.buttonStyle(.plain).foregroundStyle(.secondary)
        .help("Remove this filter")
    }
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(.quaternary, in: Capsule())
  }

  private var addMenu: some View {
    Menu {
      if fields.isEmpty {
        Text("No fields loaded")
      } else {
        ForEach(fields, id: \.name) { field in
          Button {
            isCreating = true
            editing = FilterRule(field: field.name, op: FilterEngine.defaultOperator(for: field.kind))
          } label: {
            Label(field.name, systemImage: field.kind.symbol)
          }
        }
      }
    } label: {
      Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        .font(.caption)
    }
    .menuStyle(.borderlessButton).fixedSize()
    .help("Add a filter on a field")
  }
}

/// Sheet that creates or edits one rule: field, operator, and a value control
/// whose shape follows the operator (list ops take comma-separated values).
private struct FilterRuleEditor: View {
  let fields: [FieldInfo]
  let dialect: FilterDialect
  let isCreating: Bool
  let onCancel: () -> Void
  let onSave: (FilterRule) -> Void

  @State private var rule: FilterRule
  @State private var valueText: String
  @State private var boolValue: Bool

  init(
    rule: FilterRule, fields: [FieldInfo], dialect: FilterDialect, isCreating: Bool,
    onCancel: @escaping () -> Void, onSave: @escaping (FilterRule) -> Void
  ) {
    self.fields = fields
    self.dialect = dialect
    self.isCreating = isCreating
    self.onCancel = onCancel
    self.onSave = onSave
    _rule = State(initialValue: rule)
    switch rule.value {
    case .bool(let flag):
      _boolValue = State(initialValue: flag)
      _valueText = State(initialValue: "")
    case .array(let items):
      _boolValue = State(initialValue: false)
      _valueText = State(initialValue: items.map(FilterText.display).joined(separator: ", "))
    default:
      _boolValue = State(initialValue: false)
      _valueText = State(
        initialValue: rule.op.needsValue ? FilterText.display(rule.value) : "")
    }
  }

  private var fieldInfo: FieldInfo? { fields.first { $0.name == rule.field } }
  private var kind: FieldKind { fieldInfo?.kind ?? .mixed }
  private var operators: [FilterOp] { FilterEngine.operators(for: kind) }
  private var usesBooleanPicker: Bool { kind == .boolean && !rule.op.takesList }
  private var suggestions: [BSON] {
    rule.op.takesList ? [] : Array((fieldInfo?.values ?? []).prefix(20))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(isCreating ? "Add Filter" : "Edit Filter").font(.headline)

      Picker("Field", selection: $rule.field) {
        ForEach(fields, id: \.name) { field in
          Label(field.name, systemImage: field.kind.symbol).tag(field.name)
        }
        // A rule loaded from elsewhere may name a field that isn't in the
        // current page of documents; keep it selectable.
        if !fields.contains(where: { $0.name == rule.field }) {
          Text(rule.field).tag(rule.field)
        }
      }

      Picker("Operator", selection: $rule.op) {
        ForEach(operators) { op in
          Label(op.label, systemImage: op.symbol).tag(op)
        }
        // A column "Search…" chip carries the `.custom` operator, which is not in
        // the per-kind list; keep it selectable while its chip is being edited.
        if !operators.contains(rule.op) {
          Label(rule.op.label, systemImage: rule.op.symbol).tag(rule.op)
        }
      }

      if rule.op.needsValue { valueControl }

      HStack {
        Spacer()
        Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        Button(isCreating ? "Add" : "Apply") { onSave(committedRule()) }
          .keyboardShortcut(.defaultAction).disabled(!isValid)
      }
    }
    .padding(20)
    .frame(width: 440)
    .onChange(of: rule.op) { _, _ in resetValue() }
    .onChange(of: rule.field) { _, _ in resetValue() }
  }

  @ViewBuilder private var valueControl: some View {
    if usesBooleanPicker {
      Picker("Value", selection: $boolValue) {
        Text("true").tag(true)
        Text("false").tag(false)
      }.pickerStyle(.segmented)
    } else if rule.op.takesList {
      TextField("value, value, …", text: $valueText)
        .textFieldStyle(.roundedBorder)
    } else {
      HStack {
        TextField(valuePrompt, text: $valueText).textFieldStyle(.roundedBorder)
        if !suggestions.isEmpty {
          Menu("Values") {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, value in
              Button(FilterText.display(value)) { valueText = FilterText.display(value) }
            }
          }.fixedSize().help("Values found in the loaded rows")
        }
      }
    }
  }

  private var valuePrompt: String {
    switch kind {
    case .number, .date: return "Value (e.g. 30)"
    default: return "Value"
    }
  }

  /// A rule is only applicable when its value is usable; an unfinished chip
  /// would render as `{ field: "" }` and silently filter everything out.
  private var isValid: Bool {
    guard !rule.field.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    guard rule.op.needsValue else { return true }
    if usesBooleanPicker { return true }
    return !valueText.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func resetValue() {
    valueText = ""
    boolValue = false
  }

  /// The rule to save, with the typed value folded into BSON per the field kind.
  private func committedRule() -> FilterRule {
    var edited = rule
    switch (rule.op.takesList, usesBooleanPicker, rule.op.needsValue) {
    case (true, _, _):
      edited.value = .array(
        valueText.split(separator: ",").map {
          FilterText.value(fromText: String($0), kind: kind, dialect: dialect)
        })
    case (_, true, _):
      edited.value = .bool(boolValue)
    case (_, _, true):
      edited.value = FilterText.value(fromText: valueText, kind: kind, dialect: dialect)
    default:
      edited.value = .null
    }
    return edited
  }
}

/// One-line fragment box for a column's "Search…" item. Accepts both dialects'
/// fragment syntax (`15`, `"ann"`, `{ $gt: 15 }`, `{ $gt: 1, $lt: 9 }`) and is
/// validated with the same parser the query bar uses before it is applied.
struct ColumnSearchSheet: View {
  let field: String
  @Binding var fragment: String
  @Binding var errorMessage: String?
  let onCancel: () -> Void
  let onApply: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Search \(field)").font(.headline)
      Text("Value or operator object — e.g. 15, \"ann\", { $gt: 15 }, { $in: [1, 2] }")
        .font(.caption).foregroundStyle(.secondary)
      TextField("Value or { $op: value }", text: $fragment)
        .textFieldStyle(.roundedBorder).onSubmit { onApply() }
      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        Button("Apply") { onApply() }.keyboardShortcut(.defaultAction)
      }
    }.padding(20).frame(width: 440)
  }
}

/// Redis key filter: a match-mode picker plus text, writing an explicit glob
/// pattern into the Filter field (`user:*`, `*:1`, `user:1`, `*user*`).
struct RedisKeyFilterView: View {
  @Binding var match: KeyGlob.Match
  @Binding var text: String
  /// Match-mode changes apply at once (one tap, no typing).
  let onMatchChange: () -> Void
  /// Text changes are debounced by the owner so a query is not fired per keystroke.
  let onTextChange: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Picker("Match", selection: $match) {
        ForEach(KeyGlob.Match.allCases) { mode in Text(mode.label).tag(mode) }
      }.pickerStyle(.menu).labelsHidden().fixedSize().frame(maxWidth: 150)
        .onChange(of: match) { _, _ in onMatchChange() }

      TextField("Key text", text: $text)
        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
        .onChange(of: text) { _, _ in onTextChange() }
        .onSubmit { onMatchChange() }

      if let preview = KeyGlob.pattern(text, match: match) {
        Text(preview).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }
}
