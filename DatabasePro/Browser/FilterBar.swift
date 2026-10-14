import DatabaseProKit
import SwiftUI

/// Search, filter chips, sort and fields: the simple bar above the list.
struct FilterBar: View {
  @Bindable var browser: BrowserModel
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var addingFilter = false
  @State private var searchText = ""

  var body: some View {
    HStack(spacing: 8) {
      if browser.engine.supportsSearch {
        SearchField(text: $searchText, prompt: "Search \(browser.ref.name)")
          .frame(minWidth: 140, maxWidth: 280)
          .onSubmit { commitSearch() }
          .onChange(of: searchText) { _, text in
            // Searching starts after a short pause.
            Task {
              try? await Task.sleep(for: .milliseconds(450))
              if text == searchText, text != browser.request.search { commitSearch() }
            }
          }
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(browser.request.filters) { filter in
            FilterChip(text: filter.summary(category: browser.category(of: filter.field))) {
              Task { await browser.removeFilter(filter.id) }
            }
          }
          Button {
            addingFilter = true
          } label: {
            // A phone keeps the width for the search field.
            Label("Add Filter", systemImage: "plus")
              .labelStyle(AdaptiveLabelStyle(iconOnly: sizeClass == .compact))
          }
          .buttonStyle(DashedCapsuleStyle())
          .popover(isPresented: $addingFilter, arrowEdge: .bottom) {
            AddFilterView(browser: browser) { filter in
              addingFilter = false
              Task { await browser.addFilter(filter) }
            }
            .appButtonShape()
          }
          .disabled(browser.fields.isEmpty)
        }
      }
      Spacer(minLength: 4)
      if browser.engine.family != .wideColumn && browser.engine != .redis {
        SortMenu(browser: browser)
      }
      if browser.engine != .redis {
        FieldsMenu(browser: browser)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .onAppear { searchText = browser.request.search }
  }

  private func commitSearch() {
    browser.request.search = searchText
    Task { await browser.reload() }
  }
}

/// A rounded search field that works the same on Mac and iPhone.
struct SearchField: View {
  @Binding var text: String
  var prompt: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        #endif
      if !text.isEmpty {
        Button("Clear Search", systemImage: "xmark.circle.fill") { text = "" }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

struct FilterChip: View {
  let text: String
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Text(text).lineLimit(1)
      Button("Remove filter: \(text)", systemImage: "xmark", action: onRemove)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.small)
    }
    .font(.callout.weight(.medium))
    .foregroundStyle(Color.accentColor)
    .padding(.leading, 11)
    .padding(.trailing, 7)
    .padding(.vertical, 4)
    .background(Color.accentColor.opacity(0.12), in: Capsule())
  }
}

/// Title and icon, or just the icon.
struct AdaptiveLabelStyle: LabelStyle {
  var iconOnly: Bool

  func makeBody(configuration: Configuration) -> some View {
    if iconOnly {
      IconOnlyLabelStyle().makeBody(configuration: configuration)
    } else {
      DefaultLabelStyle().makeBody(configuration: configuration)
    }
  }
}

/// "Add Filter", "Add Field": a dashed capsule the size of a bordered button.
struct DashedCapsuleStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 10)
      .frame(minHeight: 22)
      .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.tertiary))
      .opacity(configuration.isPressed ? 0.6 : 1)
      .contentShape(Capsule())
  }
}

/// Field → condition → value, in plain words.
struct AddFilterView: View {
  let browser: BrowserModel
  let onAdd: (Filter) -> Void
  @State private var field = ""
  @State private var op = FilterOp.equals
  @State private var value = ""

  private var selectedField: FieldInfo? { browser.fields.first { $0.name == field } }
  private var ops: [FilterOp] {
    selectedField.map { browser.engine.filterOps(for: $0) } ?? [.equals]
  }

  var body: some View {
    Form {
      Picker("Field", selection: $field) {
        ForEach(browser.fields) { field in
          HStack {
            Text(field.name)
            if field.keyRole != nil { Text("key").foregroundStyle(.secondary) }
          }
          .tag(field.name)
        }
      }
      Picker("Condition", selection: $op) {
        ForEach(ops) { Text($0.label(for: selectedField?.category ?? .text)).tag($0) }
      }
      if op.needsValue {
        if selectedField?.category == .boolean {
          Picker("Value", selection: $value) {
            Text("true").tag("true")
            Text("false").tag("false")
          }
        } else {
          TextField(op == .inLastDays ? "Days" : "Value", text: $value, prompt: Text(placeholder))
            .onSubmit(add)
        }
      }
      if browser.engine.family == .wideColumn, let field = selectedField, field.keyRole != .partition {
        Text("Filtering on \(field.name) reads the whole table unless the partition key is filtered too.")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      HStack {
        Spacer()
        Button("Add Filter", action: add)
          .keyboardShortcut(.defaultAction)
          .disabled(field.isEmpty || (op.needsValue && value.isEmpty))
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 320)
    .onAppear {
      field = browser.fields.first(where: { !$0.isPrimaryKey })?.name ?? browser.fields.first?.name ?? ""
      if !ops.contains(op) { op = ops.first ?? .equals }
    }
    .onChange(of: field) {
      if !ops.contains(op) { op = ops.first ?? .equals }
      if selectedField?.category == .boolean { value = "true" }
    }
  }

  private var placeholder: String {
    switch selectedField?.category {
    case .date, .dateTime: op == .inLastDays ? "7" : "2026-10-12"
    case .integer, .decimal, .float: "100"
    default: ""
    }
  }

  private func add() {
    guard !field.isEmpty, !op.needsValue || !value.isEmpty else { return }
    onAdd(Filter(field: field, op: op, value: value))
  }
}

struct SortMenu: View {
  let browser: BrowserModel

  private var label: String {
    guard let sort = browser.request.sort.first else { return "Sort" }
    let category = browser.category(of: sort.field)
    let direction: String =
      if category.isTemporal { sort.ascending ? "oldest first" : "newest first" } else if category.isNumeric {
        sort.ascending ? "lowest first" : "highest first"
      } else { sort.ascending ? "A to Z" : "Z to A" }
    return "\(sort.field), \(direction)"
  }

  var body: some View {
    Menu {
      ForEach(browser.fields) { field in
        Menu(field.name) {
          Button(field.category.isTemporal ? "Oldest First" : field.category.isNumeric ? "Lowest First" : "A to Z") {
            browser.request.sort = [SortKey(field: field.name, ascending: true)]
            Task { await browser.reload() }
          }
          Button(field.category.isTemporal ? "Newest First" : field.category.isNumeric ? "Highest First" : "Z to A") {
            browser.request.sort = [SortKey(field: field.name, ascending: false)]
            Task { await browser.reload() }
          }
        }
      }
      if !browser.request.sort.isEmpty {
        Divider()
        Button("Don't Sort") {
          browser.request.sort = []
          Task { await browser.reload() }
        }
      }
    } label: {
      Label(label, systemImage: "arrow.up.arrow.down")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}

struct FieldsMenu: View {
  let browser: BrowserModel

  var body: some View {
    Menu {
      ForEach(browser.fields) { field in
        Toggle(field.name, isOn: Binding(
          get: { !browser.request.hiddenFields.contains(field.name) },
          set: { _ in Task { await browser.toggleField(field.name) } }))
      }
      if !browser.request.hiddenFields.isEmpty {
        Divider()
        Button("Show All Fields") { Task { await browser.showAllFields() } }
      }
    } label: {
      let shown = browser.fields.count - browser.request.hiddenFields.count
      Label(browser.request.hiddenFields.isEmpty ? "Fields" : "\(shown) of \(browser.fields.count) fields", systemImage: "eye")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}

/// The query the simple bar wrote; editable and runnable.
struct QueryStrip: View {
  @Bindable var browser: BrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(browser.queryIsCustom ? "Edited query: results replace the list below" : "\(browser.engine.queryLanguage) written by the bar above. Edit it to go further.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if browser.queryIsCustom {
          Button("Reset") { browser.resetQuery() }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        Button {
          Task { await browser.runQuery() }
        } label: {
          Label("Run", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .keyboardShortcut(.return, modifiers: .command)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      Divider()
      CodeEditor(
        text: Binding(get: { browser.queryText }, set: { browser.editQuery($0) }), language: browser.engine.highlighting,
        completions: [])
        .frame(height: max(64, min(220, CGFloat(browser.queryText.split(separator: "\n", omittingEmptySubsequences: false).count) * 20 + 24)))
        .clipped()
    }
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
    .padding(.horizontal, 16)
    .padding(.bottom, 10)
  }
}
