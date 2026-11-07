#if DEBUG
  import DatabaseKit
  import Foundation

  /// Opens a sidebar path, at launch (`--select`) or on request (`listenForSelectRequests`).
  @MainActor
  public enum DebugSelect {
    /// Selects a sidebar path ("Shop/shop/public/orders": a connection, then the titles down to a table), connecting
    /// and expanding on the way; returns the connection.
    @discardableResult
    static func select(_ path: String, in window: WindowModel) async -> LiveConnection? {
      let app = window.app
      let parts = path.split(separator: "/").map(String.init)
      guard let first = parts.first, let profile = app.profiles.first(where: { $0.name == first }) else { return nil }
      window.selection = .connection(profile.id)
      let connection = app.connection(for: profile.id)
      await connection.connect()
      var parent: TreeNode?
      var target: TreeNode?
      for title in parts.dropFirst() {
        await connection.loadChildren(of: parent)
        guard let node = connection.children[connection.key(parent)]?.first(where: { $0.title == title }) else { break }
        connection.expanded.insert(connection.key(parent))
        if node.hasChildren {
          connection.expanded.insert(node.id)
          parent = node
        } else {
          target = node
        }
      }
      if let target {
        window.selection = .node(profile.id, target)
      }
      return connection
    }

    #if os(macOS)
      /// `notifyutil -p dev.v57.database.debug.select` selects the path `/tmp/database-select-<bundle id>.txt` names
      /// (a `--select` argument) in `window`: sidebar switches for performance runs, without clicks or accessibility
      /// lookups.
      public static func listenForSelectRequests(_ window: WindowModel) {
        selectWindow = window
        guard !isListening else { return }
        isListening = true
        CFNotificationCenterAddObserver(
          CFNotificationCenterGetDarwinNotifyCenter(), UnsafeRawPointer(bitPattern: 0x4442_5345),
          { _, _, _, _, _ in
            DispatchQueue.main.async {
              MainActor.assumeIsolated {
                let url = URL(fileURLWithPath: "/tmp/database-select-\(Bundle.main.bundleIdentifier ?? "app").txt")
                guard let window = DebugSelect.selectWindow,
                  let path = try? String(contentsOf: url, encoding: .utf8)
                else { return }
                Task { await DebugSelect.select(path.trimmingCharacters(in: .whitespacesAndNewlines), in: window) }
              }
            }
          }, "dev.v57.database.debug.select" as CFString, nil, .deliverImmediately)
      }

      private weak static var selectWindow: WindowModel?
      private static var isListening = false
    #endif

  }
#endif
