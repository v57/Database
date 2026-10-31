import ComponentKit
import DatabaseKit
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
        KitSegmented(selection: $showsText, options: [("Builder", false), ("Text", true)])
      }
      if let form = step.form, !showsText {
        formEditor(form)
      } else {
        CodeEditor(text: Binding(get: { step.text }, set: { pipeline.setText(step.id, $0) }), language: EngineKind.mongodb.highlighting, completions: [])
          .frame(minHeight: 80, idealHeight: 120, maxHeight: 260)
          .kitSurface(.field)
          .clipShape(RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
        if let error = parseError {
          Label(error, systemImage: "exclamationmark.circle").kitFont(.caption).foregroundStyle(Hue.red.text)
        } else if step.form == nil {
          Text("Stage body in MongoDB Shell syntax, without the \(step.kind.op) key.").kitFont(.caption)
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
      HStack(spacing: 8) {
        Text("Keep the first")
        KitStepper("Keep the first", value: Binding(get: { n }, set: { update(.limit(max(1, $0))) }), in: 1...1_000_000)
      }
    case .skip(let n):
      HStack(spacing: 8) {
        Text("Skip the first")
        KitStepper("Skip the first", value: Binding(get: { n }, set: { update(.skip(max(0, $0))) }), in: 0...1_000_000)
      }
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
        .toggleStyle(.kitCheckbox)
    case .lookup(let from, let local, let foreign, let alias):
      LookupEditor(from: from, local: local, foreign: foreign, alias: alias, fields: fieldNames, browser: browser) {
        update(.lookup(from: $0, localField: $1, foreignField: $2, as: $3))
      }
    case .count(let name):
      HStack {
        Text("Count as")
        TextField("Name", text: Binding(get: { name }, set: { update(.count($0)) })).kitField().frame(width: 140)
      }
    }
  }
}

/// A field name: type it, or pick a known one from the menu at the field's end.
struct FieldField: View {
  let value: String
  let fields: [String]
  let onChange: (String) -> Void
  @State private var picking = false

  var body: some View {
    TextField("Field", text: Binding(get: { value }, set: onChange))
      .kitField(mono: true) {
        Button("Pick a field", systemImage: "chevron.down") { picking = true }
          .labelStyle(.iconOnly)
          .buttonStyle(.kitIcon)
          .controlSize(.small)
          .fixedSize()
          .kitMenu(isPresented: $picking) {
            ForEach(fields, id: \.self) { name in Button(name) { onChange(name) } }
          }
      }
      .frame(minWidth: 110, maxWidth: 200)
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
          if index > 0 { Text("and").foregroundStyle(.kitSecondary) }
          FieldField(value: condition.field, fields: fields) { set(index) { $0.field = $1 }($0) }
          KitPicker("Condition", selection: Binding(get: { condition.op }, set: { op in var c = conditions; c[index].op = op; onChange(c) }), options: FilterOp.allCases.map { ($0.label(for: category(condition.field)), $0) })
          if condition.op.needsValue {
            TextField("Value", text: Binding(get: { condition.value }, set: { v in var c = conditions; c[index].value = v; onChange(c) }))
              .kitField()
              .frame(minWidth: 70, maxWidth: 160)
          }
          if conditions.count > 1 {
            Button("Remove condition", systemImage: "minus.circle") { var c = conditions; c.remove(at: index); onChange(c) }
              .buttonStyle(.kitIcon)
          }
        }
      }
      Button("Add Condition", systemImage: "plus") {
        onChange(conditions + [StepCondition(field: fields.first ?? "", op: .equals, value: "")])
      }
      .buttonStyle(.kitPlain)
      .controlSize(.small)
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
  @State private var adding = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Group by").foregroundStyle(.kitSecondary)
        ForEach(Array(by.enumerated()), id: \.offset) { index, field in
          FieldField(value: field, fields: fields) { value in
            var b = by
            b[index] = value
            onChange(b.filter { !$0.isEmpty }, outputs)
          }
        }
        Button("Add a field to group by", systemImage: "plus.circle") { adding = true }
          .buttonStyle(.kitIcon)
          .kitMenu(isPresented: $adding) {
            ForEach(fields, id: \.self) { name in Button(name) { onChange(by + [name], outputs) } }
            if !by.isEmpty {
              Divider()
              Button("Group everything together") { onChange([], outputs) }
            }
          }
      }
      ForEach(Array(outputs.enumerated()), id: \.element.id) { index, output in
        HStack(spacing: 6) {
          TextField("Name", text: Binding(get: { output.name }, set: { v in var o = outputs; o[index].name = v; onChange(by, o) }))
            .kitField(mono: true)
            .frame(width: 110)
          Text("=").foregroundStyle(.kitSecondary)
          KitPicker("Function", selection: Binding(get: { output.function }, set: { f in var o = outputs; o[index].function = f; onChange(by, o) }), options: GroupOutput.Function.allCases.map { ($0.label, $0) })
          if output.function != .count {
            FieldField(value: output.field, fields: fields) { v in var o = outputs; o[index].field = v; onChange(by, o) }
          }
          Button("Remove", systemImage: "minus.circle") { var o = outputs; o.remove(at: index); onChange(by, o) }
            .buttonStyle(.kitIcon)
        }
      }
      Button("Add Output", systemImage: "plus") {
        onChange(by, outputs + [GroupOutput(name: "total", function: .sum, field: fields.first ?? "")])
      }
      .buttonStyle(.kitPlain)
      .controlSize(.small)
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
          if index > 0 { Text("then").foregroundStyle(.kitSecondary) }
          FieldField(value: key.field, fields: fields) { v in var k = keys; k[index].field = v; onChange(k) }
          KitPicker(
            "Direction", selection: Binding(get: { key.ascending }, set: { a in var k = keys; k[index].ascending = a; onChange(k) }),
            options: [("Lowest first", true), ("Highest first", false)])
          if keys.count > 1 {
            Button("Remove", systemImage: "minus.circle") { var k = keys; k.remove(at: index); onChange(k) }
              .buttonStyle(.kitIcon)
          }
        }
      }
      Button("Then By…", systemImage: "plus") { onChange(keys + [SortKey(field: fields.first ?? "", ascending: true)]) }
        .buttonStyle(.kitPlain)
        .controlSize(.small)
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
        KitSegmented(
          selection: Binding(get: { exclude }, set: { onChange(picked, $0) }),
          options: [("Only these fields", false), ("All but these", true)])
      }
      FieldChips(fields: fields, picked: Set(picked)) { name, on in
        onChange(on ? picked + [name] : picked.filter { $0 != name }, exclude)
      }
    }
  }
}

/// Toggle chips for field names, on one track that wraps.
struct FieldChips: View {
  let fields: [String]
  let picked: Set<String>
  let onToggle: (String, Bool) -> Void

  var body: some View {
    ChipTrack {
      ForEach(fields, id: \.self) { name in
        Toggle(isOn: Binding(get: { picked.contains(name) }, set: { onToggle(name, $0) })) {
          Text(name).kitFont(.monoSmall).lineLimit(1)
        }
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
      .buttonStyle(.kit)
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
        TextField("Name", text: binding(\.name)).kitField(mono: true).frame(width: 110)
        Text("=").foregroundStyle(.kitSecondary)
        KitPicker("Formula", selection: binding(\.kind), options: FieldFormula.Kind.allCases.map { ($0.label, $0) })
        Text(formula.kind.op).kitFont(.monoSmall).foregroundStyle(.kitSecondary).fixedSize()
        Spacer()
        Button("Remove", systemImage: "minus.circle", action: onRemove).buttonStyle(.kitIcon)
      }
      Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
        switch formula.kind {
        case .copy, .size:
          GridRow {
            Text("field").foregroundStyle(.kitSecondary)
            FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
          }
        case .roundDate:
          GridRow {
            Text("date").foregroundStyle(.kitSecondary)
            FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
          }
          GridRow {
            Text("unit").foregroundStyle(.kitSecondary)
            KitPicker("Unit", selection: binding(\.unit), options: ["year", "quarter", "month", "week", "day", "hour", "minute"].map { ($0.capitalized, $0) })
          }
          GridRow {
            Text("time zone").foregroundStyle(.kitSecondary)
            TextField("UTC", text: binding(\.timezone), prompt: Text("Europe/Lisbon")).kitField().frame(width: 160)
          }
        case .condition:
          GridRow {
            Text("if").foregroundStyle(.kitSecondary)
            HStack(spacing: 6) {
              FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
              KitPicker("Compare", selection: binding(\.compare), options: [FilterOp.equals, .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual].map { ($0.label(for: .integer), $0) })
              TextField("Value", text: binding(\.compareValue)).kitField().frame(width: 70)
            }
          }
          GridRow {
            Text("then").foregroundStyle(.kitSecondary)
            TextField("Then", text: binding(\.thenValue)).kitField().frame(width: 90)
          }
          GridRow {
            Text("else").foregroundStyle(.kitSecondary)
            TextField("Else", text: binding(\.elseValue)).kitField().frame(width: 90)
          }
        case .concat:
          GridRow {
            Text("join").foregroundStyle(.kitSecondary)
            HStack {
              FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
              Text("and")
              FieldField(value: formula.otherField, fields: fields) { onChange(with(\.otherField, $0)) }
            }
          }
        case .math:
          GridRow {
            Text("value").foregroundStyle(.kitSecondary)
            HStack {
              FieldField(value: formula.field, fields: fields) { onChange(with(\.field, $0)) }
              KitPicker(
                "Operation", selection: binding(\.mathOp),
                options: [("+", "$add"), ("−", "$subtract"), ("×", "$multiply"), ("÷", "$divide")])
              TextField("Field or number", text: binding(\.otherField)).kitField().frame(width: 110)
            }
          }
        case .raw:
          GridRow {
            Text("expression").foregroundStyle(.kitSecondary)
            TextField("{ $toUpper: \"$name\" }", text: binding(\.raw)).kitField(mono: true)
          }
        }
      }
      .padding(.leading, 14)
      .overlay(alignment: .leading) { Rectangle().fill(Hue.purple.soft(0.4)).frame(width: 2) }
    }
    .padding(10)
    .kitSurface(.card)
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
        Text("From").foregroundStyle(.kitSecondary)
        FieldField(value: from, fields: collections) { onChange($0, local, foreign, alias) }
      }
      GridRow {
        Text("where").foregroundStyle(.kitSecondary)
        HStack {
          FieldField(value: foreign, fields: ["_id"]) { onChange(from, local, $0, alias) }
          Text("matches")
          FieldField(value: local, fields: fields) { onChange(from, $0, foreign, alias) }
        }
      }
      GridRow {
        Text("save as").foregroundStyle(.kitSecondary)
        TextField("as", text: Binding(get: { alias }, set: { onChange(from, local, foreign, $0) })).kitField().frame(width: 140)
      }
    }
  }
}
