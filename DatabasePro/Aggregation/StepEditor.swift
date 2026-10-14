import DatabaseProKit
import SwiftUI

/// Edits a step: its friendly form (Builder) or the stage as text.
struct StepEditor: View {
  @Bindable var pipeline: PipelineModel
  let browser: BrowserModel
  let step: PipelineStep
  @State private var showsText = false
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if step.form != nil {
        Picker("Edit as", selection: $showsText) {
          Text("Builder").tag(false)
          Text("Text").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      if let form = step.form, !showsText {
        formEditor(form)
      } else {
        CodeEditor(text: Binding(get: { step.text }, set: { pipeline.setText(step.id, $0) }), language: EngineKind.mongodb.highlighting, completions: [])
          .frame(minHeight: 80, idealHeight: 120, maxHeight: 260)
          .groupBox()
        if let error = parseError {
          Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
        } else if step.form == nil {
          Text("Stage body in MongoDB Shell syntax, without the \(step.kind.op) key.").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var parseError: String? {
    guard step.form == nil || showsText else { return nil }
    do {
      _ = try pipeline.body(of: step)
      return nil
    } catch {
      return FriendlyError.message(error)
    }
  }

  private var fieldNames: [String] {
    var names = browser.fields.map(\.name)
    // Fields produced by earlier steps.
    for earlier in pipeline.steps.prefix(pipeline.steps.firstIndex { $0.id == step.id } ?? 0) {
      switch earlier.form {
      case .group(_, let outputs)?: names = ["_id"] + outputs.map(\.name)
      case .addFields(let formulas)?: names += formulas.map(\.name)
      case .lookup(_, _, _, let alias)?: names.append(alias)
      default: break
      }
    }
    return names
  }

  private func update(_ form: StepForm) {
    pipeline.update(step.id) { $0.form = form }
  }

  @ViewBuilder private func formEditor(_ form: StepForm) -> some View {
    switch form {
    case .filter(let conditions):
      ConditionsEditor(conditions: conditions, fields: fieldNames, category: browser.category(of:)) { update(.filter($0)) }
    case .group(let by, let outputs):
      GroupEditor(by: by, outputs: outputs, fields: fieldNames) { update(.group(by: $0, outputs: $1)) }
    case .sort(let keys):
      SortEditor(keys: keys, fields: fieldNames) { update(.sort($0)) }
    case .limit(let n):
      Stepper("Keep the first \(n)", value: Binding(get: { n }, set: { update(.limit(max(1, $0))) }), in: 1...1_000_000)
    case .skip(let n):
      Stepper("Skip the first \(n)", value: Binding(get: { n }, set: { update(.skip(max(0, $0))) }), in: 0...1_000_000)
    case .pick(let fields, let exclude):
      PickEditor(picked: fields, exclude: exclude, fields: fieldNames, sql: pipeline.isSQL) { update(.pick(fields: $0, exclude: $1)) }
    case .addFields(let formulas):
      FormulasEditor(formulas: formulas, fields: fieldNames) { update(.addFields($0)) }
    case .unwind(let path, let keepEmpty):
      HStack {
        Text("One document per item of")
        FieldField(value: path, fields: fieldNames) { update(.unwind(path: $0, keepEmpty: keepEmpty)) }
      }
      Toggle("Keep documents without items", isOn: Binding(get: { keepEmpty }, set: { update(.unwind(path: path, keepEmpty: $0)) }))
    case .lookup(let from, let local, let foreign, let alias):
      LookupEditor(from: from, local: local, foreign: foreign, alias: alias, fields: fieldNames, browser: browser) {
        update(.lookup(from: $0, localField: $1, foreignField: $2, as: $3))
      }
    case .count(let name):
      HStack {
        Text("Count as")
        TextField("Name", text: Binding(get: { name }, set: { update(.count($0)) })).textFieldStyle(.roundedBorder).frame(width: 140)
      }
    }
  }
}

/// A field name: type it, or pick a known one.
struct FieldField: View {
  let value: String
  let fields: [String]
  let onChange: (String) -> Void

  var body: some View {
    HStack(spacing: 2) {
      TextField("Field", text: Binding(get: { value }, set: onChange))
        .textFieldStyle(.plain)
        .font(.callout.monospaced())
        .frame(minWidth: 70, maxWidth: 160)
      Menu {
        ForEach(fields, id: \.self) { name in Button(name) { onChange(name) } }
      } label: {
        Image(systemName: "chevron.down").imageScale(.small)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .foregroundStyle(Color.blue)
    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
  }
}

struct ConditionsEditor: View {
  let conditions: [StepCondition]
  let fields: [String]
  let category: (String) -> ValueCategory
  let onChange: ([StepCondition]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(conditions.enumerated()), id: \.element.id) { index, condition in
        HStack(spacing: 6) {
          if index > 0 { Text("and").foregroundStyle(.secondary) }
          FieldField(value: condition.field, fields: fields) { set(index) { $0.field = $1 }($0) }
          Picker("Condition", selection: Binding(get: { condition.op }, set: { op in var c = conditions; c[index].op = op; onChange(c) })) {
            ForEach(FilterOp.allCases) { Text($0.label(for: category(condition.field))).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
          if condition.op.needsValue {
            TextField("Value", text: Binding(get: { condition.value }, set: { v in var c = conditions; c[index].value = v; onChange(c) }))
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 70, maxWidth: 160)
          }
          if conditions.count > 1 {
            Button("Remove condition", systemImage: "minus.circle") { var c = conditions; c.remove(at: index); onChange(c) }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
          }
        }
      }
      Button("Add Condition", systemImage: "plus") {
        onChange(conditions + [StepCondition(field: fields.first ?? "", op: .equals, value: "")])
      }
      .buttonStyle(.borderless)
      .font(.callout)
    }
  }

  private func set(_ index: Int, _ change: @escaping (inout StepCondition, String) -> Void) -> (String) -> Void {
    { value in
      var c = conditions
      change(&c[index], value)
      onChange(c)
    }
  }
}

struct GroupEditor: View {
  let by: [String]
  let outputs: [GroupOutput]
  let fields: [String]
  let onChange: ([String], [GroupOutput]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Group by").foregroundStyle(.secondary)
        ForEach(Array(by.enumerated()), id: \.offset) { index, field in
          FieldField(value: field, fields: fields) { value in
            var b = by
            b[index] = value
            onChange(b.filter { !$0.isEmpty }, outputs)
          }
        }
        Menu {
          ForEach(fields, id: \.self) { name in Button(name) { onChange(by + [name], outputs) } }
          if !by.isEmpty {
            Divider()
            Button("Group everything together") { onChange([], outputs) }
          }
        } label: {
          Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      ForEach(Array(outputs.enumerated()), id: \.element.id) { index, output in
        HStack(spacing: 6) {
          TextField("Name", text: Binding(get: { output.name }, set: { v in var o = outputs; o[index].name = v; onChange(by, o) }))
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .frame(width: 110)
          Text("=").foregroundStyle(.secondary)
          Picker("Function", selection: Binding(get: { output.function }, set: { f in var o = outputs; o[index].function = f; onChange(by, o) })) {
            ForEach(GroupOutput.Function.allCases) { Text($0.label).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
          if output.function != .count {
            FieldField(value: output.field, fields: fields) { v in var o = outputs; o[index].field = v; onChange(by, o) }
          }
          Button("Remove", systemImage: "minus.circle") { var o = outputs; o.remove(at: index); onChange(by, o) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
      }
      Button("Add Output", systemImage: "plus") {
        onChange(by, outputs + [GroupOutput(name: "total", function: .sum, field: fields.first ?? "")])
      }
      .buttonStyle(.borderless)
      .font(.callout)
    }
  }
}

struct SortEditor: View {
  let keys: [SortKey]
  let fields: [String]
  let onChange: ([SortKey]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
        HStack(spacing: 6) {
          if index > 0 { Text("then").foregroundStyle(.secondary) }
          FieldField(value: key.field, fields: fields) { v in var k = keys; k[index].field = v; onChange(k) }
          Picker("Direction", selection: Binding(get: { key.ascending }, set: { a in var k = keys; k[index].ascending = a; onChange(k) })) {
            Text("Lowest first").tag(true)
            Text("Highest first").tag(false)
          }
          .labelsHidden()
          .fixedSize()
          if keys.count > 1 {
            Button("Remove", systemImage: "minus.circle") { var k = keys; k.remove(at: index); onChange(k) }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
          }
        }
      }
      Button("Then By…", systemImage: "plus") { onChange(keys + [SortKey(field: fields.first ?? "", ascending: true)]) }
        .buttonStyle(.borderless)
        .font(.callout)
    }
  }
}

struct PickEditor: View {
  let picked: [String]
  let exclude: Bool
  let fields: [String]
  let sql: Bool
  let onChange: ([String], Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !sql {
        Picker("Mode", selection: Binding(get: { exclude }, set: { onChange(picked, $0) })) {
          Text("Only these fields").tag(false)
          Text("All but these").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      FlowLayoutFields(fields: fields, picked: Set(picked)) { name, on in
        onChange(on ? picked + [name] : picked.filter { $0 != name }, exclude)
      }
    }
  }
}

/// Toggle chips for field names.
struct FlowLayoutFields: View {
  let fields: [String]
  let picked: Set<String>
  let onToggle: (String, Bool) -> Void

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
      ForEach(fields, id: \.self) { name in
        let on = picked.contains(name)
        Button {
          onToggle(name, !on)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
            Text(name).lineLimit(1)
          }
          .font(.caption.monospaced())
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(on ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
      }
    }
  }
}

/// Add Fields: each new field is a formula built from blocks.
struct FormulasEditor: View {
  let formulas: [FieldFormula]
  let fields: [String]
  let onChange: ([FieldFormula]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(formulas.enumerated()), id: \.element.id) { index, formula in
        FormulaBlock(formula: formula, fields: fields) { updated in
          var f = formulas
          f[index] = updated
          onChange(f)
        } onRemove: {
          var f = formulas
          f.remove(at: index)
          onChange(f)
        }
      }
      Button("Add Field", systemImage: "plus") {
        onChange(formulas + [FieldFormula(name: "newField", kind: .copy, field: fields.first ?? "")])
      }
      .buttonStyle(DashedCapsuleStyle())
    }
  }
}

struct FormulaBlock: View {
  let formula: FieldFormula
  let fields: [String]
  let onChange: (FieldFormula) -> Void
  let onRemove: () -> Void

  private func binding<T>(_ keyPath: WritableKeyPath<FieldFormula, T>) -> Binding<T> {
    Binding(get: { formula[keyPath: keyPath] }, set: { value in
      var f = formula
      f[keyPath: keyPath] = value
      onChange(f)
    })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        TextField("Name", text: binding(\.name)).textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(width: 110)
        Text("=").foregroundStyle(.secondary)
        Picker("Formula", selection: binding(\.kind)) {
          ForEach(FieldFormula.Kind.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        Text(formula.kind.op).font(.codeSmall).foregroundStyle(.secondary)
        Spacer()
        Button("Remove", systemImage: "minus.circle", action: onRemove).labelStyle(.iconOnly).buttonStyle(.borderless)
      }
      Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
        switch formula.kind {
        case .copy, .size:
          GridRow {
            Text("field").foregroundStyle(.secondary)
            FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
          }
        case .roundDate:
          GridRow {
            Text("date").foregroundStyle(.secondary)
            FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
          }
          GridRow {
            Text("unit").foregroundStyle(.secondary)
            Picker("Unit", selection: binding(\.unit)) {
              ForEach(["year", "quarter", "month", "week", "day", "hour", "minute"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
          }
          GridRow {
            Text("time zone").foregroundStyle(.secondary)
            TextField("UTC", text: binding(\.timezone), prompt: Text("Europe/Lisbon")).textFieldStyle(.roundedBorder).frame(width: 160)
          }
        case .condition:
          GridRow {
            Text("if").foregroundStyle(.secondary)
            HStack(spacing: 6) {
              FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
              Picker("Compare", selection: binding(\.compare)) {
                ForEach([FilterOp.equals, .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual]) { Text($0.label(for: .integer)).tag($0) }
              }
              .labelsHidden()
              .fixedSize()
              TextField("Value", text: binding(\.compareValue)).textFieldStyle(.roundedBorder).frame(width: 70)
            }
          }
          GridRow {
            Text("then").foregroundStyle(.secondary)
            TextField("Then", text: binding(\.thenValue)).textFieldStyle(.roundedBorder).frame(width: 90)
          }
          GridRow {
            Text("else").foregroundStyle(.secondary)
            TextField("Else", text: binding(\.elseValue)).textFieldStyle(.roundedBorder).frame(width: 90)
          }
        case .concat:
          GridRow {
            Text("join").foregroundStyle(.secondary)
            HStack {
              FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
              Text("and")
              FieldField(value: formula.otherField, fields: fields) { onChange(with(\.otherField, $0)) }
            }
          }
        case .math:
          GridRow {
            Text("value").foregroundStyle(.secondary)
            HStack {
              FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
              Picker("Operation", selection: binding(\.mathOp)) {
                Text("+").tag("$add")
                Text("−").tag("$subtract")
                Text("×").tag("$multiply")
                Text("÷").tag("$divide")
              }
              .labelsHidden()
              .fixedSize()
              TextField("Field or number", text: binding(\.otherField)).textFieldStyle(.roundedBorder).frame(width: 110)
            }
          }
        case .raw:
          GridRow {
            Text("expression").foregroundStyle(.secondary)
            TextField("{ $toUpper: \"$name\" }", text: binding(\.raw)).textFieldStyle(.roundedBorder).font(.callout.monospaced())
          }
        }
      }
      .padding(.leading, 14)
      .overlay(alignment: .leading) { Rectangle().fill(Color.purple.opacity(0.25)).frame(width: 2) }
    }
    .padding(10)
    .groupBox()
  }

  private func with<T>(_ keyPath: WritableKeyPath<FieldFormula, T>, _ value: T) -> FieldFormula {
    var f = formula
    f[keyPath: keyPath] = value
    return f
  }
}

struct LookupEditor: View {
  let from: String
  let local: String
  let foreign: String
  let alias: String
  let fields: [String]
  let browser: BrowserModel
  let onChange: (String, String, String, String) -> Void

  private var collections: [String] {
    browser.connection.children.values.joined().filter { $0.ref?.kind == .collection && $0.ref?.database == browser.ref.database }
      .map(\.title)
  }

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
      GridRow {
        Text("From").foregroundStyle(.secondary)
        FieldField(value: from, fields: collections) { onChange($0, local, foreign, alias) }
      }
      GridRow {
        Text("where").foregroundStyle(.secondary)
        HStack {
          FieldField(value: foreign, fields: ["_id"]) { onChange(from, local, $0, alias) }
          Text("matches")
          FieldField(value: local, fields: fields) { onChange(from, $0, foreign, alias) }
        }
      }
      GridRow {
        Text("save as").foregroundStyle(.secondary)
        TextField("as", text: Binding(get: { alias }, set: { onChange(from, local, foreign, $0) })).textFieldStyle(.roundedBorder).frame(width: 140)
      }
    }
  }
}
