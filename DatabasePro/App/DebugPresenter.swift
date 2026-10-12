#if DEBUG && os(macOS)
  import AppKit
  import SwiftUI

  /// `--present [--present-delay 3]`: after the delay, brings the window (and any sheet on it) up without taking
  /// focus and prints `window <number>`, so Scripts/shoot.sh can capture it with `screencapture -l`.
  ///
  /// Scripts/shoot.sh launches the app in the background, and macOS doesn't create SwiftUI's window until the app
  /// is activated. So in that mode the app hosts the same content in its own window instead.
  @MainActor
  enum DebugPresenter {
    private static var hostWindow: NSWindow?

    nonisolated static func prepare<Content: View>(_ content: @escaping @MainActor () -> Content) {
      guard LaunchOptions.flag("--present") else { return }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        guard !NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        let controller = NSHostingController(rootView: content())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(
          contentRect: NSRect(x: 180, y: 160, width: 1440, height: 900),
          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
          defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.orderFrontRegardless()
        hostWindow = window
      }
    }

    static func runIfRequested() async {
      guard LaunchOptions.flag("--present") else { return }
      let delay = LaunchOptions.value("--present-delay").flatMap(Double.init) ?? 3
      try? await Task.sleep(for: .seconds(delay))
      guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil })
      else { return }
      window.collectionBehavior.insert(.moveToActiveSpace)
      window.orderFrontRegardless()
      window.sheets.forEach { $0.orderFrontRegardless() }
      try? await Task.sleep(for: .milliseconds(600))
      print("window \(window.windowNumber)")
      fflush(stdout)
    }
  }
#endif
