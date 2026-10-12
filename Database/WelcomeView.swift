import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What the window shows before anything is open: three plain ways in —
/// the sample database, a database file, or a server (where a pasted
/// connection link fills in the form).
struct WelcomeView: View {
  @Query private var records: [ConnectionRecord]

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        Image(systemName: "cylinder.split.1x2.fill").font(.system(size: 44))
          .foregroundStyle(.tint).accessibilityHidden(true)
        VStack(spacing: 6) {
          Text("Open a Database").font(.largeTitle.bold())
          Text(
            "Look through and edit MongoDB, PostgreSQL, Redis and SQLite databases. No query language needed."
          )
          .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        WelcomeActions()
        if !records.isEmpty {
          Text("Your saved connections are in the sidebar.").font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: 520)
      .padding(32)
      .frame(maxWidth: .infinity)
    }
  }
}

/// The welcome choices as large buttons. Shared by the welcome screen and,
/// on iPhone (where the detail pane isn't visible yet), the sidebar.
struct WelcomeActions: View {
  @Environment(DatabaseModel.self) private var model
  @State private var showsConnectionForm = false
  @State private var isImportingFile = false

  var body: some View {
    VStack(spacing: 10) {
      WelcomeCard(
        title: "Try the Sample Database",
        detail: "A small movie collection to explore and practise on.",
        systemImage: "film.stack"
      ) {
        Task { await model.openSampleDatabase() }
      }
      WelcomeCard(
        title: "Open a Database File…",
        detail: "A SQLite file (.sqlite, .db) on this \(deviceName).",
        systemImage: "doc"
      ) {
        openFile()
      }
      WelcomeCard(
        title: "Connect to a Server…",
        detail: "MongoDB, PostgreSQL or Redis. Have a link like postgres://…? Paste it in the next step.",
        systemImage: "network"
      ) {
        showsConnectionForm = true
      }
    }
    .disabled(model.isConnecting)
    .sheet(isPresented: $showsConnectionForm) { ConnectionFormView() }
    .fileImporter(isPresented: $isImportingFile, allowedContentTypes: Self.databaseTypes) { result in
      guard case .success(let url) = result else { return }
      // A Files pick outside the app container is security-scoped: open it
      // now and keep a bookmark so the file opens again after a relaunch.
      FileAccess.open(url)
      let bookmark = try? url.bookmarkData()
      Task { await model.openSQLiteFile(at: url.path, bookmark: bookmark) }
    }
  }

  private var deviceName: String {
#if os(iOS)
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
#else
    "Mac"
#endif
  }

  static let databaseTypes = ["sqlite", "sqlite3", "db", "db3"].compactMap {
    UTType(filenameExtension: $0)
  }

  /// macOS: an open panel (the app is unsandboxed, so plain paths stay
  /// readable). iOS: the Files picker.
  private func openFile() {
#if os(macOS)
    let panel = NSOpenPanel()
    panel.title = "Open a Database File"
    panel.allowedContentTypes = Self.databaseTypes
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { await model.openSQLiteFile(at: url.path) }
    }
#else
    isImportingFile = true
#endif
  }
}

/// One large welcome button: icon, title and a line saying what it's for.
private struct WelcomeCard: View {
  let title: String
  let detail: String
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: systemImage).font(.title2).foregroundStyle(.tint)
          .frame(width: 44, height: 44)
          .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline).foregroundStyle(.primary)
          Text(detail).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.callout).foregroundStyle(.tertiary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
      .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .accessibilityHint(detail)
  }
}
