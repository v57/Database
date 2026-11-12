import ComponentKit
import DatabaseKit
import SwiftUI

/// A key or a group of keys sharing a prefix.
struct KeyRow: Identifiable, Hashable {
  var id: String
  var label: String
  var record: Record?
  var children: [KeyRow]?
  var count: Int = 0
}

/// The selected key's value and the changes made to it.
@Observable @MainActor
final class RedisKeyModel {
  let browser: BrowserModel
  var key: String? {
    didSet { if key != oldValue { Task { await load() } } }
  }
  private(set) var value: RedisValue = .none
  private(set) var total = 0
  private(set) var ttl: Int64 = -1
  private(set) var isLoading = false
  var error: String?
  /// Changes waiting for confirmation on production connections.
  var confirming: [RedisMutation] = []
  private var undos: [(RedisUndo, String)] = []

  init(browser: BrowserModel) { self.browser = browser }

  var session: RedisBrowsing? { browser.session as? RedisBrowsing }
  var canUndo: Bool { !undos.isEmpty }

  func load() async {
    guard let session, let key else {
      value = .none
      return
    }
    Activity.begin()
    defer { Activity.end() }
    isLoading = true
    defer { isLoading = false }
    do {
      (value, total) = try await session.value(of: key, in: browser.ref, limit: 500)
      ttl = try await session.ttl(of: key, in: browser.ref)
      error = nil
    } catch {
      self.error = FriendlyError.message(error)
    }
  }

  /// Runs changes now, or asks first on a production connection.
  func perform(_ mutations: [RedisMutation]) async {
    if browser.connection.profile.isProduction && confirming.isEmpty {
      confirming = mutations
      return
    }
    confirming = []
    guard let session else { return }
    do {
      for mutation in mutations {
        let undo = try await session.mutate(mutation, in: browser.ref)
        undos.append((undo, describe(mutation)))
      }
      browser.toast = mutations.count == 1 ? describe(mutations[0]) : "Made \(mutations.count) changes"
      if case .rename(_, let to)? = mutations.last { key = to }
      if case .delete? = mutations.last { key = nil }
      await browser.load()
      await load()
      error = nil
    } catch {
      self.error = FriendlyError.message(error)
    }
  }

  func undoLast() async {
    guard let session, let (undo, text) = undos.popLast() else { return }
    do {
      try await session.undo(undo, in: browser.ref)
      browser.toast = "Undid: \(text)"
      key = undo.key
      await browser.load()
      await load()
    } catch {
      self.error = "Couldn't undo: \(FriendlyError.message(error))"
    }
  }

  func describe(_ mutation: RedisMutation) -> String {
    switch mutation {
    case .delete(let key): String(localized: "Deleted \(key)")
    case .rename(let key, let to): String(localized: "Renamed \(key) to \(to)")
    case .expire(let key, let seconds?): String(localized: "\(key) expires in \(formatTTLDuration(seconds: Int64(seconds)))")
    case .expire(let key, nil): String(localized: "\(key) no longer expires")
    default: String(localized: "Changed \(mutation.key)")
    }
  }
}

struct KeysBrowserView: View {
  @Bindable var browser: BrowserModel
  @Bindable var window: WindowModel
  @State private var model: RedisKeyModel?
  @State private var creating = false
  @State private var commandLine = false
  /// Groups ("cart:") that are open.
  @State private var expanded: Set<String> = []
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.showToast) private var toast

  static let types: [(String, String?)] = [
    ("All", nil), ("String", "string"), ("Hash", "hash"), ("List", "list"), ("Set", "set"), ("Sorted Set", "zset"),
    ("Stream", "stream"), ("JSON", "json"),
  ]

  var body: some View {
    split
      .kitToolbar(
        browser.ref.name, meta: [browser.connection.profile.displayName, "\(keyCount) keys"], systemImage: "key",
        hue: browser.engine.hue, status: browser.isLoading && browser.page != nil ? .working : .idle
      ) {
        tools
      }
      .kitSheet(isPresented: $creating) {
        if let model { NewKeySheet(model: model).componentKit(accent: .databaseAccent) }
      }
      .kitSheet(isPresented: isConfirming) {
        if let model { RedisConfirmSheet(model: model).componentKit(accent: .databaseAccent) }
      }
      .onChange(of: browser.toast) { _, message in showToast(message) }
      .onAppear {
        if model == nil { model = RedisKeyModel(browser: browser) }
      }
  }

  private var split: some View {
    InspectorSplit("keyInspectorWidth", range: 280...560, isShown: window.showsInspector && sizeClass != .compact) {
      main
    } pane: {
      inspector
    } over: {
      if let model, model.key != nil { RedisValueView(model: model) }
    }
  }

  @ViewBuilder private var inspector: some View {
    if let model, model.key != nil {
      RedisValueView(model: model)
    } else {
      EmptyState(systemImage: "key", title: "No Key Selected", message: "Select a key to see and edit its value.")
        .kitPane(.secondary)
    }
  }

  private var keyCount: Int { browser.exactTotal ?? browser.page?.total ?? 0 }

  private var main: some View {
    VStack(spacing: 0) {
      HStack(spacing: KitMetrics.gutter) {
        RedisKeySearch(browser: browser)
        ScrollView(.horizontal, showsIndicators: false) {
          KitSegmented(selection: typeFilter, options: Self.types.map { ($0.0, $0.1) })
            .padding(2)
        }
      }
      .padding(.horizontal, KitMetrics.gutter)
      .padding(.vertical, 6)
      if commandLine {
        RedisCommandLine(browser: browser)
      }
      if let error = browser.errorMessage {
        Banner(error, systemImage: "exclamationmark.triangle", hue: .red, onDismiss: { browser.errorMessage = nil })
          .padding([.horizontal, .bottom], KitMetrics.gutter)
      }
      ForEach(browser.page?.notes ?? [], id: \.self) {
        Banner($0, systemImage: "info.circle", hue: .gray).padding([.horizontal, .bottom], KitMetrics.gutter)
      }
      if sizeClass == .compact {
        // A phone has no room for the grid's columns or the inspector: a list whose rows push the key (D-010).
        PhoneKeyList(browser: browser, model: model)
      } else {
        RedisKeyList(browser: browser, model: model, expanded: $expanded)
          .padding(.horizontal, KitMetrics.gutter)
      }
      StatusBar {
        if sizeClass != .compact { Text("Keys are grouped by the “:” in their names") }
        Text(browser.pageLabel)
        if sizeClass != .compact, let elapsed = browser.page?.elapsed {
          Text("scanned in \(formatDuration(elapsed))").foregroundStyle(.kitTertiary)
        }
        Spacer()
        Button("Previous Page", systemImage: "chevron.left") { Task { await browser.previousPage() } }
          .disabled(browser.request.offset == 0)
        Button("Next Page", systemImage: "chevron.right") { Task { await browser.nextPage() } }
          .disabled(browser.page?.hasMore != true)
      }
      .buttonStyle(.kitIcon)
      .padding(.top, KitMetrics.gutter)
    }
    .kitPane(.content)
  }

  @ToolbarSlotBuilder private var tools: [ToolbarSlot] {
    ToolGroup(iconOnly: true) {
      Button(commandLine ? "Hide Command Line" : "Show Command Line", systemImage: "apple.terminal") {
        commandLine.toggle()
      }
      .kitToolOn(commandLine)
      Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
      if browser.isEditable {
        Button("Add Key", systemImage: "plus") { creating = true }
      }
      // The Mac has View › Show Inspector; an iPad only this (D-014).
      if idiom != .mac, sizeClass != .compact {
        Button(window.showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") {
          withKitAnimation { window.showsInspector.toggle() }
        }
        .kitToolOn(window.showsInspector)
      }
    }
  }

  private func refresh() {
    Task {
      await browser.reload()
      await model?.load()
    }
  }

  private var typeFilter: Binding<String?> {
    Binding(
      get: { browser.request.keyType },
      set: { type in
        browser.request.keyType = type
        Task { await browser.reload() }
      })
  }

  private var isConfirming: Binding<Bool> {
    Binding(get: { model?.confirming.isEmpty == false }, set: { if !$0 { model?.confirming = [] } })
  }

  private func showToast(_ message: String?) {
    guard let message else { return }
    let model = model
    var undo: (@MainActor () -> Void)?
    if model?.canUndo == true {
      undo = { @MainActor in
        Task { @MainActor in await model?.undoLast() }
      }
    }
    toast(Toast(message, systemImage: "checkmark", duration: .seconds(8), undo: undo))
    browser.toast = nil
  }
}

/// The key search over the list. A view of its own with its own text, so a keystroke redraws the field alone, not the
/// list, the inspector and the bar around them.
private struct RedisKeySearch: View {
  let browser: BrowserModel
  @State private var searchText = ""

  var body: some View {
    KitSearchField(text: $searchText, prompt: "Find keys, like cart:*", status: searchStatus)
      .frame(minWidth: 160, maxWidth: 280)
      .onSubmit(search)
      .onChange(of: searchText) { _, text in
        Task {
          try? await Task.sleep(for: .milliseconds(450))
          if text == searchText { search() }
        }
      }
      .onAppear { searchText = browser.request.search }
  }

  private var searchStatus: WorkStatus {
    guard !browser.request.search.isEmpty else { return .idle }
    if browser.isLoading { return .working }
    return browser.records.isEmpty ? .failed : .done
  }

  private func search() {
    browser.request.search = searchText
    Task { await browser.reload() }
  }
}

/// The keys, grouped by prefix, in the kit's grid. The groups are made once per page here; the selection is read in
/// `RedisKeyGrid`, so a click doesn't group the page again or rebuild the pane around the grid.
private struct RedisKeyList: View {
  let browser: BrowserModel
  let model: RedisKeyModel?
  @Binding var expanded: Set<String>

  var body: some View {
    RedisKeyGrid(browser: browser, model: model, rows: rows, columns: columns, expanded: $expanded)
  }

  /// Groups (their keys as children) and loose keys.
  private var rows: [KeyRow] {
    let records = browser.records
    let keys = records.compactMap { $0["key"]?.displayText }
    let grouped = RedisKeyTree.group(keys)
    var out: [KeyRow] = []
    for group in grouped.groups {
      let id = "group:" + group.prefix
      let children = records.filter { $0["key"]?.displayText.hasPrefix(group.prefix) == true }.map { record in
        let key = record["key"]?.displayText ?? ""
        return KeyRow(id: record.id, label: String(key.dropFirst(group.prefix.count)), record: record)
      }
      out.append(KeyRow(id: id, label: group.prefix, children: children, count: group.count))
    }
    out += grouped.loose.compactMap { key in
      records.first { $0["key"]?.displayText == key }.map { KeyRow(id: $0.id, label: key, record: $0) }
    }
    return out
  }

  private var columns: [KitGridColumn<KeyRow>] {
    [
      KitGridColumn("Key", width: 280, content: { row in
        HStack(spacing: 6) {
          Text(row.label).kitFont(.mono).fontWeight(row.children != nil ? .semibold : .regular)
          if row.children != nil { Text("\(row.count) keys").kitFont(.caption) }
        }
        .lineLimit(1)
      }),
      KitGridColumn("Type", width: 100, content: { row in
        if let type = row.record?["type"]?.displayText { Chip(type: type).controlSize(.small) }
      }),
      KitGridColumn("Holds", width: 130, content: { row in
        if let record = row.record, let n = record["holds"]?.dbValue?.intValue {
          Text(Self.holds(n, type: record["type"]?.displayText ?? ""))
        }
      }),
      KitGridColumn("Size", width: 100, content: { row in
        if let n = row.record?["size"]?.dbValue?.intValue { Text(formatBytes(n)).monospacedDigit() }
      }),
      KitGridColumn("Expires", width: 100, content: { row in
        if let ms = row.record?["ttl"]?.dbValue?.intValue { Text(formatTTL(milliseconds: ms)) }
      }),
    ]
  }

  static func holds(_ n: Int64, type: String) -> String {
    switch type {
    case "STRING": String(localized: "\(n.formatted()) chars")
    case "HASH": n == 1 ? String(localized: "1 field") : String(localized: "\(n.formatted()) fields")
    case "LIST": n == 1 ? String(localized: "1 item") : String(localized: "\(n.formatted()) items")
    case "STREAM": n == 1 ? String(localized: "1 entry") : String(localized: "\(n.formatted()) entries")
    case "JSON": String(localized: "1 document")
    default: n == 1 ? String(localized: "1 member") : String(localized: "\(n.formatted()) members")
    }
  }
}

/// The keys as a phone list: each row its key, type, size and expiry, pushing the key's value (its inspector).
private struct PhoneKeyList: View {
  let browser: BrowserModel
  let model: RedisKeyModel?
  /// The key pushed; the stack pops it back to nil.
  @State private var opened: Record.ID?

  var body: some View {
    KitList(selection: $opened) {
      ForEach(browser.records) { record in
        PhoneKeyRow(record: record)
      }
      if browser.page?.hasMore == true {
        Button("Load More") { Task { await browser.nextPage() } }.buttonStyle(.kitPlain)
      }
    }
    .refreshable { await browser.reload() }
    // A deleted key leaves its page.
    .onChange(of: model?.key) { _, key in if key == nil { opened = nil } }
    .onChange(of: opened) { _, id in
      guard let id, let key = browser.records.first(where: { $0.id == id })?["key"]?.displayText else { return }
      model?.key = key
    }
    .navigationDestination(item: $opened) { _ in
      if let model {
        RedisValueView(model: model)
          .navigationTitle(model.key ?? "")
          #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
          #endif
      }
    }
  }
}

/// A key as a list row: its name, and its type, what it holds, its size and expiry under it.
private struct PhoneKeyRow: View {
  let record: Record

  var body: some View {
    let key = record["key"]?.displayText ?? ""
    let type = record["type"]?.displayText ?? ""
    var details: [String] = []
    if let n = record["holds"]?.dbValue?.intValue { details.append(RedisKeyList.holds(n, type: type)) }
    if let n = record["size"]?.dbValue?.intValue { details.append(formatBytes(n)) }
    if let ms = record["ttl"]?.dbValue?.intValue { details.append(formatTTL(milliseconds: ms)) }
    return SidebarRow(
      value: record.id, key, subtitle: details.isEmpty ? nil : details.joined(separator: " · "), systemImage: "key",
      hue: Hue.forTypeName(type)
    ) {
      if !type.isEmpty { Chip(type: type) }
    }
    .pushes()
  }
}

private struct RedisKeyGrid: View {
  @Bindable var browser: BrowserModel
  let model: RedisKeyModel?
  let rows: [KeyRow]
  let columns: [KitGridColumn<KeyRow>]
  @Binding var expanded: Set<String>

  var body: some View {
    KitGrid(rows, columns: columns, selection: $browser.selection, children: \.children, expanded: $expanded)
      .rowContextMenu { ids in
        let keys = ids.filter { $0.hasPrefix("key:") }.sorted().map { String($0.dropFirst(4)) }
        if !keys.isEmpty {
          Button(keys.count == 1 ? String(localized: "Copy Key Name") : String(localized: "Copy Key Names")) { KitPasteboard.copy(keys.joined(separator: "\n")) }
          if browser.isEditable {
            Button("Delete \(keys.count == 1 ? "Key" : "\(keys.count) Keys")", systemImage: "trash", role: .destructive) {
              Task { await model?.perform(keys.map { .delete(key: $0) }) }
            }
            .kitMenuPreview(keys.count == 1 ? "Deletes \(keys[0]) from Redis." : "Deletes these \(keys.count) keys from Redis.")
          }
        }
      }
      .onChange(of: browser.selection) { _, selection in
        guard let id = selection.first, selection.count == 1, id.hasPrefix("key:") else { return }
        model?.key = String(id.dropFirst(4))
      }
  }
}

/// Production: the commands a key change runs, to confirm first.
struct RedisConfirmSheet: View {
  let model: RedisKeyModel

  var body: some View {
    KitSheet(
      title: "Run these commands?", meta: "\(model.browser.connection.profile.displayName) is a production connection.",
      systemImage: "shield", hue: .red, width: 480
    ) {
      KitCodeBlock(
        model.confirming.flatMap(\.commands).map { $0.map(RedisCommandText.quote).joined(separator: " ") }.joined(separator: "\n"),
        font: .monoSmall)
    } footer: {
      Button("Cancel") { model.confirming = [] }
        .keyboardShortcut(.cancelAction)
      Button("Run") { Task { await model.perform(model.confirming) } }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
  }
}

enum RedisCommandText {
  static func quote(_ arg: String) -> String {
    arg.isEmpty || arg.contains(where: { $0 == " " || $0 == "\"" || $0.isNewline })
      ? "\"" + arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : arg
  }
}

/// redis-cli in a strip: type a command, see the reply.
struct RedisCommandLine: View {
  let browser: BrowserModel
  @State private var command = ""
  @State private var history: [(String, String)] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !history.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
              Text("> " + entry.0).kitFont(.monoSmall).foregroundStyle(.kitSecondary)
              Text(entry.1).kitFont(.monoSmall).textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
      }
      HStack(spacing: 6) {
        TextField("Command, e.g. ZREVRANGE leaderboard:weekly 0 9 WITHSCORES", text: $command)
          // A command: no capitals, corrections or spell check ("HGETALL" isn't a typo, D-008).
          .kitField(mono: true, content: .verbatim)
          .onSubmit(run)
        Button("Run", action: run).buttonStyle(.kitPrimary).controlSize(.small)
      }
    }
    .kitCard()
    .padding(.horizontal, KitMetrics.gutter)
    .padding(.bottom, KitMetrics.gutter)
  }

  private func run() {
    let text = command
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty, let session = browser.session else { return }
    command = ""
    Task {
      do {
        let runs = try await session.run(text, context: QueryContext(database: browser.ref.database))
        let output = runs.flatMap(\.outputs).compactMap { output -> String? in
          if case .text(let t) = output { return t }
          return nil
        }.joined(separator: "\n")
        history.append((text, output))
        await browser.load()
      } catch {
        history.append((text, "(error) " + FriendlyError.message(error)))
      }
    }
  }
}

/// A new key with its first value.
struct NewKeySheet: View {
  let model: RedisKeyModel
  @Environment(\.kitDismiss) private var dismiss
  @State private var name = ""
  @State private var type = "string"
  @State private var first = ""
  @State private var second = ""
  @State private var error: String?

  var body: some View {
    KitSheet(title: "Add Key", meta: "In \(model.browser.ref.name). Redis keeps it until you delete it or it expires.", systemImage: "key", hue: .red) {
      FormCard {
        FormRow("Key name", systemImage: "key", hue: .red, field: TextField("Key name", text: $name, prompt: Text("session:1234")))
        FormRow("Type", systemImage: "square.grid.2x2", hue: .gray) {
          KitPicker("Type", selection: $type, options: KeysBrowserView.types.compactMap(\.1).map { ("\(label($0))", $0) })
        }
        switch type {
        case "hash", "stream":
          FormRow("Field", systemImage: "textformat", hue: .gray, field: TextField("Field", text: $first))
          FormRow("Value", systemImage: "text.alignleft", hue: .gray, field: TextField("Value", text: $second))
        case "zset":
          FormRow("Member", systemImage: "person", hue: .gray, field: TextField("Member", text: $first))
          FormRow("Score", systemImage: "number", hue: .gray, field: TextField("Score", text: $second))
        case "json":
          FormRow("JSON", systemImage: "curlybraces", hue: .gray, field: TextField("JSON", text: $first, prompt: Text("{ \"name\": \"Ann\" }"), axis: .vertical))
        default:
          FormRow("Value", systemImage: "text.alignleft", hue: .gray, field: TextField("Value", text: $first, axis: .vertical))
        }
      }
      if let error { Banner(error, systemImage: "exclamationmark.triangle", hue: .red) }
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Add") {
        Task {
          do {
            let values = ["hash", "stream", "zset"].contains(type) ? [first, second] : [first]
            try await model.session?.create(key: name, type: type, first: values, in: model.browser.ref)
            await model.browser.load()
            model.key = name
            dismiss()
          } catch {
            self.error = FriendlyError.message(error)
          }
        }
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(name.isEmpty)
    }
  }

  private func label(_ type: String) -> String {
    KeysBrowserView.types.first { $0.1 == type }?.0 ?? type
  }
}
