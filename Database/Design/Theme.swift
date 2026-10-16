import ComponentKit
import DatabaseKit
import SwiftUI

/// The engine's hue, for its two-letter tile and its sidebar icons.
extension EngineKind {
  var hue: Hue {
    switch self {
    case .postgres: .blue
    case .mysql: .teal
    case .mariadb: .brown
    case .sqlserver: .pink
    case .sqlite: .gray
    case .duckdb: .yellow
    case .mongodb: .green
    case .redis: .red
    case .cassandra: .indigo
    case .scylla: .purple
    }
  }

  /// The engine's two-letter tile ("Pg").
  func tile(size: CGFloat = 24) -> Tile<Text> {
    Tile(letters: monogram, hue: hue, size: size)
  }
}

extension ColorTag {
  var hue: Hue? {
    switch self {
    case .none: nil
    case .red: .red
    case .orange: .orange
    case .yellow: .yellow
    case .green: .green
    case .blue: .blue
    case .purple: .purple
    case .gray: .gray
    }
  }
}

extension ConnectionProfile {
  /// Production and read-only markers, as the kit's chips.
  @ViewBuilder var safetyChips: some View {
    if isProduction { Chip.production }
    if isReadOnly { Chip.readOnly }
  }
}

/// Plain-language errors.
enum FriendlyError {
  static func message(_ error: Error) -> String {
    if let local = error as? LocalizedError, let description = local.errorDescription { return description }
    return error.localizedDescription
  }
}

/// "14 ms", "1.2 s".
func formatDuration(_ seconds: TimeInterval) -> String {
  seconds < 1 ? "\(max(1, Int((seconds * 1000).rounded()))) ms" : String(format: "%.1f s", seconds)
}

/// "in 23 min", "Never", "Expired".
func formatTTL(milliseconds ms: Int64) -> String {
  if ms == -1 { return "Never" }
  if ms < 0 { return "Expired" }
  let seconds = ms / 1000
  switch seconds {
  case ..<60: return "in \(seconds) s"
  case ..<3600: return "in \(seconds / 60) min"
  case ..<86400: return "in \(seconds / 3600) hr"
  default: return "in \(seconds / 86400) day\(seconds / 86400 == 1 ? "" : "s")"
  }
}

func formatBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .memory) }

extension ToolbarContent {
  /// The kit's toolbar views (`KitTitle`, `ToolGroup`, `KitSegmented`) draw their own cards, so the toolbar's Liquid
  /// Glass capsule stays out from behind them.
  @ToolbarContentBuilder func kitBare() -> some ToolbarContent {
    if #available(macOS 26, iOS 26, *) {
      sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}

extension View {
  /// Each pane names itself in its own `KitTitle`, so the window's title stays out of the toolbar.
  @ViewBuilder func hidesWindowTitle() -> some View {
    #if os(macOS)
      if #available(macOS 15, *) { toolbar(removing: .title) } else { self }
    #else
      self
    #endif
  }
}

extension View {
  /// The pane's meta line under its title: the window subtitle on the Mac, the navigation subtitle on iPad.
  @ViewBuilder func navigationMeta(_ text: String) -> some View {
    #if os(macOS)
      navigationSubtitle(text)
    #else
      if #available(iOS 26, *) { navigationSubtitle(text) } else { self }
    #endif
  }
}
