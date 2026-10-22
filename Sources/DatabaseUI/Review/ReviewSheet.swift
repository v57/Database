import ComponentKit
import DatabaseKit
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
    KitSheet(
      title: "Review \(browser.pending.count) Change\(browser.pending.count == 1 ? "" : "s")", meta: meta, width: 600,
      icon: { browser.connection.liveTile(size: 32) }
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          ForEach(browser.pending) { edit in
            EditCard(edit: edit, browser: browser)
          }
          if browser.pending.isEmpty {
            Text("Nothing to review.").foregroundStyle(.kitSecondary).padding(8)
          }
          statements
          if browser.engine.family != .document || browser.pending.count == 1 {
            ReviewNote(text: "After saving you can undo with Undo in the confirmation, or Edit › Undo Last Save.", systemImage: "arrow.uturn.backward")
          } else {
            ReviewNote(text: "MongoDB without a replica set saves documents one at a time; if one fails, the ones before it stay saved and can be undone.", systemImage: "info.circle")
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
      VStack(alignment: .leading, spacing: 6) {
        Button {
          withKitAnimation { showsStatements.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .bold))
              .rotationEffect(.degrees(showsStatements ? 90 : 0))
            Text(browser.engine.family == .sql ? "SQL that will run" : "\(browser.engine.queryLanguage) that will run")
              .kitFont(.headline)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        if showsStatements {
          HighlightedCode(
            text: lines.map { $0 + (browser.engine.family == .sql ? ";" : "") }.joined(separator: "\n"),
            language: browser.engine.highlighting
          )
          .kitFont(.monoSmall)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.kitField, in: RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous))
        }
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

/// A quiet line in its own card under the changes.
private struct ReviewNote: View {
  let text: String
  let systemImage: String

  var body: some View {
    Label(text, systemImage: systemImage)
      .kitFont(.callout)
      .foregroundStyle(.kitSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .kitSurface(.card)
  }
}

/// One pending change: its kind, what it applies to and Revert, then each field old → new.
struct EditCard: View {
  let edit: RecordEdit
  let browser: BrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Chip(edit.verb, hue: hue)
        Text(edit.title).kitFont(.headline).lineLimit(1)
        Spacer()
        if case .delete(let record) = edit.kind, let summary = deleteSummary(record) {
          Text(summary).kitFont(.caption).lineLimit(1)
        }
        Button("Revert") { withKitAnimation { browser.revert(edit.id) } }
          .buttonStyle(.kitPlain)
          .controlSize(.small)
      }
      .padding(.leading, 12)
      .padding(.trailing, 4)
      .frame(minHeight: 40)
      switch edit.kind {
      case .update(let changes):
        ForEach(changes) { change in
          FieldChangeRow(field: change.field, old: change.old, new: change.new)
        }
      case .insert(let values):
        ForEach(values.keys.sorted(), id: \.self) { key in
          FieldChangeRow(field: key, old: nil, new: values[key]!)
        }
      case .delete:
        EmptyView()
      }
    }
    .padding(.bottom, isDelete ? 0 : 4)
    .kitSurface(.card)
    .overlay {
      if isDelete {
        RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous).fill(Hue.red.soft(0.08)).allowsHitTesting(false)
      }
    }
  }

  private var isDelete: Bool { if case .delete = edit.kind { true } else { false } }

  private var hue: Hue {
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

/// One field of a change: its name, the old value struck through, the new one in a chip.
struct FieldChangeRow: View {
  let field: String
  let old: CellValue?
  let new: CellValue

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(field).foregroundStyle(.kitSecondary).frame(width: 140, alignment: .leading).lineLimit(1)
      ChangeValues(old: old?.reviewText, new: nil)
      if old != nil {
        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.kitSecondary)
      }
      Chip(new.reviewText, hue: new == .unset ? .red : .green)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 30)
    .overlay(alignment: .top) { Rectangle().fill(.kitSeparator).frame(height: 0.5).padding(.horizontal, 12) }
  }
}
