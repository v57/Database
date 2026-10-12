import DatabaseCore
import SwiftUI

/// Every pending change, old → new, with the statements that will run. Nothing is written before Save.
struct ReviewSheet: View {
  @Bindable var browser: BrowserModel
  @Environment(\.dismiss) private var dismiss
  @State private var showsStatements = true
  @State private var saving = false

  private var profile: ConnectionProfile { browser.connection.profile }
  private var deletes: Int { browser.pending.filter { if case .delete = $0.kind { true } else { false } }.count }
  private var inserts: Int { browser.pending.filter { if case .insert = $0.kind { true } else { false } }.count }
  private var updates: Int { browser.pending.count - deletes - inserts }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          header
          ForEach(browser.pending) { edit in
            EditCard(edit: edit, browser: browser)
          }
          if browser.pending.isEmpty {
            Text("Nothing to review.").foregroundStyle(.secondary)
          }
          statements
          if browser.engine.family != .document || browser.pending.count == 1 {
            Label("After saving you can undo with Undo in the confirmation, or Edit › Undo Last Save.", systemImage: "arrow.uturn.backward")
              .font(.callout)
              .foregroundStyle(.secondary)
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
          } else {
            Label("MongoDB without a replica set saves documents one at a time; if one fails, the ones before it stay saved and can be undone.", systemImage: "info.circle")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          if let error = browser.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
          }
        }
        .padding(24)
      }
      Divider()
      footer
    }
    .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 620)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      EngineTile(engine: profile.engine, size: 40)
      VStack(alignment: .leading, spacing: 3) {
        Text("Review \(browser.pending.count) Change\(browser.pending.count == 1 ? "" : "s")").font(.title2.bold())
        HStack(spacing: 4) {
          Text("\(browser.ref.name) on")
          Text(profile.displayName + (profile.isProduction ? " (Production)" : ""))
            .fontWeight(.semibold)
            .foregroundStyle(profile.isProduction ? .red : .primary)
          Text(transactionNote)
        }
        .foregroundStyle(.secondary)
      }
    }
  }

  private var transactionNote: String {
    switch browser.engine.family {
    case .sql: browser.pending.count > 1 ? "· saved together, or none are." : ""
    case .wideColumn: browser.pending.count > 1 ? "· saved as one batch." : ""
    default: ""
    }
  }

  @ViewBuilder private var statements: some View {
    let lines = browser.statements()
    if !lines.isEmpty {
      DisclosureGroup(isExpanded: $showsStatements) {
        Text(lines.map { $0 + (browser.engine.family == .sql ? ";" : "") }.joined(separator: "\n"))
          .font(.codeSmall)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
      } label: {
        Text(browser.engine.family == .sql ? "SQL that will run" : "\(browser.engine.queryLanguage) that will run")
          .fontWeight(.medium)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Text(summary).font(.callout).foregroundStyle(.secondary)
      Spacer()
      Button("Discard All", role: .destructive) {
        browser.discardChanges()
        dismiss()
      }
      .disabled(browser.pending.isEmpty)
      Button("Keep Editing") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button {
        Task {
          saving = true
          if await browser.save() { dismiss() }
          saving = false
        }
      } label: {
        if saving { ProgressView().controlSize(.small) } else { Text("Save \(browser.pending.count) Change\(browser.pending.count == 1 ? "" : "s")") }
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(browser.pending.isEmpty || saving || profile.isReadOnly)
    }
    .padding(16)
  }

  private var summary: String {
    var parts: [String] = []
    if updates > 0 { parts.append("\(updates) changed") }
    if inserts > 0 { parts.append("\(inserts) added") }
    if deletes > 0 { parts.append("\(deletes) deleted") }
    return parts.joined(separator: ", ")
  }
}

/// One pending change.
struct EditCard: View {
  let edit: RecordEdit
  let browser: BrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        TagLabel(text: edit.verb, color: color)
        Text(edit.title).fontWeight(.semibold).lineLimit(1)
        Spacer()
        if case .delete(let record) = edit.kind, let summary = deleteSummary(record) {
          Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Button("Revert") { browser.revert(edit.id) }
          .buttonStyle(.borderless)
          .font(.callout)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(color.opacity(edit.verb == "DELETE" ? 0.08 : 0.04))
      switch edit.kind {
      case .update(let changes):
        Divider()
        VStack(spacing: 0) {
          ForEach(changes) { change in
            ChangeRow(field: change.field, old: change.old, new: change.new)
          }
        }
        .padding(.vertical, 4)
      case .insert(let values):
        Divider()
        VStack(spacing: 0) {
          ForEach(values.keys.sorted(), id: \.self) { key in
            ChangeRow(field: key, old: nil, new: values[key]!)
          }
        }
        .padding(.vertical, 4)
      case .delete:
        EmptyView()
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(edit.verb == "DELETE" ? 0.4 : 0.2)))
  }

  private var color: Color {
    switch edit.kind {
    case .update: .blue
    case .insert: .green
    case .delete: .red
    }
  }

  private func deleteSummary(_ record: Record) -> String? {
    let parts = browser.fields.prefix(4).filter { !$0.isPrimaryKey }.compactMap { record[$0.name]?.displayText }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

struct ChangeRow: View {
  let field: String
  let old: CellValue?
  let new: CellValue

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(field).foregroundStyle(.secondary).frame(width: 120, alignment: .leading).lineLimit(1)
      HStack(spacing: 8) {
        if let old {
          Text(old == .unset ? "missing" : old.isNull ? "empty" : old.displayText)
            .strikethrough()
            .italic(old.isNull || old == .unset)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Image(systemName: "arrow.right").foregroundStyle(.secondary).imageScale(.small)
        }
        Text(new == .unset ? "removed" : new.isNull ? "empty" : new.displayText)
          .fontWeight(.semibold)
          .foregroundStyle(new == .unset ? .red : .green)
          .padding(.horizontal, 7)
          .padding(.vertical, 1)
          .background((new == .unset ? Color.red : Color.green).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
          .lineLimit(3)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
  }
}
