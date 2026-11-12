import ComponentKit
import DatabaseKit
import SwiftUI

/// A table's or collection's indexes and the changes waiting to run. Nothing runs before Apply; the last changes
/// applied can be undone, a dropped index going back as it was.
@MainActor @Observable
final class IndexesModel {
  enum Change: Identifiable, Hashable {
    case create(NewIndex)
    case drop(TableIndex)

    var id: String {
      switch self {
      case .create(let index): "create:" + index.name
      case .drop(let index): "drop:" + index.name
      }
    }
  }

  private unowned let browser: BrowserModel
  private(set) var indexes: [TableIndex] = []
  private(set) var pending: [Change] = []
  private(set) var isLoading = false
  private(set) var isApplying = false
  var errorMessage: String?
  /// What undoes the last changes applied, newest first, and what to say when it's done.
  private(set) var undoStatements: [String] = []
  private(set) var undoSummary = ""

  init(browser: BrowserModel) { self.browser = browser }

  private var session: IndexSession? { browser.session as? IndexSession }
  private var ref: ObjectRef { browser.ref }

  func load() async {
    guard let session else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      indexes = try await session.indexes(of: ref)
      errorMessage = nil
    } catch {
      errorMessage = FriendlyError.message(error)
    }
  }

  func isDropping(_ index: TableIndex) -> Bool { pending.contains(.drop(index)) }

  func stageDrop(_ index: TableIndex) {
    guard !index.isProtected, !isDropping(index) else { return }
    pending.append(.drop(index))
  }

  func revert(_ change: Change) { pending.removeAll { $0 == change } }

  /// Adds the index under its final name, the one its statement and later its undo use.
  func stageCreate(_ index: NewIndex) {
    guard let session else { return }
    var index = index
    if index.name.isEmpty { index.name = session.defaultIndexName(for: index, on: ref) }
    pending.append(.create(index))
  }

  func defaultName(for index: NewIndex) -> String { session?.defaultIndexName(for: index, on: ref) ?? "" }

  /// A name no index here has or is about to have.
  func isTaken(_ name: String) -> Bool {
    pending.contains { if case .create(let index) = $0 { index.name == name } else { false } }
      || indexes.contains { index in index.name == name && !isDropping(index) }
  }

  func statement(for change: Change) -> String {
    switch change {
    case .create(let index): session?.createStatement(for: index, on: ref) ?? ""
    case .drop(let index): index.dropStatement
    }
  }

  /// Runs the changes in order and stops at the first that fails; those before it stay applied and can be undone.
  func apply() async {
    guard let session, !pending.isEmpty else { return }
    isApplying = true
    defer { isApplying = false }
    var undo: [String] = []
    var applied = 0
    errorMessage = nil
    for change in pending {
      do {
        try await session.runIndexStatement(statement(for: change), on: ref)
        switch change {
        case .create(let index): undo.insert(session.dropStatement(forIndexNamed: index.name, on: ref), at: 0)
        case .drop(let index): undo.insert(index.restoreStatement, at: 0)
        }
        applied += 1
      } catch {
        errorMessage = FriendlyError.message(error)
        break
      }
    }
    pending.removeFirst(applied)
    if applied > 0 {
      undoStatements = undo
      undoSummary = String(localized: "\(applied) index changes")
      browser.toast = String(localized: "Applied \(undoSummary) to \(ref.name)")
    }
    let failure = errorMessage
    await load()
    if failure != nil { errorMessage = failure }
  }

  func undo() async {
    guard let session, !undoStatements.isEmpty else { return }
    isApplying = true
    defer { isApplying = false }
    do {
      for statement in undoStatements { try await session.runIndexStatement(statement, on: ref) }
      browser.toast = String(localized: "Undid \(undoSummary)")
      undoStatements = []
      await load()
    } catch {
      errorMessage = "Couldn't undo: \(FriendlyError.message(error))"
    }
  }
}

struct IndexesSheet: View {
  @Bindable var browser: BrowserModel
  @Environment(\.kitDismiss) private var dismiss
  @State private var adding = false

  private var model: IndexesModel { browser.indexes }
  private var profile: ConnectionProfile { browser.connection.profile }
  private var isEditable: Bool { browser.isEditable }

  var body: some View {
    KitSheet(title: "Indexes", meta: meta, width: 640, icon: { browser.connection.liveTile(size: 32) }) {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          indexList
          if adding {
            AddIndexCard(browser: browser) { adding = false }
          }
          statements
          if let error = model.errorMessage {
            Banner(error, systemImage: "exclamationmark.triangle", hue: .red)
          }
          if !model.undoStatements.isEmpty {
            HStack {
              NoteLine("You can undo \(model.undoSummary).", systemImage: "arrow.uturn.backward")
              Spacer()
              Button("Undo") { Task { await model.undo() } }
                .buttonStyle(.kit)
                .disabled(model.isApplying)
            }
          }
        }
      }
      .frame(minHeight: 200, idealHeight: 460, maxHeight: 560)
      .fixedSize(horizontal: false, vertical: true)
    } footer: {
      SheetStatus(summary, systemImage: "bolt.horizontal", hue: .gray, status: model.isApplying || model.isLoading ? .working : .idle)
      if isEditable {
        Button("Add Index", systemImage: "plus") { adding = true }
          .disabled(adding || browser.fields.isEmpty)
      }
      Button("Close") { dismiss() }
        .keyboardShortcut(.cancelAction)
      if isEditable {
        Button(applyTitle) { Task { await model.apply() } }
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
          .disabled(model.pending.isEmpty || model.isApplying)
      }
    }
    .task { await model.load() }
    #if DEBUG
      .onAppear { if LaunchOptions.flag("--index-add") { adding = true } }
    #endif
  }

  private var meta: LocalizedStringKey {
    profile.isProduction
      ? "\(browser.ref.name) on \(profile.displayName) (Production)" : "\(browser.ref.name) on \(profile.displayName)"
  }

  private var applyTitle: String {
    model.pending.count > 1 ? String(localized: "Apply \(model.pending.count) Changes") : String(localized: "Apply Change")
  }

  private var summary: String {
    if !model.pending.isEmpty {
      return String(localized: "\(model.pending.count) changes to apply")
    }
    return String(localized: "\(model.indexes.count) indexes")
  }

  @ViewBuilder private var indexList: some View {
    VStack(alignment: .leading, spacing: 2) {
      if model.indexes.isEmpty, !model.isLoading, model.pending.isEmpty {
        NoteLine("No indexes yet. Every search here reads the whole \(browser.engine.collectionNoun.singular).", systemImage: nil)
          .padding(8)
      }
      ForEach(model.indexes) { index in
        IndexRow(
          name: index.name, keys: index.keys, isUnique: index.isUnique, isProtected: index.isProtected,
          isDropping: model.isDropping(index), isNew: false
        ) {
          if model.isDropping(index) {
            Button("Keep") { withKitAnimation { model.revert(.drop(index)) } }.buttonStyle(.kit)
          } else if isEditable, !index.isProtected {
            Button("Drop", role: .destructive) { withKitAnimation { model.stageDrop(index) } }.buttonStyle(.kit)
          }
        }
      }
      ForEach(model.pending) { change in
        if case .create(let index) = change {
          IndexRow(
            name: index.name, keys: index.keys, isUnique: index.isUnique, isProtected: false, isDropping: false, isNew: true
          ) {
            Button("Remove") { withKitAnimation { model.revert(change) } }.buttonStyle(.kit)
          }
        }
      }
    }
    .kitCard()
  }

  @ViewBuilder private var statements: some View {
    if !model.pending.isEmpty {
      KitSection(
        browser.engine.family == .sql ? "SQL that will run" : "\(browser.engine.queryLanguage) that will run",
        meta: String(localized: "\(model.pending.count) statements"),
        systemImage: "chevron.left.forwardslash.chevron.right", hue: .gray
      ) {
        HighlightedCode(
          text: model.pending.map { model.statement(for: $0) + (browser.engine.family == .sql ? ";" : "") }.joined(separator: "\n"),
          language: browser.engine.highlighting
        )
        .kitFont(.monoSmall)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .kitSurface(.field)
        .padding(6)
      }
    }
  }
}

/// One index: its name, its fields in order with their direction, what's special about it, its action.
private struct IndexRow<Action: View>: View {
  let name: String
  let keys: [IndexKey]
  let isUnique: Bool
  let isProtected: Bool
  let isDropping: Bool
  let isNew: Bool
  @ViewBuilder var action: Action

  var body: some View {
    HStack(spacing: KitMetrics.gutter) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(name)
            .kitFont(.body)
            .strikethrough(isDropping)
            .lineLimit(1)
            .truncationMode(.middle)
          if isNew { Chip("New", hue: .green).controlSize(.small) }
          if isDropping { Chip("Will be dropped", hue: .red).controlSize(.small) }
          if isUnique { Chip("Unique", hue: .blue).controlSize(.small) }
          if isProtected { Chip("Required", systemImage: "lock").controlSize(.small) }
        }
        Text(keysText)
          .kitFont(.monoSmall)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
      action.controlSize(.small)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
  }

  private var keysText: String {
    keys.map { key in
      if let method = key.method { return "\(key.field) (\(method))" }
      return key.field + (key.isDescending ? " ↓" : " ↑")
    }
    .joined(separator: ", ")
  }
}

/// A new index: its fields in order, then a name (the engine's usual one by default) and whether it's unique.
private struct AddIndexCard: View {
  let browser: BrowserModel
  var onDone: () -> Void
  @State private var keys: [IndexKey] = []
  @State private var name = ""
  @State private var isUnique = false

  private var model: IndexesModel { browser.indexes }
  private var fieldOptions: [(LocalizedStringKey, String)] { browser.fields.map { ("\($0.name)", $0.name) } }
  private var new: NewIndex { NewIndex(name: name.trimmingCharacters(in: .whitespaces), keys: keys, isUnique: isUnique) }
  private var finalName: String { new.name.isEmpty ? model.defaultName(for: new) : new.name }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      FormCard("Add Index") {
        ForEach(keys.indices, id: \.self) { position in
          FormRow(position == 0 ? "Field" : "Then by", systemImage: "tablecells", hue: .gray) {
            HStack(spacing: 6) {
              KitPicker("Field", selection: $keys[position].field, options: fieldOptions)
              KitSegmented(selection: $keys[position].isDescending, options: [("Ascending", false), ("Descending", true)])
                .fixedSize()
              if keys.count > 1 {
                // The kit's icon button: a kit button style sets its own label style, so `.labelStyle(.iconOnly)`
                // around `.kit` still showed the title.
                Button("Remove Field", systemImage: "minus") { keys.remove(at: position) }
                  .buttonStyle(.kitIcon)
              }
            }
          }
        }
        FormRow("Name", systemImage: "character.cursor.ibeam", hue: .gray,
          field: TextField("Name", text: $name, prompt: Text(model.defaultName(for: new))))
        FormRow("Unique", help: "No two \(browser.noun.plural) can have the same values.", systemImage: "number", hue: .blue) {
          Toggle("Unique", isOn: $isUnique).toggleStyle(.kitSwitch).kitLabelsHidden()
        }
      }
      if model.isTaken(finalName) {
        Text("An index named \(finalName) already exists.")
          .kitFont(.caption)
          .foregroundStyle(Hue.orange.text)
          .padding(.horizontal, 4)
      }
      HStack {
        Button("Add Field", systemImage: "plus") { keys.append(IndexKey(field: nextField)) }
          .disabled(keys.count >= browser.fields.count)
        Spacer()
        Button("Cancel", action: onDone)
        Button("Add to Changes") {
          withKitAnimation { model.stageCreate(new) }
          onDone()
        }
        .buttonStyle(.kitPrimary)
        .disabled(keys.isEmpty || keys.contains { $0.field.isEmpty } || Set(keys.map(\.field)).count != keys.count || model.isTaken(finalName))
      }
      .controlSize(.small)
    }
    // The fields can arrive after the card does.
    .task(id: browser.fields.map(\.name)) {
      if keys.isEmpty { keys = [IndexKey(field: "")] }
      for position in keys.indices where keys[position].field.isEmpty { keys[position].field = nextField }
    }
  }

  /// The first field not in the index yet, skipping the key, which is indexed already.
  private var nextField: String {
    let unused = browser.fields.filter { field in !keys.contains { $0.field == field.name } }
    return unused.first { !$0.isPrimaryKey }?.name ?? unused.first?.name ?? ""
  }
}
