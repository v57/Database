import Foundation

/// The loads in flight (connecting, a tree level, a page, a pipeline preview, an inspector's related rows), so a
/// screenshot scene can wait until its screen has finished loading rather than for a fixed time.
@MainActor
enum Activity {
  private static var running = 0

  static func begin() { running += 1 }
  static func end() { running -= 1 }

  /// Returns once nothing has loaded for `quiet`, so the loads views start after laying out the screen count too.
  static func settle(quiet: Duration = .milliseconds(500), timeout: Duration = .seconds(30)) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var idleSince = clock.now
    while clock.now < deadline {
      if running > 0 {
        idleSince = clock.now
      } else if clock.now - idleSince >= quiet {
        return
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }
}
