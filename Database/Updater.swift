#if os(macOS)
import AppKit
import Database
import SwiftUI

/// Update check for the direct-download Mac app (the iOS app updates through
/// the App Store). Asks GitHub for the latest release at most once a day,
/// or when the user chooses Check for Updates…, and offers the download.
@MainActor @Observable final class Updater {
  static let shared = Updater()
  static let repository = "v57/Database"

  /// A newer release, shown as an alert until dismissed.
  var available: UpdateCheck.Release?
  /// The answer to a manual check that found nothing ("up to date", or why
  /// the check failed).
  var manualResult: String?

  private static let automaticKey = "checksForUpdatesAutomatically"
  private static let lastCheckKey = "lastUpdateCheck"

  var checksAutomatically: Bool {
    get { UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: Self.automaticKey) }
  }

  var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  /// Launch-time check: skipped when turned off or done in the last day.
  func checkIfDue() async {
    guard checksAutomatically else { return }
    let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
    guard Date.now.timeIntervalSince(last) > 24 * 60 * 60 else { return }
    await check(userInitiated: false)
  }

  func check(userInitiated: Bool) async {
    var request = URLRequest(url: UpdateCheck.latestReleaseURL(repository: Self.repository))
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200, let release = UpdateCheck.release(fromJSON: data) else {
        // 404: no release published yet.
        if userInitiated { manualResult = "No release is available to download yet." }
        return
      }
      if UpdateCheck.isVersion(release.version, newerThan: currentVersion) {
        available = release
      } else if userInitiated {
        manualResult = "Database \(currentVersion) is the latest version."
      }
    } catch {
      if userInitiated {
        manualResult = "Couldn’t check for updates: \(error.localizedDescription)"
      }
    }
  }

  func openDownload(_ release: UpdateCheck.Release) {
    NSWorkspace.shared.open(release.download ?? release.page)
  }
}

/// App menu: Check for Updates… and the automatic-check switch.
struct UpdateCommands: Commands {
  @State private var updater = Updater.shared

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
      Toggle(
        "Check for Updates Automatically",
        isOn: Binding(
          get: { updater.checksAutomatically }, set: { updater.checksAutomatically = $0 }))
    }
  }
}

/// The update alerts, attached to the main window's content.
struct UpdateAlerts: ViewModifier {
  @State private var updater = Updater.shared

  func body(content: Content) -> some View {
    content
      .task { await updater.checkIfDue() }
      .alert(
        updater.available.map { "Database \($0.version) is available" } ?? "",
        isPresented: Binding(
          get: { updater.available != nil }, set: { if !$0 { updater.available = nil } }),
        presenting: updater.available
      ) { release in
        Button("Download") { updater.openDownload(release) }
        Button("Release Notes") { NSWorkspace.shared.open(release.page) }
        Button("Later", role: .cancel) {}
      } message: { _ in
        Text("You have version \(updater.currentVersion). The download replaces it when you move it to Applications.")
      }
      .alert(
        updater.manualResult ?? "",
        isPresented: Binding(
          get: { updater.manualResult != nil }, set: { if !$0 { updater.manualResult = nil } })
      ) {
        Button("OK", role: .cancel) {}
      }
  }
}
#endif
