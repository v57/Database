import MongoDB
import SQLQuery
import SwiftUI
import UniformTypeIdentifiers

/// Which query surface the documents pane shows: the Filter/Sort/Project bar,
/// or the aggregation pipeline builder.
enum QueryMode: String, CaseIterable, Identifiable {
  case find, aggregate

  var id: String { rawValue }

  var name: String {
    switch self {
    case .find: "Find"
    case .aggregate: "Aggregate"
    }
  }

  var symbol: String {
    switch self {
    case .find: "magnifyingglass"
    case .aggregate: "square.stack.3d.up"
    }
  }
}

/// Aggregation pipeline builder: an ordered list of stage cards (operator +
/// shell-syntax argument), with JavaScript import/export. MongoDB runs the
/// stages as-is; SQL engines compile them to one SELECT (SQLPipelineCompiler)
/// and show that SQL under the stages. The stage TEXT is the source of truth —
/// like the Find bar's Filter field — and is parsed when the pipeline runs.
struct AggregationBuilderView: View {
  @Environment(DatabaseModel.self) private var model
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @Binding var stages: [PipelineStage]
  /// Loaded fields: new stages name the first one instead of a placeholder.
  let fields: [FieldInfo]
  let isRunning: Bool
  /// The stages differ from what produced the shown results.
  let hasUnappliedChanges: Bool
  /// Runs the pipeline; with an index, only the stages up to and including it.
  let onRun: (_ throughStage: Int?) -> Void

  @State private var isImporting = false
  @State private var isExportingFile = false
  @State private var showsSQL = false
  /// Says where an imported pipeline came from when that wasn't this collection.
  @State private var importNote: String?
  @State private var listHeight: CGFloat = 0

  private var collection: String { model.selectedCollection ?? "collection" }
  private var isSQL: Bool { model.activeEngine == .postgresql || model.activeEngine == .sqlite }

  /// Stage kinds this engine can run (SQL compiles a subset).
  private var stageKinds: [AggregationPipeline.StageKind] {
    guard isSQL else { return AggregationPipeline.stageKinds }
    return AggregationPipeline.stageKinds.filter { SQLPipelineCompiler.supportedStages.contains($0.name) }
  }

  /// The SQL the enabled stages compile to, or why they don't. nil while a
  /// stage doesn't parse: its card already says so.
  private var compiledSQL: Result<String, Error>? {
    guard isSQL, let documents = try? AggregationPipeline.documents(stages) else { return nil }
    do {
      guard let sql = try model.pipelineSQL(documents) else { return nil }
      return .success(sql)
    } catch {
      return .failure(error)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      if let importNote {
        HStack(alignment: .firstTextBaseline) {
          Label(importNote, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
          Button("Dismiss", systemImage: "xmark.circle") { self.importNote = nil }
            .buttonStyle(.plain).labelStyle(.iconOnly).foregroundStyle(.secondary)
        }
      }
      if stages.isEmpty {
        Text(
          "An empty pipeline returns every \(model.itemNoun.singular). Add a stage, or import a pipeline from JavaScript."
        ).font(.caption).foregroundStyle(.secondary)
      } else {
        stageList
      }
      if isSQL { sqlSection }
    }
    .sheet(isPresented: $isImporting) {
      PipelineImportSheet(onCancel: { isImporting = false }, onImport: importPipeline)
    }
    .fileExporter(
      isPresented: $isExportingFile, document: JavaScriptFile(text: javaScript),
      contentType: .javaScript, defaultFilename: "\(collection)-pipeline.js"
    ) { _ in }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Text("Pipeline").font(.caption).foregroundStyle(.secondary)
      if !stages.isEmpty {
        let enabled = stages.filter(\.isEnabled).count
        Text(
          enabled == stages.count
            ? "\(stages.count) \(stages.count == 1 ? "stage" : "stages")"
            : "\(enabled) of \(stages.count) on")
          .font(.caption).foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
      addStageMenu
      Button("Import…", systemImage: "square.and.arrow.down") { isImporting = true }
        .help("Import a pipeline from mongosh / JavaScript")
      exportMenu
      runButton
    }
    // Four titled buttons wrap at phone width; icons alone still read there.
    .labelStyle(HeaderLabelStyle(iconOnly: horizontalSizeClass == .compact))
    .buttonStyle(.borderless)
    .font(.caption)
    .lineLimit(1)
  }

  private var addStageMenu: some View {
    Menu {
      ForEach(stageKinds) { kind in
        Button {
          stages.append(AggregationPipeline.stage(kind, field: templateField))
        } label: {
          Text(kind.name)
          Text(kind.summary)
        }
      }
      if isSQL {
        Divider()
        Text("Other stages have no SQL equivalent")
      }
    } label: {
      Label("Add Stage", systemImage: "plus")
    }.menuStyle(.borderlessButton).fixedSize().help("Append a stage to the pipeline")
  }

  private var exportMenu: some View {
    Menu {
      Button("Copy as JavaScript", systemImage: "doc.on.doc") { Clipboard.copy(javaScript) }
      Button("Save as JavaScript File…", systemImage: "square.and.arrow.down") {
        isExportingFile = true
      }
      if isSQL {
        Divider()
        Button("Copy SQL", systemImage: "doc.on.doc") {
          if case .success(let sql) = compiledSQL { Clipboard.copy(sql) }
        }.disabled(!sqlCompiles)
      }
    } label: {
      Label("Export", systemImage: "square.and.arrow.up")
    }.menuStyle(.borderlessButton).fixedSize().disabled(stages.isEmpty)
      .help("Export the pipeline as a mongosh script")
  }

  private var sqlCompiles: Bool {
    if case .success = compiledSQL { return true }
    return false
  }

  @ViewBuilder private var runButton: some View {
    if isRunning {
      ProgressView().controlSize(.small)
    } else {
      Button {
        onRun(nil)
      } label: {
        Label("Run", systemImage: hasUnappliedChanges ? "play.circle.fill" : "play.circle")
      }
      .keyboardShortcut(.return, modifiers: .command)
      .help(hasUnappliedChanges ? "Run the edited pipeline (⌘↩)" : "Run the pipeline again (⌘↩)")
    }
  }

  /// The field new stages name: the first one that isn't a row id, since
  /// grouping or sorting by a unique id is rarely the point.
  private var templateField: String? {
    (fields.first { $0.name != "_id" && $0.name != "id" } ?? fields.first)?.name
  }

  /// mongosh script for every stage (disabled ones commented out).
  private var javaScript: String { AggregationPipeline.javaScript(stages, collection: collection) }

  // MARK: - Stages

  /// Cards in a scroll view as tall as its content, capped so a long
  /// pipeline doesn't push the results off screen.
  private var stageList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
          PipelineStageCard(
            stage: binding(for: stage.id),
            index: index,
            count: stages.count,
            kinds: stageKinds,
            field: templateField,
            unsupportedReason: unsupportedReason(stage),
            onMove: { move(stage.id, by: $0) },
            onDuplicate: { duplicate(stage.id) },
            onDelete: { stages.removeAll { $0.id == stage.id } },
            onRunThrough: { onRun(index) })
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
    }
    .frame(height: min(max(listHeight, 1), horizontalSizeClass == .compact ? 260 : 380))
    .scrollBounceBehavior(.basedOnSize)
  }

  /// Why a stage can't run here, if it can't: SQL engines compile a subset.
  private func unsupportedReason(_ stage: PipelineStage) -> String? {
    if AggregationPipeline.writeStages.contains(stage.name) {
      return "\(stage.name) writes to the database; the builder doesn't run it."
    }
    guard isSQL, !SQLPipelineCompiler.supportedStages.contains(stage.name) else { return nil }
    return "\(stage.name) has no SQL equivalent — disable or remove it to run on a table."
  }

  private func binding(for id: UUID) -> Binding<PipelineStage> {
    Binding(
      get: { stages.first { $0.id == id } ?? PipelineStage(name: "$match", body: "{}") },
      set: { stage in
        guard let index = stages.firstIndex(where: { $0.id == id }) else { return }
        var straightened = stage
        // iOS curls typed quotes, which no parser accepts.
        if let plain = stage.body.withStraightQuotes { straightened.body = plain }
        stages[index] = straightened
      })
  }

  private func move(_ id: UUID, by offset: Int) {
    guard let index = stages.firstIndex(where: { $0.id == id }),
      stages.indices.contains(index + offset)
    else { return }
    stages.swapAt(index, index + offset)
  }

  private func duplicate(_ id: UUID) {
    guard let index = stages.firstIndex(where: { $0.id == id }) else { return }
    var copy = stages[index]
    copy.id = UUID()
    stages.insert(copy, at: index + 1)
  }

  // MARK: - SQL preview

  @ViewBuilder private var sqlSection: some View {
    switch compiledSQL {
    case .success(let sql):
      DisclosureGroup(isExpanded: $showsSQL) {
        Text(sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
      } label: {
        Text("SQL").font(.caption).foregroundStyle(.secondary)
      }
    case .failure(let error):
      Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    case nil:
      EmptyView()
    }
  }

  // MARK: - Import

  private func importPipeline(_ imported: PipelineImport) {
    stages = imported.stages
    isImporting = false
    if let source = imported.collection, source != collection {
      importNote = "Imported from “\(source)” — runs against “\(collection)”."
    } else {
      importNote = nil
    }
    onRun(nil)
  }
}

/// Title and icon, or only the icon (the title stays the accessibility label).
private struct HeaderLabelStyle: LabelStyle {
  let iconOnly: Bool

  @ViewBuilder func makeBody(configuration: Configuration) -> some View {
    if iconOnly {
      Label(configuration).labelStyle(.iconOnly).touchTarget(32)
    } else {
      Label(configuration).labelStyle(.titleAndIcon)
    }
  }
}

// MARK: - Stage card

/// One stage: enable toggle, operator menu, argument editor and its parse
/// error, plus a menu to reorder/duplicate/run up to here/delete.
private struct PipelineStageCard: View {
  @Binding var stage: PipelineStage
  let index: Int
  let count: Int
  let kinds: [AggregationPipeline.StageKind]
  let field: String?
  let unsupportedReason: String?
  let onMove: (Int) -> Void
  let onDuplicate: () -> Void
  let onDelete: () -> Void
  let onRunThrough: () -> Void

  /// The argument's parse error, re-checked as it is typed.
  private var parseError: String? {
    do {
      _ = try stage.value()
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Button {
          stage.isEnabled.toggle()
        } label: {
          Label(
            stage.isEnabled ? "Disable stage" : "Enable stage",
            systemImage: stage.isEnabled ? "checkmark.circle.fill" : "circle"
          ).labelStyle(.iconOnly).touchTarget(28)
        }.buttonStyle(.plain).foregroundStyle(stage.isEnabled ? Color.accentColor : .secondary)
          .help(stage.isEnabled ? "Skip this stage when running" : "Run this stage again")

        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)

        operatorMenu

        if let summary = kinds.first(where: { $0.name == stage.name })?.summary {
          Text(summary).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        Spacer(minLength: 0)
        actionsMenu
      }

      TextField("Stage", text: $stage.body, prompt: Text("{ … }"), axis: .vertical)
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1...12)
        .textFieldStyle(.roundedBorder)
        .plainTextEntry()
        .opacity(stage.isEnabled ? 1 : 0.5)

      if let message = unsupportedReason, stage.isEnabled {
        Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
      } else if let parseError {
        Label(parseError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
    .padding(8)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
  }

  /// Changing the operator swaps in its starter text only while the argument
  /// is still the old operator's untouched starter text (or empty).
  private var operatorMenu: some View {
    Menu {
      ForEach(kinds) { kind in
        Button {
          let oldTemplate = kinds.first { $0.name == stage.name }?.template(field: field)
          let isUntouched =
            stage.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || stage.body == oldTemplate
          stage.name = kind.name
          if isUntouched { stage.body = kind.template(field: field) }
        } label: {
          Text(kind.name)
          Text(kind.summary)
        }
      }
    } label: {
      Text(stage.name).font(.callout.monospaced().bold())
    }.menuStyle(.borderlessButton).fixedSize().help("Stage operator")
  }

  private var actionsMenu: some View {
    Menu {
      Button("Run Through This Stage", systemImage: "play.circle") { onRunThrough() }
      Divider()
      Button("Move Up", systemImage: "arrow.up") { onMove(-1) }.disabled(index == 0)
      Button("Move Down", systemImage: "arrow.down") { onMove(1) }.disabled(index == count - 1)
      Button("Duplicate", systemImage: "plus.square.on.square") { onDuplicate() }
      Divider()
      Button("Delete Stage", systemImage: "trash", role: .destructive) { onDelete() }
    } label: {
      Label("Stage \(index + 1) actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        .touchTarget(28)
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .help("Reorder, duplicate, run up to here or delete")
  }
}

// MARK: - Import sheet

/// Paste or open a mongosh / JavaScript pipeline. Accepts an `aggregate([...])`
/// call, `const pipeline = [...]` or a bare JSON array; type helpers like
/// `ObjectId(…)`/`ISODate(…)` and comments are understood.
private struct PipelineImportSheet: View {
  let onCancel: () -> Void
  let onImport: (PipelineImport) -> Void

  @State private var text = ""
  @State private var errorMessage: String?
  @State private var isOpeningFile = false

  private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
#if os(iOS)
    // A phone-width sheet: title and actions live in the navigation bar.
    NavigationStack {
      content.padding()
        .navigationTitle("Import Pipeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Import") { importText() }.disabled(isEmpty)
          }
        }
    }
#else
    VStack(alignment: .leading, spacing: 12) {
      Text("Import Pipeline").font(.headline)
      content
    }
    .padding(20)
    .frame(minWidth: 520, minHeight: 360)
#endif
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Paste a mongosh script — db.collection.aggregate([...]) — or an array of stages. "
          + "It replaces the current pipeline."
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      TextEditor(text: $text)
        .font(.system(.callout, design: .monospaced))
        .plainTextEntry()
        .frame(minHeight: 220)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .onChange(of: text) { _, newText in
          errorMessage = nil
          if let plain = newText.withStraightQuotes { text = plain }
        }
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button("Open File…", systemImage: "doc.badge.plus") { isOpeningFile = true }
#if os(macOS)
        Spacer()
        Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        Button("Import") { importText() }.keyboardShortcut(.defaultAction).disabled(isEmpty)
#endif
      }
    }
    .fileImporter(
      isPresented: $isOpeningFile, allowedContentTypes: [.javaScript, .json, .plainText]
    ) { result in
      do {
        let url = try result.get()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        text = try String(contentsOf: url, encoding: .utf8)
      } catch {
        errorMessage = "Couldn't read the file: \(error.localizedDescription)"
      }
    }
  }

  private func importText() {
    do {
      let imported = try AggregationPipeline.importJavaScript(text)
      onImport(imported)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// A `.js` file for the "Save as JavaScript File…" exporter.
struct JavaScriptFile: FileDocument {
  static let readableContentTypes: [UTType] = [.javaScript]

  var text: String

  init(text: String) { self.text = text }

  init(configuration: ReadConfiguration) throws {
    text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}
