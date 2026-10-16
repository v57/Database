import ComponentKit
import DatabaseKit
import SwiftUI

/// Aggregate mode: steps on the left, the selected step's output on the right.
struct PipelineView: View {
  @Bindable var pipeline: PipelineModel
  let browser: BrowserModel
  @State private var importing = false
  @State private var importText = ""
  @State private var importError: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      if pipeline.showsFullBuilder && !pipeline.isSQL {
        KitWindowLayout {
          StepLibrary(pipeline: pipeline).frame(width: 260).kitPane(.secondary)
          stepList.frame(minWidth: 360).kitPane(.content)
          StepInspector(pipeline: pipeline, browser: browser).frame(minWidth: 270, idealWidth: 400).kitPane(.secondary)
        }
      } else {
        KitWindowLayout {
          stepList.frame(minWidth: 420).kitPane(.content)
          OutputPanel(pipeline: pipeline, browser: browser).frame(minWidth: 320, idealWidth: 400).kitPane(.secondary)
        }
      }
    }
    .task {
      if pipeline.steps.isEmpty { pipeline.add(.match) } else { await pipeline.refreshPreview() }
    }
    .sheet(isPresented: $importing) { importSheet.componentKit(accent: .databaseAccent) }
  }

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Pipeline").kitFont(.title3)
        Text("Each step works on what the step above passes down. Click a step to see its output.")
          .kitFont(.caption)
      }
      Spacer()
      if !pipeline.isSQL {
        Toggle(isOn: $pipeline.showsFullBuilder) {
          Label("All Steps", systemImage: "square.grid.2x2")
        }
        .toggleStyle(.kitCheckbox)
        .accessibilityHint("Show every MongoDB step, settings and formulas")
      }
      Button("Import…") {
        importText = ""
        importing = true
      }
      .buttonStyle(.kit)
      Menu("Export") {
        if pipeline.isSQL {
          Button("Copy SQL") { Clipboard.copy((try? pipeline.sql()) ?? "") }
        } else {
          Button("Copy as JavaScript") { Clipboard.copy(pipeline.javaScript) }
          Button("Copy as JSON") {
            Clipboard.copy(BSON.array(((try? pipeline.stages()) ?? []).map(BSON.document)).text(.extendedJSON, indent: 2))
          }
        }
      }
      .menuStyle(.button)
      .buttonStyle(.kit)
      .menuIndicator(.hidden)
      .fixedSize()
      Button("Run", systemImage: "play.fill") { Task { await pipeline.run() } }
        .buttonStyle(.kitPrimary)
        .kitHelp("Run the whole pipeline", shortcut: "⌘↩", systemImage: "play.fill")
    }
    .controlSize(.small)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var stepList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(pipeline.steps.enumerated()), id: \.element.id) { index, step in
          StepCard(pipeline: pipeline, browser: browser, step: step, index: index, inlineEditor: !pipeline.showsFullBuilder)
          if index < pipeline.steps.count - 1 {
            Rectangle().fill(.kitSeparator).frame(width: 2, height: KitMetrics.gutter).padding(.leading, 44)
          }
        }
        AddStepMenu(pipeline: pipeline)
          .padding(.top, 12)
        if pipeline.showsFullBuilder && !pipeline.isSQL {
          PipelineSettings(pipeline: pipeline).padding(.top, 16)
        }
        if let error = pipeline.resultError {
          Banner(error, systemImage: "exclamationmark.triangle", hue: .red).padding(.top, 12)
        }
        if pipeline.isSQL {
          Text("Pipelines on SQL tables become one SELECT, shown under Code.")
            .kitFont(.caption)
            .padding(.top, 14)
        }
      }
      .padding(KitMetrics.gutter)
    }
  }

  private var importSheet: some View {
    KitSheet(
      title: "Import Pipeline", meta: "Paste db.collection.aggregate([…]), a JSON array of stages, or stages separated by commas.",
      systemImage: "square.and.arrow.down", width: 560
    ) {
      CodeEditor(text: $importText, language: EngineKind.mongodb.highlighting, completions: [])
        .frame(minHeight: 240)
        .background(.kitField, in: RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
        .kitFieldError(importError)
    } footer: {
      Button("Cancel") { importing = false }
        .keyboardShortcut(.cancelAction)
      Button("Import") {
        do {
          try pipeline.importText(importText)
          importing = false
        } catch {
          importError = FriendlyError.message(error)
        }
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
    }
  }
}

/// One step: number, name, summary, count, on/off, actions; the form when selected.
struct StepCard: View {
  @Bindable var pipeline: PipelineModel
  let browser: BrowserModel
  let step: PipelineStep
  let index: Int
  let inlineEditor: Bool

  private var selected: Bool { pipeline.selectedID == step.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "line.3.horizontal").foregroundStyle(.kitTertiary).accessibilityHidden(true)
        Button {
          pipeline.select(step.id)
        } label: {
          HStack(spacing: 8) {
            StepNumber(index + 1, isCurrent: selected)
            Text(step.kind.name).kitFont(.headline)
            Text(step.kind.op).kitFont(.monoSmall).foregroundStyle(.kitSecondary)
            Text("· " + pipeline.summary(step)).foregroundStyle(.kitSecondary).lineLimit(1)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Spacer(minLength: 4)
        if let count = pipeline.counts[step.id], step.isEnabled {
          Text("\(count.formatted()) out").kitFont(.caption).monospacedDigit()
        } else if !step.isEnabled {
          Text("Off").kitFont(.caption)
        }
        Toggle("Step \(index + 1) on", isOn: Binding(get: { step.isEnabled }, set: { on in pipeline.update(step.id) { $0.isEnabled = on } }))
          .toggleStyle(.kitSwitch)
          .labelsHidden()
        Menu {
          Button("Run Through This Step", systemImage: "play") { pipeline.select(step.id) }
          Button("Move Up", systemImage: "arrow.up") { pipeline.move(step.id, by: -1) }.disabled(index == 0)
          Button("Move Down", systemImage: "arrow.down") { pipeline.move(step.id, by: 1) }
            .disabled(index == pipeline.steps.count - 1)
          Button("Duplicate", systemImage: "plus.square.on.square") { pipeline.duplicate(step.id) }
          Divider()
          Button("Delete Step", systemImage: "trash", role: .destructive) { pipeline.remove(step.id) }
        } label: {
          Label("Step \(index + 1) actions", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.kitIcon)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      if step.kind.writes && !step.isEnabled {
        Text("Off while you try things out. Turn it on to write the results.")
          .kitFont(.caption)
          .padding(.leading, 52)
      }
      if selected && inlineEditor {
        StepEditor(pipeline: pipeline, browser: browser, step: step)
          .padding(.leading, 52)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background {
      if step.isEnabled {
        SurfaceShapeCard()
      }
    }
    .overlay {
      let shape = RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous)
      if selected {
        shape.strokeBorder(Hue.accent.fill, lineWidth: 2)
      } else if !step.isEnabled {
        shape.strokeBorder(.kitSeparator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      }
    }
    .opacity(step.isEnabled ? 1 : 0.8)
  }
}

/// A card's ground, for views that draw their own border over it.
private struct SurfaceShapeCard: View {
  var body: some View {
    Color.clear.kitSurface(.card)
  }
}

struct AddStepMenu: View {
  let pipeline: PipelineModel

  var body: some View {
    Menu {
      ForEach(pipeline.isSQL ? StepKind.common.filter { StepKind.sqlCompatible.contains($0) } : StepKind.common) { kind in
        Button("\(kind.name) — \(kind.does)") { pipeline.add(kind) }
      }
      if !pipeline.isSQL {
        Divider()
        Menu("More Steps") {
          ForEach(StepKind.allCases.filter { !StepKind.common.contains($0) }) { kind in
            Button("\(kind.name) — \(kind.does)") { pipeline.add(kind) }
          }
        }
      }
    } label: {
      Label("Add Step", systemImage: "plus")
    }
    .menuStyle(.button)
    .buttonStyle(.kitPlain)
    .fixedSize()
  }
}

/// The full builder's step library: every MongoDB stage, in colored groups.
struct StepLibrary: View {
  let pipeline: PipelineModel
  @State private var search = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(StepKind.groups, id: \.self) { group in
          let kinds = StepKind.allCases.filter {
            $0.group == group && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.op.localizedCaseInsensitiveContains(search))
          }
          if !kinds.isEmpty {
            StepGroupBlock(group: group, kinds: kinds) { kind in
              pipeline.add(kind, at: pipeline.selectedIndex.map { $0 + 1 })
            }
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 12)
    }
    .safeAreaInset(edge: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Steps").kitFont(.title3)
        KitSearchField(text: $search, prompt: "Search \(StepKind.allCases.count) steps")
      }
      .padding([.horizontal, .top], 12)
      .background(.kitPanel)
    }
    .safeAreaInset(edge: .bottom) {
      Text("Click a step to add it after the selected one.")
        .kitFont(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.kitPanel)
    }
  }
}

/// One library group: its tile, name and count, and its steps.
private struct StepGroupBlock: View {
  let group: String
  let kinds: [StepKind]
  let onAdd: (StepKind) -> Void

  var body: some View {
    let look = StepGroupLook(group)
    KitSection(group, meta: "\(kinds.count) \(kinds.count == 1 ? "step" : "steps")", systemImage: look.symbol, hue: look.hue) {
      ForEach(kinds) { kind in
        StepLibraryRow(kind: kind, hue: look.hue) { onAdd(kind) }
      }
    }
  }
}

private struct StepLibraryRow: View {
  let kind: StepKind
  let hue: Hue
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(kind.name).lineLimit(1)
        Spacer(minLength: 4)
        Text(kind.op).kitFont(.monoSmall).foregroundStyle(hue.text).lineLimit(1)
      }
      .padding(.horizontal, 6)
      .frame(minHeight: 26)
      .background(hovering ? AnyShapeStyle(.kitHover) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: KitMetrics.radiusSmall, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityHint(kind.does)
    .draggable(kind.rawValue)
  }
}

/// Each library group's symbol and hue.
struct StepGroupLook {
  let symbol: String
  let hue: Hue

  init(_ group: String) {
    switch group {
    case "Filter and shape": (symbol, hue) = ("line.3.horizontal.decrease", .blue)
    case "Group and count": (symbol, hue) = ("square.grid.2x2", .purple)
    case "Arrays": (symbol, hue) = ("list.bullet", .teal)
    case "Order and pages": (symbol, hue) = ("arrow.up.arrow.down", .orange)
    case "Combine": (symbol, hue) = ("arrow.triangle.merge", .green)
    case "Time and windows": (symbol, hue) = ("clock", .pink)
    case "Location": (symbol, hue) = ("mappin", .yellow)
    default: (symbol, hue) = ("square.and.arrow.down", .gray)
    }
  }
}

/// MongoDB run options in plain words.
struct PipelineSettings: View {
  @Bindable var pipeline: PipelineModel

  var body: some View {
    FormCard("Pipeline settings") {
      FormRow("Big sorts use disk", systemImage: "internaldrive", hue: .gray) {
        Toggle("Big sorts use disk", isOn: $pipeline.allowDiskUse).toggleStyle(.kitSwitch).labelsHidden()
      }
      FormRow("Time limit", systemImage: "timer", hue: .orange) {
        KitStepper("Time limit", value: $pipeline.maxTimeSeconds, in: 0...3600, step: 5) { $0 == 0 ? "none" : "\($0) s" }
      }
      FormRow("Text comparison language", systemImage: "textformat", hue: .gray) {
        TextField("Text comparison language", text: $pipeline.collationLocale, prompt: Text("e.g. en"))
          .kitField()
          .frame(width: 150)
      }
      if !pipeline.collationLocale.isEmpty {
        FormRow("Ignore case", systemImage: "textformat.size", hue: .gray) {
          Toggle("Ignore case", isOn: $pipeline.caseInsensitive).toggleStyle(.kitSwitch).labelsHidden()
        }
      }
      FormRow("Tag in server logs", systemImage: "tag", hue: .gray) {
        TextField("Tag in server logs", text: $pipeline.comment, prompt: Text("e.g. review-trends"))
          .kitField()
          .frame(width: 150)
      }
    }
  }
}

/// The selected step's output, or the pipeline as code.
struct OutputPanel: View {
  @Bindable var pipeline: PipelineModel
  let browser: BrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      RichHeader(title, meta: subtitle, size: .title, systemImage: "square.stack.3d.up", hue: browser.engine.hue,
        status: pipeline.isPreviewing ? .working : .idle) {
        KitSegmented(selection: $pipeline.showsCode, options: [("Output", false), ("Code", true)])
      }
      if pipeline.results != nil || pipeline.resultRows != nil {
        resultsView
      } else if pipeline.showsCode {
        codeView
      } else {
        previewView
      }
    }
    .padding(KitMetrics.gutter)
  }

  private var title: String {
    if pipeline.results != nil || pipeline.resultRows != nil { return "Pipeline results" }
    if let index = pipeline.selectedIndex { return "After step \(index + 1) · \(pipeline.steps[index].kind.name)" }
    return "Output"
  }

  private var subtitle: String {
    if let results = pipeline.results { return "\(results.count) documents" }
    if let rows = pipeline.resultRows { return "\(rows.rows.count) rows" }
    var parts: [String] = []
    if let count = pipeline.previewCount { parts.append("\(count.formatted()) \(pipeline.isSQL ? "rows" : "documents")") }
    parts.append("first 20 shown")
    if let elapsed = pipeline.previewElapsed { parts.append(formatDuration(elapsed)) }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder private var previewView: some View {
    if let error = pipeline.previewError {
      Banner(error, systemImage: "exclamationmark.triangle", hue: .red)
      Spacer()
    } else if pipeline.isSQL, let rows = pipeline.previewRows {
      ResultTable(fields: rows.fields, rows: rows.rows)
    } else {
      ScrollView {
        VStack(spacing: 8) {
          ForEach(Array(pipeline.preview.enumerated()), id: \.offset) { _, doc in
            DocumentPreview(document: doc)
          }
          if pipeline.preview.isEmpty && !pipeline.isPreviewing {
            Text("No documents reach this step.").foregroundStyle(.kitSecondary).padding()
          }
        }
      }
      Label("Output updates as you edit a step. Run applies the whole pipeline.", systemImage: "info.circle")
        .kitFont(.caption)
    }
  }

  private var codeView: some View {
    VStack(alignment: .leading, spacing: 8) {
      ScrollView {
        Text(pipeline.isSQL ? ((try? pipeline.sql()) ?? "") : pipeline.javaScript)
          .kitFont(.monoSmall)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .kitSurface(.card)
      Button(pipeline.isSQL ? "Copy SQL" : "Copy as JavaScript") {
        Clipboard.copy(pipeline.isSQL ? ((try? pipeline.sql()) ?? "") : pipeline.javaScript)
      }
      .buttonStyle(.kit)
    }
  }

  @ViewBuilder private var resultsView: some View {
    if let rows = pipeline.resultRows {
      ResultTable(fields: rows.fields, rows: rows.rows)
    } else if let results = pipeline.results {
      ScrollView {
        VStack(spacing: 8) {
          ForEach(Array(results.enumerated()), id: \.offset) { _, doc in DocumentPreview(document: doc) }
        }
      }
    }
    Button("Back to Step Output") { pipeline.clearResults() }.buttonStyle(.kit)
  }
}

/// A compact document: up to six fields.
struct DocumentPreview: View {
  let document: BSONDocument
  var highlight: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      ForEach(document.elements.prefix(8), id: \.key) { element in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          HStack(spacing: 4) {
            Text(element.key).foregroundStyle(.kitSecondary)
            if highlight.contains(element.key) { Chip("New", hue: .green).controlSize(.small) }
          }
          .frame(width: 120, alignment: .leading)
          Text(CellValue.bson(element.value).displayText)
            .kitFont(.monoSmall)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .kitFont(.caption)
      }
      if document.count > 8 {
        Text("+ \(document.count - 8) more fields").kitFont(.caption).foregroundStyle(.kitTertiary)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .kitSurface(.card)
  }
}

/// The full builder's right pane: edit the step, see the fields it can use and its output.
struct StepInspector: View {
  @Bindable var pipeline: PipelineModel
  let browser: BrowserModel

  var body: some View {
    KitInspector(width: nil) {
      if let step = pipeline.selectedStep, let index = pipeline.selectedIndex {
        InspectorHeader(
          "Step \(index + 1) · \(step.kind.name)", meta: [step.kind.op, step.kind.does.lowercased()],
          systemImage: StepGroupLook(step.kind.group).symbol, hue: StepGroupLook(step.kind.group).hue,
          status: pipeline.isPreviewing ? .working : .idle)
        StepEditor(pipeline: pipeline, browser: browser, step: step)
        fieldsHere
        KitSection(
          "Output of step \(index + 1)",
          meta: ["\(pipeline.previewCount?.formatted() ?? "…") documents"] + (pipeline.previewElapsed.map { [formatDuration($0)] } ?? []),
          systemImage: "doc.on.doc", hue: browser.engine.hue
        ) {
          if let error = pipeline.previewError {
            Text(error).kitFont(.caption).foregroundStyle(Hue.red.text).padding(6)
          }
          ForEach(Array(pipeline.preview.prefix(3).enumerated()), id: \.offset) { _, doc in
            DocumentPreview(document: doc, highlight: newFields(step))
          }
        }
      } else {
        EmptyState(systemImage: "square.stack.3d.up", title: "No Step Selected", message: "Pick a step to edit it.")
      }
    }
  }

  private func newFields(_ step: PipelineStep) -> Set<String> {
    if case .addFields(let formulas)? = step.form { return Set(formulas.map(\.name)) }
    return []
  }

  /// Fields seen in the step's output, with type and how often they're filled.
  @ViewBuilder private var fieldsHere: some View {
    let docs = pipeline.preview
    if !docs.isEmpty {
      let names = docs.flatMap(\.keys).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
      KitSection("Fields here", meta: "how often each is filled", systemImage: "tablecells", hue: .gray) {
        ForEach(names.prefix(14), id: \.self) { name in
          let values = docs.compactMap { $0[name] }
          let fill = Double(values.count) / Double(docs.count)
          InspectorRow(name) {
            HStack(spacing: 8) {
              if let type = values.first?.typeName { Chip(type: type).controlSize(.small) }
              MicroBar(value: fill, width: 54)
              Text(fill.formatted(.percent.precision(.fractionLength(0))))
                .kitFont(.caption)
                .frame(width: 36, alignment: .trailing)
            }
          }
        }
      }
    }
  }
}
