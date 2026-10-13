import DatabaseProKit
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
      Divider()
      if pipeline.showsFullBuilder && !pipeline.isSQL {
        HStack(spacing: 0) {
          StepLibrary(pipeline: pipeline).frame(width: 260)
          Divider()
          stepList.frame(minWidth: 360)
          Divider()
          StepInspector(pipeline: pipeline, browser: browser).frame(minWidth: 270, idealWidth: 400)
        }
      } else {
        HStack(spacing: 0) {
          stepList.frame(minWidth: 420)
          Divider()
          OutputPanel(pipeline: pipeline, browser: browser).frame(minWidth: 320, idealWidth: 400)
        }
      }
    }
    .task {
      if pipeline.steps.isEmpty { pipeline.add(.match) } else { await pipeline.refreshPreview() }
    }
    .sheet(isPresented: $importing) { importSheet.appButtonShape() }
  }

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Pipeline").font(.headline)
        Text("Each step works on what the step above passes down. Click a step to see its output.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if !pipeline.isSQL {
        Toggle(isOn: $pipeline.showsFullBuilder) {
          Label("All Steps", systemImage: "square.grid.2x2")
        }
        .help("Show every MongoDB step, settings and formulas")
      }
      Button("Import…") {
        importText = ""
        importing = true
      }
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
      .fixedSize()
      Button {
        Task { await pipeline.run() }
      } label: {
        Label("Run", systemImage: "play.fill")
      }
      .buttonStyle(.borderedProminent)
      .help("Run the whole pipeline (⌘↩)")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var stepList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(pipeline.steps.enumerated()), id: \.element.id) { index, step in
          StepCard(pipeline: pipeline, browser: browser, step: step, index: index, inlineEditor: !pipeline.showsFullBuilder)
          if index < pipeline.steps.count - 1 {
            Rectangle().fill(.separator).frame(width: 2, height: 14).padding(.leading, 44)
          }
        }
        AddStepMenu(pipeline: pipeline)
          .padding(.top, 12)
        if pipeline.showsFullBuilder && !pipeline.isSQL {
          PipelineSettings(pipeline: pipeline).padding(.top, 16)
        }
        if let error = pipeline.resultError {
          Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.top, 12)
        }
        if pipeline.isSQL {
          Text("Pipelines on SQL tables become one SELECT, shown under Code.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 14)
        }
      }
      .padding(16)
    }
  }

  private var importSheet: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 8) {
        Text("Paste db.collection.aggregate([…]), a JSON array of stages, or stages separated by commas.")
          .font(.callout)
          .foregroundStyle(.secondary)
        CodeEditor(text: $importText, language: EngineKind.mongodb.highlighting, completions: [])
          .frame(minHeight: 240)
          .groupBox()
        if let importError { Text(importError).foregroundStyle(.red).font(.caption) }
      }
      .padding()
      .navigationTitle("Import Pipeline")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { importing = false } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Import") {
            do {
              try pipeline.importText(importText)
              importing = false
            } catch {
              importError = FriendlyError.message(error)
            }
          }
        }
      }
    }
    .frame(minWidth: 520, minHeight: 380)
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
        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
        Button {
          pipeline.select(step.id)
        } label: {
          HStack(spacing: 8) {
            Text("\(index + 1)")
              .font(.caption.bold())
              .foregroundStyle(selected ? Color.white : Color.primary)
              .frame(width: 22, height: 22)
              .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
            Text(step.kind.name).fontWeight(.bold)
            Text(step.kind.op).font(.codeSmall).foregroundStyle(.secondary)
            Text("· " + pipeline.summary(step)).foregroundStyle(.secondary).lineLimit(1)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Spacer(minLength: 4)
        if let count = pipeline.counts[step.id], step.isEnabled {
          Text("\(count.formatted()) out").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else if !step.isEnabled {
          Text("Off").font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Step \(index + 1) on", isOn: Binding(get: { step.isEnabled }, set: { on in pipeline.update(step.id) { $0.isEnabled = on } }))
          .toggleStyle(.switch)
          .labelsHidden()
          .controlSize(.mini)
        Menu {
          Button("Run Through This Step", systemImage: "play") { pipeline.select(step.id) }
          Button("Move Up", systemImage: "arrow.up") { pipeline.move(step.id, by: -1) }.disabled(index == 0)
          Button("Move Down", systemImage: "arrow.down") { pipeline.move(step.id, by: 1) }
            .disabled(index == pipeline.steps.count - 1)
          Button("Duplicate", systemImage: "plus.square.on.square") { pipeline.duplicate(step.id) }
          Divider()
          Button("Delete Step", systemImage: "trash", role: .destructive) { pipeline.remove(step.id) }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Step \(index + 1) actions")
      }
      if step.kind.writes && !step.isEnabled {
        Text("Off while you try things out. Turn it on to write the results.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 52)
      }
      if selected && inlineEditor {
        StepEditor(pipeline: pipeline, browser: browser, step: step)
          .padding(.leading, 52)
      }
    }
    .padding(12)
    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(step.isEnabled ? 0.25 : 0.4), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: step.isEnabled ? [] : [4, 3])))
    .opacity(step.isEnabled ? 1 : 0.8)
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
    .menuStyle(.borderlessButton)
    .fixedSize()
    .buttonStyle(DashedCapsuleStyle())
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
        Text("Steps").font(.headline)
        SearchField(text: $search, prompt: "Search \(StepKind.allCases.count) steps")
      }
      .padding([.horizontal, .top], 12)
      .background(.background)
    }
    .safeAreaInset(edge: .bottom) {
      Text("Click a step to add it after the selected one.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background)
    }
    .background(.background)
  }
}

/// One library group: a colored icon, its name and count, and its steps.
private struct StepGroupBlock: View {
  let group: String
  let kinds: [StepKind]
  let onAdd: (StepKind) -> Void

  var body: some View {
    let look = StepGroupLook(group)
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 8) {
        Image(systemName: look.symbol)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(look.ink)
          .frame(width: 22, height: 22)
          .background(look.ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .accessibilityHidden(true)
        Text(group).font(.callout.weight(.semibold))
        Spacer()
        Text("\(kinds.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      .padding(.horizontal, 4)
      .padding(.top, 2)
      .padding(.bottom, 3)
      ForEach(kinds) { kind in
        StepLibraryRow(kind: kind, ink: look.ink) { onAdd(kind) }
      }
    }
    .padding(4)
    .groupBox()
  }
}

private struct StepLibraryRow: View {
  let kind: StepKind
  let ink: Color
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(kind.name).lineLimit(1)
        Spacer(minLength: 4)
        Text(kind.op).font(.codeSmall).foregroundStyle(ink).lineLimit(1)
      }
      .padding(.horizontal, 6)
      .frame(minHeight: 26)
      .background(hovering ? ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(kind.does)
    .draggable(kind.rawValue)
  }
}

/// Each library group's symbol and color. Light mode uses dark inks that read on white; dark mode lighter ones.
struct StepGroupLook {
  let symbol: String
  let ink: Color

  init(_ group: String) {
    switch group {
    case "Filter and shape": (symbol, ink) = ("line.3.horizontal.decrease", Color(light: 0x0B4A8F, dark: 0x6CA8F0))
    case "Group and count": (symbol, ink) = ("square.grid.2x2", Color(light: 0x5E2A84, dark: 0xC597E8))
    case "Arrays": (symbol, ink) = ("list.bullet", Color(light: 0x0F5E5A, dark: 0x5CC8C0))
    case "Order and pages": (symbol, ink) = ("arrow.up.arrow.down", Color(light: 0x93370D, dark: 0xF2A27A))
    case "Combine": (symbol, ink) = ("arrow.triangle.merge", Color(light: 0x1E6B35, dark: 0x6CCB86))
    case "Time and windows": (symbol, ink) = ("clock", Color(light: 0x8A2456, dark: 0xEE8DB9))
    case "Location": (symbol, ink) = ("mappin", Color(light: 0x6B5200, dark: 0xE3C35A))
    default: (symbol, ink) = ("square.and.arrow.down", Color(light: 0x3A3A3F, dark: 0xAEAEB2))
    }
  }
}

/// MongoDB run options in plain words.
struct PipelineSettings: View {
  @Bindable var pipeline: PipelineModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Pipeline settings").font(.callout.weight(.semibold))
      Form {
        Toggle("Big sorts use disk", isOn: $pipeline.allowDiskUse)
        Stepper("Time limit: \(pipeline.maxTimeSeconds == 0 ? "none" : "\(pipeline.maxTimeSeconds) s")", value: $pipeline.maxTimeSeconds, in: 0...3600, step: 5)
        TextField("Text comparison language", text: $pipeline.collationLocale, prompt: Text("e.g. en"))
        if !pipeline.collationLocale.isEmpty {
          Toggle("Ignore case", isOn: $pipeline.caseInsensitive)
        }
        TextField("Tag in server logs", text: $pipeline.comment, prompt: Text("e.g. review-trends"))
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .frame(minHeight: 220)
    }
  }
}

/// The selected step's output, or the pipeline as code.
struct OutputPanel: View {
  @Bindable var pipeline: PipelineModel
  let browser: BrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.headline)
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Picker("Show", selection: $pipeline.showsCode) {
          Text("Output").tag(false)
          Text("Code").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      if pipeline.results != nil || pipeline.resultRows != nil {
        resultsView
      } else if pipeline.showsCode {
        codeView
      } else {
        previewView
      }
    }
    .padding(16)
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
      Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
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
            Text("No documents reach this step.").foregroundStyle(.secondary).padding()
          }
        }
      }
      .overlay { if pipeline.isPreviewing { ProgressView() } }
      Label("Output updates as you edit a step. Run applies the whole pipeline.", systemImage: "info.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var codeView: some View {
    VStack(alignment: .leading, spacing: 8) {
      ScrollView {
        Text(pipeline.isSQL ? ((try? pipeline.sql()) ?? "") : pipeline.javaScript)
          .font(.codeSmall)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .groupBox()
      Button(pipeline.isSQL ? "Copy SQL" : "Copy as JavaScript") {
        Clipboard.copy(pipeline.isSQL ? ((try? pipeline.sql()) ?? "") : pipeline.javaScript)
      }
      .buttonStyle(.bordered)
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
    Button("Back to Step Output") { pipeline.clearResults() }.buttonStyle(.bordered)
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
            Text(element.key).foregroundStyle(.secondary)
            if highlight.contains(element.key) { TagLabel(text: "NEW", color: .green) }
          }
          .frame(width: 120, alignment: .leading)
          Text(CellValue.bson(element.value).displayText)
            .font(.codeSmall)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .font(.caption)
      }
      if document.count > 8 {
        Text("+ \(document.count - 8) more fields").font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .groupBox()
  }
}

/// The full builder's right pane: edit the step, see the fields it can use and its output.
struct StepInspector: View {
  @Bindable var pipeline: PipelineModel
  let browser: BrowserModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let step = pipeline.selectedStep, let index = pipeline.selectedIndex {
          VStack(alignment: .leading, spacing: 2) {
            Text("Step \(index + 1) · \(step.kind.name)").font(.title3.bold())
            HStack(spacing: 4) {
              Text(step.kind.op).font(.codeSmall)
              Text("· " + step.kind.does.lowercased())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          StepEditor(pipeline: pipeline, browser: browser, step: step)
          fieldsHere
          VStack(alignment: .leading, spacing: 6) {
            Text("Output of step \(index + 1) · \(pipeline.previewCount?.formatted() ?? "…") documents\(pipeline.previewElapsed.map { " · " + formatDuration($0) } ?? "")")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            if let error = pipeline.previewError {
              Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
            }
            ForEach(Array(pipeline.preview.prefix(3).enumerated()), id: \.offset) { _, doc in
              DocumentPreview(document: doc, highlight: newFields(step))
            }
          }
        } else {
          ContentUnavailableView("No Step Selected", systemImage: "square.stack.3d.up", description: Text("Pick a step to edit it."))
        }
      }
      .padding(16)
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
      VStack(alignment: .leading, spacing: 6) {
        Text("Fields here · how often each is filled").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        VStack(spacing: 0) {
          ForEach(names.prefix(14), id: \.self) { name in
            let values = docs.compactMap { $0[name] }
            let fill = Double(values.count) / Double(docs.count)
            HStack(spacing: 8) {
              Text(name).font(.codeSmall).lineLimit(1)
              Spacer()
              if let type = values.first?.typeName { TypeBadge(type) }
              ProgressView(value: fill).frame(width: 54).tint(.blue)
              Text(fill.formatted(.percent.precision(.fractionLength(0)))).font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
          }
        }
        .padding(.vertical, 4)
        .groupBox()
      }
    }
  }
}
