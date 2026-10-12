import DatabaseCore
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
    case .delete(let key): "Deleted \(key)"
    case .rename(let key, let to): "Renamed \(key) to \(to)"
    case .expire(let key, let seconds?): "\(key) expires in \(formatTTL(milliseconds: Int64(seconds) * 1000).dropFirst(3))"
    case .expire(let key, nil): "\(key) no longer expires"
    default: "Changed \(mutation.key)"
    }
  }
}

struct KeysBrowserView: View {
  @Bindable var browser: BrowserModel
  @Bindable var window: WindowModel
  @State private var model: RedisKeyModel?
  @State private var searchText = ""
  @State private var creating = false
  @State private var commandLine = false
  @Environment(\.horizontalSizeClass) private var sizeClass

  static let types: [(String, String?)] = [
    ("All", nil), ("String", "string"), ("Hash", "hash"), ("List", "list"), ("Set", "set"), ("Sorted Set", "zset"),
    ("Stream", "stream"), ("JSON", "json"),
  ]

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        SearchField(text: $searchText, prompt: "Find keys, like cart:*")
          .frame(minWidth: 160, maxWidth: 280)
          .onSubmit(search)
          .onChange(of: searchText) { _, text in
            Task {
              try? await Task.sleep(for: .milliseconds(450))
              if text == searchText { search() }
            }
          }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(Self.types, id: \.0) { name, type in
              let on = browser.request.keyType == type
              Button(name) {
                browser.request.keyType = type
                Task { await browser.reload() }
              }
              .font(.callout)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .foregroundStyle(on ? Color.white : Color.primary)
              .background(on ? Color.primary : Color.clear, in: Capsule())
              .overlay(Capsule().strokeBorder(on ? .clear : Color.secondary.opacity(0.3)))
              .buttonStyle(.plain)
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      if commandLine {
        RedisCommandLine(browser: browser)
      }
      if let error = browser.errorMessage {
        Banner(text: error, systemImage: "exclamationmark.triangle.fill", color: .red) { browser.errorMessage = nil }
      }
      ForEach(browser.page?.notes ?? [], id: \.self) { Banner(text: $0, systemImage: "info.circle", color: .secondary) }
      keyList
      HStack {
        Text("Keys are grouped by the “:” in their names · \(browser.pageLabel)")
        if let elapsed = browser.page?.elapsed { Text("· scanned in \(formatDuration(elapsed))") }
        Spacer()
        Button("Previous Page", systemImage: "chevron.left") { Task { await browser.previousPage() } }
          .labelStyle(.iconOnly).disabled(browser.request.offset == 0)
        Button("Next Page", systemImage: "chevron.right") { Task { await browser.nextPage() } }
          .labelStyle(.iconOnly).disabled(browser.page?.hasMore != true)
      }
      .buttonStyle(.borderless)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .navigationTitle(browser.ref.name)
    #if os(macOS)
      .navigationSubtitle("\(browser.connection.profile.displayName) · \(browser.exactTotal ?? browser.page?.total ?? 0) keys")
    #endif
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Toggle(isOn: $commandLine) { Label("Command Line", systemImage: "terminal") }
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task {
            await browser.reload()
            await model?.load()
          }
        }
        if browser.isEditable {
          Button("Add Key", systemImage: "plus") { creating = true }
        }
      }
    }
    .inspector(isPresented: Binding(get: { window.showsInspector && sizeClass != .compact }, set: { window.showsInspector = $0 })) {
      Group {
        if let model, model.key != nil {
          RedisValueView(model: model)
        } else {
          ContentUnavailableView("No Key Selected", systemImage: "key", description: Text("Select a key to see and edit its value."))
        }
      }
      .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
    }
    .sheet(isPresented: $creating) {
      if let model { NewKeySheet(model: model).appButtonShape() }
    }
    .overlay(alignment: .bottom) { RedisToast(browser: browser, model: model) }
    .onAppear {
      if model == nil { model = RedisKeyModel(browser: browser) }
      searchText = browser.request.search
    }
    .onChange(of: browser.selection) { _, selection in
      guard let id = selection.first, selection.count == 1, id.hasPrefix("key:") else { return }
      model?.key = String(id.dropFirst(4))
    }
  }

  private func search() {
    browser.request.search = searchText
    Task { await browser.reload() }
  }

  private var rows: [KeyRow] {
    let records = browser.records
    let keys = records.compactMap { $0["key"]?.displayText }
    let grouped = RedisKeyTree.group(keys)
    var out: [KeyRow] = grouped.groups.map { group in
      let children = records.filter { $0["key"]?.displayText.hasPrefix(group.prefix) == true }.map { record in
        let key = record["key"]?.displayText ?? ""
        return KeyRow(id: record.id, label: String(key.dropFirst(group.prefix.count)), record: record)
      }
      return KeyRow(id: "group:" + group.prefix, label: group.prefix, children: children, count: group.count)
    }
    out += grouped.loose.compactMap { key in
      records.first { $0["key"]?.displayText == key }.map { KeyRow(id: $0.id, label: key, record: $0) }
    }
    return out
  }

  private var keyList: some View {
    Table(rows, children: \.children, selection: $browser.selection) {
      TableColumn("Key") { row in
        HStack(spacing: 6) {
          Text(row.label).font(.system(.callout, design: .monospaced)).fontWeight(row.children != nil ? .semibold : .regular)
          if row.children != nil { Text("\(row.count) keys").font(.caption).foregroundStyle(.secondary) }
        }
        .lineLimit(1)
      }
      .width(min: 160, ideal: 280)
      TableColumn("Type") { row in
        if let type = row.record?["type"]?.displayText { TypeBadge(type) }
      }
      .width(70)
      TableColumn("Holds") { row in
        if let record = row.record, let n = record["holds"]?.dbValue?.intValue {
          Text(holds(n, type: record["type"]?.displayText ?? "")).foregroundStyle(.secondary)
        }
      }
      .width(min: 80, ideal: 110)
      TableColumn("Size") { row in
        if let n = row.record?["size"]?.dbValue?.intValue {
          Text(formatBytes(n)).monospacedDigit().foregroundStyle(.secondary)
        }
      }
      .width(70)
      TableColumn("Expires") { row in
        if let ms = row.record?["ttl"]?.dbValue?.intValue { Text(formatTTL(milliseconds: ms)).foregroundStyle(.secondary) }
      }
      .width(80)
    }
    .stripedTableStyle()
    .contextMenu(forSelectionType: String.self) { ids in
      let keys = ids.filter { $0.hasPrefix("key:") }.map { String($0.dropFirst(4)) }
      if !keys.isEmpty {
        Button("Copy Key Name\(keys.count == 1 ? "" : "s")") { Clipboard.copy(keys.joined(separator: "\n")) }
        if browser.isEditable {
          Button("Delete \(keys.count == 1 ? "Key" : "\(keys.count) Keys")", systemImage: "trash", role: .destructive) {
            Task { await model?.perform(keys.map { .delete(key: $0) }) }
          }
        }
      }
    }
  }

  private func holds(_ n: Int64, type: String) -> String {
    switch type {
    case "STRING": "\(n.formatted()) chars"
    case "HASH": "\(n.formatted()) field\(n == 1 ? "" : "s")"
    case "LIST": "\(n.formatted()) item\(n == 1 ? "" : "s")"
    case "STREAM": "\(n.formatted()) entr\(n == 1 ? "y" : "ies")"
    case "JSON": "1 document"
    default: "\(n.formatted()) member\(n == 1 ? "" : "s")"
    }
  }
}

/// Confirmation and undo for key changes.
struct RedisToast: View {
  let browser: BrowserModel
  let model: RedisKeyModel?

  var body: some View {
    if let model, !model.confirming.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Label("Production: run these commands?", systemImage: "shield").font(.headline).foregroundStyle(.red)
        Text(model.confirming.flatMap(\.commands).map { $0.map(RedisCommandText.quote).joined(separator: " ") }.joined(separator: "\n"))
          .font(.codeSmall)
          .textSelection(.enabled)
        HStack {
          Spacer()
          Button("Cancel") { model.confirming = [] }
          Button("Run") { Task { await model.perform(model.confirming) } }.buttonStyle(.borderedProminent)
        }
      }
      .padding(16)
      .frame(maxWidth: 460)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
      .padding(.bottom, 40)
    } else if let toast = browser.toast {
      HStack(spacing: 12) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text(toast)
        if model?.canUndo == true {
          Button("Undo") { Task { await model?.undoLast() } }.buttonStyle(.borderless).fontWeight(.semibold)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.regularMaterial, in: Capsule())
      .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
      .padding(.bottom, 40)
      .task(id: toast) {
        try? await Task.sleep(for: .seconds(8))
        browser.toast = nil
      }
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
              Text("> " + entry.0).font(.codeSmall).foregroundStyle(.secondary)
              Text(entry.1).font(.codeSmall).textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
      }
      HStack {
        Text(">").font(.code).foregroundStyle(.secondary)
        TextField("Command, e.g. ZREVRANGE leaderboard:weekly 0 9 WITHSCORES", text: $command)
          .font(.code)
          .textFieldStyle(.plain)
          .onSubmit(run)
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
        Button("Run", action: run).buttonStyle(.borderedProminent).controlSize(.small)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(.horizontal, 16)
    .padding(.bottom, 10)
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
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var type = "string"
  @State private var first = ""
  @State private var second = ""
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        TextField("Key name", text: $name, prompt: Text("session:1234"))
        Picker("Type", selection: $type) {
          ForEach(KeysBrowserView.types.compactMap(\.1), id: \.self) { Text(label($0)).tag($0) }
        }
        switch type {
        case "hash", "stream":
          TextField("Field", text: $first)
          TextField("Value", text: $second)
        case "zset":
          TextField("Member", text: $first)
          TextField("Score", text: $second)
        case "json":
          TextField("JSON", text: $first, prompt: Text("{ \"name\": \"Ann\" }"), axis: .vertical).font(.code)
        default:
          TextField("Value", text: $first, axis: .vertical)
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .navigationTitle("Add Key")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
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
          .disabled(name.isEmpty)
        }
      }
    }
    .frame(minWidth: 420, minHeight: 300)
  }

  private func label(_ type: String) -> String {
    KeysBrowserView.types.first { $0.1 == type }?.0 ?? type
  }
}
