import ComponentKit
import DatabaseKit
import SwiftUI

/// The inspector for one Redis key: type, expiry, the value editor and key actions.
struct RedisValueView: View {
  @Bindable var model: RedisKeyModel
  @State private var settingExpiry = false
  @State private var renaming = false
  @State private var newName = ""
  @State private var deleting = false

  private var key: String { model.key ?? "" }
  private var editable: Bool { model.browser.isEditable }

  var body: some View {
    KitInspector(width: nil) {
      InspectorHeader(
        key, meta: [longTypeName], systemImage: "key", hue: Hue.forTypeName(typeName),
        status: model.isLoading ? .working : .idle
      ) {
        Chip(type: typeName)
      }
      expiry
      if let error = model.error {
        Banner(error, systemImage: "exclamationmark.triangle", hue: .red)
      }
      valueEditor
      actions
      KitCodeBlock(commandHint, font: .monoSmall)
    }
    .kitPrompt(
      "Rename Key", isPresented: $renaming, text: $newName, message: key,
      field: KitPromptField("New name", placeholder: "New name", systemImage: "key"), confirm: "Rename"
    ) { name in
      if name != key { Task { await model.perform([.rename(key: key, to: name)]) } }
    }
    .kitConfirmation(
      "Delete \(key)?", isPresented: $deleting, message: "You can undo right after.", systemImage: "trash",
      confirm: "Delete Key"
    ) {
      Task { await model.perform([.delete(key: key)]) }
    }
  }

  private var typeName: String {
    switch model.value {
    case .string: "STRING"
    case .hash: "HASH"
    case .list: "LIST"
    case .set: "SET"
    case .zset: "ZSET"
    case .stream: "STREAM"
    case .json: "JSON"
    case .none: "GONE"
    case .other(let type): type.uppercased()
    }
  }

  private var longTypeName: String {
    switch model.value {
    case .string: "String · \(model.total.formatted()) bytes"
    case .hash: "Hash · \(model.total.formatted()) fields"
    case .list: "List · \(model.total.formatted()) items"
    case .set: "Set · \(model.total.formatted()) members"
    case .zset: "Sorted set · \(model.total.formatted()) members"
    case .stream: "Stream · \(model.total.formatted()) entries"
    case .json: "JSON document"
    case .none: "This key no longer exists"
    case .other(let type): type
    }
  }

  private var expiry: some View {
    RichHeader(
      model.ttl == -1 ? "Never expires" : "Expires \(formatTTL(milliseconds: model.ttl))",
      meta: model.ttl == -1 ? "Set a time and Redis removes the key for you." : "Redis removes the key then.",
      systemImage: "clock", hue: model.ttl == -1 ? .gray : .orange
    ) {
      if editable {
        Button(model.ttl == -1 ? "Set Expiry…" : "Change…") { settingExpiry = true }
          .buttonStyle(.kitPlain)
          .controlSize(.small)
          .kitPopover(isPresented: $settingExpiry) {
            ExpiryEditor(hasExpiry: model.ttl >= 0) { seconds in
              settingExpiry = false
              Task { await model.perform([.expire(key: key, seconds: seconds)]) }
            }
          }
      }
    }
    .kitCard()
  }

  @ViewBuilder private var valueEditor: some View {
    switch model.value {
    case .string(let text):
      TextValueEditor(initial: text, isJSON: false, editable: editable) { new in
        Task { await model.perform([.setString(key: key, value: new)]) }
      }
    case .json(let text):
      TextValueEditor(initial: text, isJSON: true, editable: editable) { new in
        Task { await model.perform([.jsonSet(key: key, path: "$", json: new)]) }
      }
    case .hash(let fields):
      PairsEditor(
        pairs: fields.map { ($0.field, $0.value) }, keyTitle: "Field", valueTitle: "Value", editable: editable,
        onSet: { f, v in Task { await model.perform([.hashSet(key: key, field: f, value: v)]) } },
        onDelete: { f in Task { await model.perform([.hashDelete(key: key, field: f)]) } })
    case .list(let items):
      ListValueEditor(items: items, total: model.total, editable: editable, model: model)
    case .set(let members):
      MembersEditor(members: members, total: model.total, editable: editable) { add, remove in
        Task {
          if let add { await model.perform([.setAdd(key: key, member: add)]) }
          if let remove { await model.perform([.setRemove(key: key, member: remove)]) }
        }
      }
    case .zset(let members):
      SortedSetEditor(members: members, total: model.total, editable: editable, model: model)
    case .stream(let entries):
      StreamEditor(entries: entries, total: model.total, editable: editable, model: model)
    case .none:
      EmptyState(systemImage: "key.slash", title: "Key Gone", message: "It expired or was deleted.")
    case .other(let type):
      Text("Values of type \(type) can be read with the command line.").foregroundStyle(.kitSecondary)
    }
  }

  @ViewBuilder private var actions: some View {
    if editable, model.value != .none {
      ActionBar {
        Button("Rename Key…") {
          newName = key
          renaming = true
        }
        Button("Delete Key…", systemImage: "trash", role: .destructive) { deleting = true }
          .labelStyle(.iconOnly)
      }
    }
  }

  private var commandHint: String {
    switch model.value {
    case .string: "GET \(RedisCommandText.quote(key))"
    case .hash: "HGETALL \(RedisCommandText.quote(key))"
    case .list: "LRANGE \(RedisCommandText.quote(key)) 0 -1"
    case .set: "SMEMBERS \(RedisCommandText.quote(key))"
    case .zset: "ZREVRANGE \(RedisCommandText.quote(key)) 0 -1 WITHSCORES"
    case .stream: "XREVRANGE \(RedisCommandText.quote(key)) + - COUNT 100"
    case .json: "JSON.GET \(RedisCommandText.quote(key)) $"
    default: "TYPE \(RedisCommandText.quote(key))"
    }
  }
}

struct ExpiryEditor: View {
  let hasExpiry: Bool
  let onSet: (Int?) -> Void
  @State private var amount = 30
  @State private var unit = 60

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Expires in").kitFont(.headline)
      HStack {
        TextField("Amount", value: $amount, format: .number).kitField(mono: true).frame(width: 70)
        KitPicker("Unit", selection: $unit, options: [("seconds", 1), ("minutes", 60), ("hours", 3600), ("days", 86400)])
      }
      HStack {
        if hasExpiry { Button("Never Expire") { onSet(nil) }.buttonStyle(.kit) }
        Spacer()
        Button("Set Expiry") { onSet(max(1, amount) * unit) }
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
      }
      .controlSize(.small)
    }
    .padding(14)
    .frame(width: 300)
  }
}

/// Strings and JSON.
struct TextValueEditor: View {
  let initial: String
  let isJSON: Bool
  let editable: Bool
  let onSave: (String) -> Void
  @State private var text = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextEditor(text: $text)
        .kitFont(isJSON || looksLikeJSON ? .mono : .body)
        .frame(minHeight: 160, maxHeight: 420)
        .scrollContentBackground(.hidden)
        .padding(6)
        .kitSurface(.card)
        .disabled(!editable)
      if let error { Label(error, systemImage: "exclamationmark.circle").kitFont(.caption).foregroundStyle(Hue.red.text) }
      if editable && text != initial {
        HStack {
          Button("Revert") { text = initial }.buttonStyle(.kit)
          Button("Save") {
            if isJSON, (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) == nil {
              error = "That isn't valid JSON."
              return
            }
            error = nil
            onSave(text)
          }
          .buttonStyle(.kitPrimary)
        }
      }
    }
    .onAppear { text = initial }
    .onChange(of: initial) { text = initial }
  }

  private var looksLikeJSON: Bool { text.hasPrefix("{") || text.hasPrefix("[") }
}

/// Field → value pairs (hashes).
struct PairsEditor: View {
  let pairs: [(String, String)]
  let keyTitle: String
  let valueTitle: String
  let editable: Bool
  let onSet: (String, String) -> Void
  let onDelete: (String) -> Void
  @State private var editingField: String?
  @State private var draft = ""
  @State private var newField = ""
  @State private var newValue = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(keyTitle).frame(width: 120, alignment: .leading)
        Text(valueTitle)
        Spacer()
      }
      .kitFont(.sectionHeader)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      ForEach(pairs, id: \.0) { field, value in
        HStack(alignment: .firstTextBaseline) {
          Text(field).kitFont(.monoSmall).frame(width: 120, alignment: .leading).lineLimit(1)
          if editingField == field {
            TextField(valueTitle, text: $draft)
              .kitField()
              .onSubmit {
                onSet(field, draft)
                editingField = nil
              }
          } else {
            Text(value).lineLimit(3).textSelection(.enabled)
          }
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          guard editable else { return }
          editingField = field
          draft = value
        }
        .kitContextMenu {
          if editable {
            Button("Edit Value") {
              editingField = field
              draft = value
            }
            Button("Delete \(field)", role: .destructive) { onDelete(field) }
          }
          Button("Copy Value") { KitPasteboard.copy(value) }
        }
        Rectangle().fill(.kitSeparator).frame(height: 0.5).padding(.leading, 12)
      }
      if editable {
        HStack {
          TextField(keyTitle, text: $newField).kitField().frame(width: 120)
          TextField(valueTitle, text: $newValue).kitField()
          Button("Add", systemImage: "plus") {
            onSet(newField, newValue)
            newField = ""
            newValue = ""
          }
          .buttonStyle(.kitIcon)
          .disabled(newField.isEmpty)
        }
        .padding(10)
      }
    }
    .kitSurface(.card)
  }
}

struct ListValueEditor: View {
  let items: [String]
  let total: Int
  let editable: Bool
  let model: RedisKeyModel
  @State private var newItem = ""
  @State private var editing: Int?
  @State private var draft = ""

  var body: some View {
    let key = model.key ?? ""
    VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack {
          Text("\(index)").monospacedDigit().foregroundStyle(.kitSecondary).frame(width: 34, alignment: .leading)
          if editing == index {
            TextField("Value", text: $draft).kitField().onSubmit {
              Task { await model.perform([.listSet(key: key, index: index, value: draft)]) }
              editing = nil
            }
          } else {
            Text(item).lineLimit(3).textSelection(.enabled)
          }
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          guard editable else { return }
          editing = index
          draft = item
        }
        .kitContextMenu {
          if editable {
            Button("Edit") {
              editing = index
              draft = item
            }
            Button("Remove", role: .destructive) { Task { await model.perform([.listRemove(key: key, index: index)]) } }
          }
        }
        Rectangle().fill(.kitSeparator).frame(height: 0.5).padding(.leading, 12)
      }
      if total > items.count {
        Text("Showing \(items.count) of \(total.formatted())").kitFont(.caption).padding(8)
      }
      if editable {
        HStack {
          TextField("New item", text: $newItem).kitField()
          Button("Add to Start") { push(atEnd: false, key: key) }.buttonStyle(.kit).disabled(newItem.isEmpty)
          Button("Add to End") { push(atEnd: true, key: key) }.buttonStyle(.kit).disabled(newItem.isEmpty)
        }
        .padding(10)
      }
    }
    .kitSurface(.card)
  }

  private func push(atEnd: Bool, key: String) {
    let value = newItem
    newItem = ""
    Task { await model.perform([.listPush(key: key, value: value, atEnd: atEnd)]) }
  }
}

struct MembersEditor: View {
  let members: [String]
  let total: Int
  let editable: Bool
  let onChange: (String?, String?) -> Void
  @State private var newMember = ""

  var body: some View {
    VStack(spacing: 0) {
      ForEach(members, id: \.self) { member in
        HStack {
          Text(member).textSelection(.enabled)
          Spacer()
          if editable {
            Button("Remove \(member)", systemImage: "minus.circle", role: .destructive) { onChange(nil, member) }
              .buttonStyle(.kitIcon)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        Rectangle().fill(.kitSeparator).frame(height: 0.5).padding(.leading, 12)
      }
      if total > members.count {
        Text("Showing \(members.count) of \(total.formatted())").kitFont(.caption).padding(8)
      }
      if editable {
        HStack {
          TextField("New member", text: $newMember).kitField().onSubmit(add)
          Button("Add Member", action: add).buttonStyle(.kit).disabled(newMember.isEmpty).fixedSize()
        }
        .padding(10)
      }
    }
    .kitSurface(.card)
  }

  private func add() {
    guard !newMember.isEmpty else { return }
    onChange(newMember, nil)
    newMember = ""
  }
}

/// Rank, member and score with a bar, highest first (the leaderboard view).
struct SortedSetEditor: View {
  let members: [(member: String, score: Double)]
  let total: Int
  let editable: Bool
  let model: RedisKeyModel
  @State private var newMember = ""
  @State private var newScore = ""
  @State private var editing: String?
  @State private var draftScore = ""

  var body: some View {
    let key = model.key ?? ""
    let top = max(members.map { abs($0.score) }.max() ?? 1, 1)
    VStack(spacing: 0) {
      HStack {
        Text("Rank").frame(width: 40, alignment: .leading)
        Text("Member")
        Spacer()
        Text("Score")
      }
      .kitFont(.sectionHeader)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      ForEach(Array(members.enumerated()), id: \.element.member) { index, entry in
        HStack(alignment: .center) {
          Text("\(index + 1)").monospacedDigit().foregroundStyle(.kitSecondary).frame(width: 40, alignment: .leading)
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.member).kitFont(.monoSmall).lineLimit(1)
            GeometryReader { proxy in
              Capsule().fill(.kitFill)
                .overlay(alignment: .leading) {
                  Capsule().fill(Hue.accent.fill).frame(width: proxy.size.width * CGFloat(abs(entry.score) / top))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
          }
          .padding(.trailing, 12)
          if editing == entry.member {
            TextField("Score", text: $draftScore)
              .kitField()
              .frame(width: 80)
              .onSubmit {
                if let score = Double(draftScore) {
                  Task { await model.perform([.zsetAdd(key: key, member: entry.member, score: score)]) }
                }
                editing = nil
              }
          } else {
            Text(entry.score.formatted()).monospacedDigit()
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(index + 1). \(entry.member), score \(entry.score.formatted())")
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          guard editable else { return }
          editing = entry.member
          draftScore = entry.score.formatted(.number.grouping(.never))
        }
        .kitContextMenu {
          if editable {
            Button("Change Score") {
              editing = entry.member
              draftScore = entry.score.formatted(.number.grouping(.never))
            }
            Button("Remove", role: .destructive) { Task { await model.perform([.zsetRemove(key: key, member: entry.member)]) } }
          }
        }
        Rectangle().fill(.kitSeparator).frame(height: 0.5).padding(.leading, 12)
      }
      Text("Highest first · \(members.count) of \(total.formatted())")
        .kitFont(.caption)
        .padding(8)
      if editable {
        // One line where Member keeps room to type (the Mac); Add Member under the fields on a touch screen.
        ViewThatFits(in: .horizontal) {
          HStack {
            memberField.frame(minWidth: 90)
            scoreField
            addButton
          }
          VStack(alignment: .trailing) {
            HStack {
              memberField
              scoreField
            }
            addButton
          }
        }
        .padding(10)
      }
    }
    .kitSurface(.card)
  }

  private var memberField: some View { TextField("Member", text: $newMember).kitField() }

  private var scoreField: some View { TextField("Score", text: $newScore).kitField().frame(width: 70) }

  private var addButton: some View {
    Button("Add Member") {
      guard let score = Double(newScore) else { return }
      let member = newMember
      newMember = ""
      newScore = ""
      Task { await model.perform([.zsetAdd(key: model.key ?? "", member: member, score: score)]) }
    }
    .buttonStyle(.kit)
    .disabled(newMember.isEmpty || Double(newScore) == nil)
    .fixedSize()
  }
}

struct StreamEditor: View {
  let entries: [(id: String, fields: [(String, String)])]
  let total: Int
  let editable: Bool
  let model: RedisKeyModel
  @State private var field = ""
  @State private var value = ""

  var body: some View {
    let key = model.key ?? ""
    VStack(alignment: .leading, spacing: 0) {
      ForEach(entries, id: \.id) { entry in
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(entry.id).kitFont(.monoSmall).foregroundStyle(.kitSecondary)
            Spacer()
            if editable {
              Button("Delete Entry", systemImage: "trash", role: .destructive) { Task { await model.perform([.streamDelete(key: key, id: entry.id)]) } }
                .buttonStyle(.kitIcon)
            }
          }
          ForEach(entry.fields, id: \.0) { pair in
            HStack(alignment: .firstTextBaseline) {
              Text(pair.0).foregroundStyle(.kitSecondary).frame(width: 100, alignment: .leading)
              Text(pair.1).textSelection(.enabled)
            }
            .kitFont(.callout)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        Rectangle().fill(.kitSeparator).frame(height: 0.5).padding(.leading, 12)
      }
      Text("Newest first · \(entries.count) of \(total.formatted())").kitFont(.caption).padding(8)
      if editable {
        HStack {
          TextField("Field", text: $field).kitField().frame(width: 100)
          TextField("Value", text: $value).kitField()
          Button("Add Entry") {
            let pair = [field, value]
            field = ""
            value = ""
            Task { await model.perform([.streamAdd(key: key, fields: pair)]) }
          }
          .buttonStyle(.kit)
          .disabled(field.isEmpty)
        }
        .padding(10)
      }
    }
    .kitSurface(.card)
  }
}
