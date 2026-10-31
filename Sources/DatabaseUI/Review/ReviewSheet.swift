import ComponentKit
import DatabaseKit
import SwiftUI

/// Every pending change, old → new, with the statements that will run. Nothing is written before Save.
struct ReviewSheet: View {
  @Bindable var browser: BrowserModel
  @Environment(\.kitDismiss) private var dismiss
  @State private var showsStatements = true
  @State private var saving = false

  private var profile: ConnectionProfile { browser.connection.profile }
  private var deletes: Int { browser.pending.filter { if case .delete = $0.kind { true } else { false } }.count }
  private var inserts: Int { browser.pending.filter { if case .insert = $0.kind { true } else { false } }.count }
  private var updates: Int { browser.pending.count - deletes - inserts }

  var body: some View {
    KitSheet(
      title: "Review \(browser.pending.count) Change\(browser.pending.count == 1 ? "" : "s")", meta: meta, width: 600,
      icon: { browser.connection.liveTile(size: 32) }
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          if browser.pending.isEmpty {
            NoteLine("Nothing to review.", systemImage: nil).padding(.vertical, 8)
          } else {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(browser.pending) { edit in
                ReviewEditRows(edit: edit, browser: browser)
              }
            }
            .kitCard()
          }
          statements
          if browser.engine.family != .document || browser.pending.count == 1 {
            NoteLine("After saving you can undo with Undo in the confirmation, or Edit › Undo Last Save.", systemImage: "arrow.uturn.backward")
          } else {
            NoteLine("MongoDB without a replica set saves documents one at a time; if one fails, the ones before it stay saved and can be undone.")
          }
          if let error = browser.errorMessage {
            Banner(error, systemImage: "exclamationmark.triangle", hue: .red)
          }
        }
      }
      .frame(minHeight: 200, idealHeight: 420, maxHeight: 560)
      .fixedSize(horizontal: false, vertical: true)
    } footer: {
      SheetStatus(summary, systemImage: "checklist", hue: .orange, status: saving ? .working : .idle)
      Button("Discard All", role: .destructive) {
        browser.discardChanges()
        dismiss()
      }
      .disabled(browser.pending.isEmpty)
      Button("Keep Editing") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save \(browser.pending.count) Change\(browser.pending.count == 1 ? "" : "s")") {
        Task {
          saving = true
          if await browser.save() { dismiss() }
          saving = false
        }
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(browser.pending.isEmpty || saving || profile.isReadOnly)
    }
  }

  private var meta: String {
    var parts = ["\(browser.ref.name) on \(profile.displayName)" + (profile.isProduction ? " (Production)" : "")]
    if let note = transactionNote { parts.append(note) }
    return parts.joined(separator: " · ")
  }

  private var transactionNote: String? {
    switch browser.engine.family {
    case .sql: browser.pending.count > 1 ? "saved together, or none are" : nil
    case .wideColumn: browser.pending.count > 1 ? "saved as one batch" : nil
    default: nil
    }
  }

  @ViewBuilder private var statements: some View {
    let lines = browser.statements()
    if !lines.isEmpty {
      KitSection(
        browser.engine.family == .sql ? "SQL that will run" : "\(browser.engine.queryLanguage) that will run",
        meta: lines.count == 1 ? "1 statement" : "\(lines.count) statements",
        systemImage: "chevron.left.forwardslash.chevron.right", hue: .gray, isExpanded: $showsStatements
      ) {
        HighlightedCode(
          text: lines.map { $0 + (browser.engine.family == .sql ? ";" : "") }.joined(separator: "\n"),
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

  private var summary: String {
    var parts: [String] = []
    if updates > 0 { parts.append("\(updates) changed") }
    if inserts > 0 { parts.append("\(inserts) added") }
    if deletes > 0 { parts.append("\(deletes) deleted") }
    return parts.joined(separator: " · ")
  }
}

/// One pending change as the kit's change rows: a row a field (old → new) for an edit or a new item, one row for a
/// deletion, with Undo on the first.
private struct ReviewEditRows: View {
  let edit: RecordEdit
  let browser: BrowserModel

  var body: some View {
    let title = edit.key?.summary ?? edit.title
    let undo = { withKitAnimation { browser.revert(edit.id) } }
    switch edit.kind {
    case .update(let changes):
      ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
        ChangeRow(
          .edited, title: title, field: change.field, old: change.old.reviewText, new: change.new.reviewText,
          undo: index == 0 ? undo : nil)
      }
    case .insert(let values):
      ForEach(Array(values.keys.sorted().enumerated()), id: \.element) { index, key in
        ChangeRow(.inserted, title: title, field: key, new: values[key]?.reviewText, undo: index == 0 ? undo : nil)
      }
    case .delete(let record):
      ChangeRow(.deleted, title: title, field: "row", old: deleteSummary(record), undo: undo)
    }
  }

  private func deleteSummary(_ record: Record) -> String? {
    let parts = browser.fields.prefix(4).filter { !$0.isPrimaryKey }.compactMap { record[$0.name]?.displayText }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
