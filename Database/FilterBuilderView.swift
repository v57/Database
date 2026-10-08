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
    // Wraps onto further lines instead of overflowing the pane when there are
    // more chips than fit in one row.
    FlowLayout(spacing: 6, lineSpacing: 4) {
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

/// Left-to-right layout that starts a new line when the next subview would not
/// fit the proposed width (an HStack would overflow instead). Each line is as
/// tall as its tallest item, and items are centered vertically within it.
struct FlowLayout: Layout {
  /// Horizontal gap between items on a line.
  var spacing: CGFloat = 6
  /// Vertical gap between lines.
  var lineSpacing: CGFloat = 4

  /// One laid-out line: the subview indices on it plus its size.
  private struct Line {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    let lines = lines(for: subviews, maxWidth: maxWidth)
    let width = lines.map(\.width).max() ?? 0
    let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
    return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for line in lines(for: subviews, maxWidth: bounds.width) {
      var x = bounds.minX
      for index in line.indices {
        let size = itemSize(subviews[index], maxWidth: bounds.width)
        subviews[index].place(
          at: CGPoint(x: x, y: y + (line.height - size.height) / 2), anchor: .topLeading,
          proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += line.height + lineSpacing
    }
  }

  /// Ideal size, clamped so a single over-wide item still fits one line.
  private func itemSize(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
    let ideal = subview.sizeThatFits(.unspecified)
    guard ideal.width > maxWidth else { return ideal }
    return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
  }

  private func lines(for subviews: Subviews, maxWidth: CGFloat) -> [Line] {
    var lines: [Line] = []
    var current = Line()
    for index in subviews.indices {
      let size = itemSize(subviews[index], maxWidth: maxWidth)
      if !current.indices.isEmpty && current.width + spacing + size.width > maxWidth {
        lines.append(current)
        current = Line()
      }
      current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { lines.append(current) }
    return lines
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
    // Keep what was typed while it still means something: `is` → `is not`
    // reuses the value, only a different value shape (or field kind) clears it.
    .onChange(of: rule.op) { oldOp, newOp in
      if shape(of: oldOp, kind: kind) != shape(of: newOp, kind: kind) { resetValue() }
    }
    .onChange(of: rule.field) { oldField, _ in
      if kind(of: oldField) != kind { resetValue() }
    }
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

  /// What kind of value control an operator needs for a field kind.
  private enum ValueShape {
    case none, single, list, boolean
    /// `.custom` (a column "Search…" chip) holds a raw query fragment, which
    /// is not a usable value for any other operator.
    case custom
  }

  private func shape(of op: FilterOp, kind: FieldKind) -> ValueShape {
    if !op.needsValue { return .none }
    if op == .custom { return .custom }
    if op.takesList { return .list }
    return kind == .boolean ? .boolean : .single
  }

  private func kind(of field: String) -> FieldKind {
    fields.first { $0.name == field }?.kind ?? .mixed
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
  /// Only changes the hint: SQL engines take the same JSON fragment syntax and
  /// compile it to a WHERE clause, which isn't obvious from the examples alone.
  var dialect: FilterDialect = .mongo
  @Binding var fragment: String
  @Binding var errorMessage: String?
  let onCancel: () -> Void
  let onApply: () -> Void

  private var hint: String {
    switch dialect {
    case .mongo:
      "Value or operator object — e.g. 15, \"ann\", { $gt: 15 }, { $in: [1, 2] }"
    case .sql:
      "JSON query syntax, compiled to SQL — e.g. 15, \"ann\", { $gt: 15 }, { $in: [1, 2] }"
    }
  }

  private var isEmpty: Bool { fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Search \(field)").font(.headline)
      Text(hint).font(.caption).foregroundStyle(.secondary)
      TextField("Value or { $op: value }", text: $fragment)
        .textFieldStyle(.roundedBorder).onSubmit { if !isEmpty { onApply() } }
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        Button("Apply") { onApply() }.keyboardShortcut(.defaultAction).disabled(isEmpty)
      }
    }.padding(20).frame(width: 440)
  }
}

/// Redis key filter: a match-mode picker plus text, writing an explicit glob
/// pattern into the Filter field (`user:*`, `*:1`, `user:1`, `*user*`). Text
/// that already contains glob syntax is sent as typed and the match mode is
/// disabled, since it no longer applies.
struct RedisKeyFilterView: View {
  @Binding var match: KeyGlob.Match
  @Binding var text: String
  /// Match-mode changes apply at once (one tap, no typing).
  let onMatchChange: () -> Void
  /// Text changes are debounced by the owner so a query is not fired per keystroke.
  let onTextChange: () -> Void

  private var isGlob: Bool { KeyGlob.isPattern(text) }

  var body: some View {
    HStack(spacing: 6) {
      Picker("Match", selection: $match) {
        ForEach(KeyGlob.Match.allCases) { mode in Text(mode.label).tag(mode) }
      }.pickerStyle(.menu).labelsHidden().fixedSize().frame(maxWidth: 150)
        .disabled(isGlob)
        .help(isGlob ? "Glob pattern used as typed" : "How the text matches key names")
        .onChange(of: match) { _, _ in onMatchChange() }

      TextField("Key", text: $text, prompt: Text("Key (text or glob, e.g. user:*)"))
        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
        .onChange(of: text) { _, _ in onTextChange() }
        .onSubmit { onMatchChange() }

      // The exact SCAN pattern the query will use.
      if let preview = KeyGlob.query(text, match: match) {
        Text("MATCH \(preview)").font(.caption.monospaced()).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
  }
}
