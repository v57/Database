#if canImport(AppKit)
import AppKit

/// Routes Finder "Open With…" launches and dock drops of database files into
/// the app: the first file becomes a saved SQLite connection and connects
/// immediately. SwitchUI's NSApplicationDelegateAdaptor creates the delegate;
/// DatabaseApp.init hands it the app's single DatabaseModel.
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Set once at app init; weak — DatabaseApp owns the model.
  weak var model: DatabaseModel?

  func application(_ application: NSApplication, open urls: [URL]) { openFirstFile(urls) }

  func application(_ application: NSApplication, openFiles filenames: [String]) {
    openFirstFile(filenames.map { URL(fileURLWithPath: $0) })
  }

  private func openFirstFile(_ urls: [URL]) {
    guard let first = urls.first(where: { $0.isFileURL }) else { return }
    Task { @MainActor in await model?.openSQLiteFile(at: first.path) }
  }
}
#endif
