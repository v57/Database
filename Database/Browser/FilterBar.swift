import ComponentKit
import DatabaseKit
import SwiftUI

/// Search, filter chips, sort and fields: the simple bar above the list.
struct FilterBar: View {
  @Bindable var browser: BrowserModel
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var addingFilter = false
  @State private var searchText = ""

  var body: some View {
    HStack(spacing: KitMetrics.gutter) {
      if browser.engine.supportsSearch {
        KitSearchField(
          text: $searchText, prompt: "Search \(browser.ref.name)", scope: scope, scopes: scopes,
          status: searchStatus, count: searchCount
        )
        .frame(minWidth: 180, maxWidth: 300)
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
            FilterToken(text: filter.summary(category: browser.category(of: filter.field))) {
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
          .buttonStyle(.kit)
          .popover(isPresented: $addingFilter, arrowEdge: .bottom) {
            AddFilterView(browser: browser) { filter in
              addingFilter = false
              Task { await browser.addFilter(filter) }
            }
            .componentKit(accent: .databaseAccent)
          }
          .disabled(browser.fields.isEmpty)
        }
        .padding(.vertical, 2)
      }
      .scrollClipDisabled()
      Spacer(minLength: 4)
      if browser.engine.family != .wideColumn && browser.engine != .redis {
        SortMenu(browser: browser)
      }
      if browser.engine != .redis {
        FieldsMenu(browser: browser)
      }
    }
    .controlSize(.small)
    .padding(.horizontal, KitMetrics.gutter)
    .padding(.vertical, 6)
    .onAppear { searchText = browser.request.search }
  }

  private var scopes: [SearchScope] {
    [SearchScope(field: nil, isDocument: browser.engine.family == .document)]
      + browser.fields.filter { $0.category == .text || $0.category == .uuid }.map { SearchScope(field: $0.name) }
  }

  private var scope: Binding<SearchScope> {
    Binding(
      get: { SearchScope(field: browser.searchField, isDocument: browser.engine.family == .document) },
      set: { scope in
        browser.searchField = scope.field
        if !browser.request.search.isEmpty { Task { await browser.reload() } }
      })
  }

  /// The search's live icon: the arc while it runs, then how many matched.
  private var searchStatus: WorkStatus {
    guard !browser.request.search.isEmpty else { return .idle }
    if browser.isLoading { return .working }
    return browser.records.isEmpty ? .failed : .done
  }

  private var searchCount: String? {
    guard !browser.request.search.isEmpty, !browser.isLoading, !browser.records.isEmpty else { return nil }
    let total = browser.exactTotal ?? browser.page?.total ?? browser.records.count
    return browser.noun.count(total)
  }

  private func commitSearch() {
    browser.request.search = searchText
    Task { await browser.reload() }
  }
}

/// Where the search looks: any column, or one.
struct SearchScope: KitOption {
  var field: String?
  var isDocument = false

  var title: String { field ?? (isDocument ? "Any field" : "Any column") }

  static func == (a: Self, b: Self) -> Bool { a.field == b.field }
  func hash(into hasher: inout Hasher) { hasher.combine(field) }
}

/// An active filter: the condition as a chip, and its remove button.
struct FilterToken: View {
  let text: String
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Chip(text, systemImage: "line.3.horizontal.decrease", hue: .accent)
      Button("Remove filter: \(text)", systemImage: "xmark", action: onRemove)
        .buttonStyle(.kitIcon)
        .controlSize(.small)
    }
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
    VStack(alignment: .leading, spacing: 10) {
      FormCard("Add Filter") {
        FormRow("Field", systemImage: "tablecells", hue: .gray) {
          Picker("Field", selection: $field) {
            ForEach(browser.fields) { field in
              Text(field.keyRole != nil ? "\(field.name) (key)" : field.name).tag(field.name)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
        FormRow("Condition", systemImage: "line.3.horizontal.decrease", hue: .accent) {
          Picker("Condition", selection: $op) {
            ForEach(ops) { Text($0.label(for: selectedField?.category ?? .text)).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
        if op.needsValue {
          if selectedField?.category == .boolean {
            FormRow("Value", systemImage: "checkmark.circle", hue: .gray) {
              KitSegmented(selection: $value, options: [("true", "true"), ("false", "false")])
            }
          } else {
            FormRow(op == .inLastDays ? "Days" : "Value", systemImage: "character.cursor.ibeam", hue: .gray,
              field: TextField(op == .inLastDays ? "Days" : "Value", text: $value, prompt: Text(placeholder)).onSubmit(add))
          }
        }
      }
      if browser.engine.family == .wideColumn, let field = selectedField, field.keyRole != .partition {
        Text("Filtering on \(field.name) reads the whole table unless the partition key is filtered too.")
          .kitFont(.caption)
          .foregroundStyle(Hue.orange.text)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
      HStack {
        Spacer()
        Button("Add Filter", action: add)
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
          .disabled(field.isEmpty || (op.needsValue && value.isEmpty))
      }
      .controlSize(.small)
    }
    .padding(KitMetrics.gutter)
    .frame(width: 360)
    .background(.kitPanel)
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
    .menuStyle(.button)
    .buttonStyle(.kit)
    .menuIndicator(.hidden)
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
    .menuStyle(.button)
    .buttonStyle(.kit)
    .menuIndicator(.hidden)
    .fixedSize()
  }
}

/// The query the simple bar wrote; editable and runnable.
struct QueryStrip: View {
  @Bindable var browser: BrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      RichHeader(
        browser.queryIsCustom ? "Edited query" : "\(browser.engine.queryLanguage) written by the bar",
        meta: browser.queryIsCustom ? "Results replace the list below" : "Edit it to go further",
        systemImage: "chevron.left.forwardslash.chevron.right"
      ) {
        HStack(spacing: 4) {
          if browser.queryIsCustom {
            Button("Reset") { browser.resetQuery() }
              .buttonStyle(.kitPlain)
          }
          Button("Run", systemImage: "play.fill") { Task { await browser.runQuery() } }
            .buttonStyle(.kitPrimary)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .controlSize(.small)
      }
      CodeEditor(
        text: Binding(get: { browser.queryText }, set: { browser.editQuery($0) }), language: browser.engine.highlighting,
        completions: [])
        .frame(height: max(64, min(220, CGFloat(browser.queryText.split(separator: "\n", omittingEmptySubsequences: false).count) * 20 + 24)))
        .background(.kitField, in: RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
    }
    .kitCard()
    .padding(.horizontal, KitMetrics.gutter)
    .padding(.bottom, KitMetrics.gutter)
  }
}
