#if DEBUG && os(macOS)
  import AppKit
  import DatabaseUI
  import SwiftUI

  /// `--present [--present-delay 3] [--present-size 1440x600] [--activate]`: after the delay, brings the window (and any sheet on it) up
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
        // `--present-size 1440x600`: a shorter window, to see what overflows (sticky sidebar sections).
        let size =
          LaunchOptions.value("--present-size").map { $0.split(separator: "x").compactMap { Double($0) } }
          .flatMap { $0.count == 2 ? NSSize(width: $0[0], height: $0[1]) : nil } ?? NSSize(width: 1440, height: 900)
        let controller = NSHostingController(rootView: content())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(
          contentRect: NSRect(origin: NSPoint(x: 180, y: 160), size: size),
          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
          defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
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
      if let path = LaunchOptions.value("--scroll-probe") { await SidebarScrollProbe.run(in: window, writingTo: path) }
      if let path = LaunchOptions.value("--snapshot") { await snapshot(window, to: path) }
    }

    /// `--snapshot <file.png> [--snapshot-delay 2]`: draws the window (its sheet, when it has one) into a file, and
    /// beside it (`<file>.txt`) the sizes of its scroll views. Needs no screen, so it works on a locked Mac, and never
    /// takes focus.
    private static func snapshot(_ window: NSWindow, to path: String) async {
      let delay = LaunchOptions.value("--snapshot-delay").flatMap(Double.init) ?? 2
      try? await Task.sleep(for: .seconds(delay))
      guard let view = (window.sheets.first ?? window).contentView?.superview ?? window.contentView,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      else { return }
      view.layoutSubtreeIfNeeded()
      view.cacheDisplay(in: view.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      var lines: [String] = []
      func walk(_ view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
          lines.append(
            "scroll view \(scroll.contentView.bounds.size) document \(document.frame.size) "
              + "elastic h \(scroll.horizontalScrollElasticity.rawValue) v \(scroll.verticalScrollElasticity.rawValue) "
              + "scrollers h \(scroll.hasHorizontalScroller) v \(scroll.hasVerticalScroller)")
        }
        view.subviews.forEach(walk)
      }
      walk(view)
      try? lines.joined(separator: "\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }
  }

  /// `--scroll-probe <file>`: scrolls the sidebar to its end and back at 1500 pt/s and writes the frames that missed
  /// their display refresh, to measure a long tree without the real cursor.
  @MainActor
  private final class SidebarScrollProbe: NSObject {
    private let scrollView: NSScrollView
    private var link: CADisplayLink?
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    private var direction: CGFloat = 1
    private var frames = 0
    private var hitches = 0
    private var hitched = 0.0
    private var worst = 0.0
    private var finished: CheckedContinuation<Void, Never>?

    static func run(in window: NSWindow, writingTo path: String) async {
      guard let content = window.contentView, let scrollView = sidebar(in: content) else {
        try? "no sidebar scroll view\n".write(toFile: path, atomically: true, encoding: .utf8)
        return
      }
      let probe = SidebarScrollProbe(scrollView)
      await withCheckedContinuation { probe.start($0) }
      let height = scrollView.documentView?.frame.height ?? 0
      let line = String(
        format: "document %.0f pt, %d frames, %d hitches, %.0f ms hitched, worst %.0f ms\n", height, probe.frames,
        probe.hitches, probe.hitched * 1000, probe.worst * 1000)
      try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The tallest vertical scroll view at the window's leading edge.
    private static func sidebar(in view: NSView) -> NSScrollView? {
      var found: [NSScrollView] = []
      func walk(_ view: NSView) {
        if let scroll = view as? NSScrollView { found.append(scroll) }
        view.subviews.forEach(walk)
      }
      walk(view)
      return
        found
        .filter { $0.convert($0.bounds, to: nil).minX < 40 }
        .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private init(_ scrollView: NSScrollView) { self.scrollView = scrollView }

    private func start(_ finished: CheckedContinuation<Void, Never>) {
      self.finished = finished
      // A sleeping display has no refreshes: a timer steps it, and the layout of each step is what's measured.
      if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.step(now: CACurrentMediaTime(), budget: 1.0 / 60)
            self.scrollView.window?.layoutIfNeeded()
          }
        }
      } else {
        let link = scrollView.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
      }
    }

    @objc private func tick(_ link: CADisplayLink) {
      step(now: link.timestamp, budget: max(link.duration, 1.0 / 120))
    }

    private func step(now: CFTimeInterval, budget: CFTimeInterval) {
      defer { last = now }
      guard last > 0 else { return }
      let gap = now - last
      frames += 1
      if gap > budget * 1.5 {
        hitches += 1
        hitched += gap - budget
        worst = max(worst, gap)
      }
      let clip = scrollView.contentView
      let end = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
      var y = clip.bounds.origin.y + direction * 1500 * min(gap, 0.1)
      if direction > 0, y >= end {
        y = end
        direction = -1
      } else if direction < 0, y <= 0 {
        link?.invalidate()
        timer?.invalidate()
        finished?.resume()
        finished = nil
        return
      }
      clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
      scrollView.reflectScrolledClipView(clip)
    }
  }
#endif
