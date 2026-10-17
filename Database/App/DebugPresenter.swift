#if DEBUG && os(macOS)
  import AppKit
  import SwiftUI

  /// `--present [--present-delay 3] [--activate]`: after the delay, brings the window (and any sheet on it) up
  /// without taking focus (or, with `--activate`, makes it the active window) and prints `window <number>`, so
  /// a script can capture it with `screencapture -l`.
  ///
  /// Screenshots (`.dev/screenshots.json`, Dev's `dev-screenshots`) launch the app in the background, and macOS
  /// doesn't create SwiftUI's window until the app is activated. So in that mode the app hosts the same content in
  /// its own window instead.
  @MainActor
  enum DebugPresenter {
    private static var hostWindow: NSWindow?

    nonisolated static func prepare<Content: View>(_ content: @escaping @MainActor () -> Content) {
      // `--appearance light|dark`: screenshots shouldn't depend on the Mac's own setting.
      if let name = LaunchOptions.value("--appearance") {
        Task { @MainActor in NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua) }
      }
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
        // The kit's toolbar draws in the title bar; a hosting controller doesn't bridge SwiftUI's hidden toolbar
        // background, so the title bar's own would cover it.
        window.titlebarAppearsTransparent = true
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
      if LaunchOptions.flag("--activate") {
        // App Store screenshots want the active-window look. An app launched in the background can't make itself
        // active, so the script that launched it reopens it (like a Dock click) when it reads this line.
        print("activate")
        fflush(stdout)
        for _ in 0..<50 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
        window.makeKeyAndOrderFront(nil)
      }
      window.orderFrontRegardless()
      window.sheets.forEach { $0.orderFrontRegardless() }
      try? await Task.sleep(for: .milliseconds(600))
      print("window \(window.windowNumber)")
      fflush(stdout)
    }
  }
#endif
