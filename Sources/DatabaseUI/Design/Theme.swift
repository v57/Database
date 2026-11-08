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
  /// The tag whose hue is `hue` (`nil`: no tag).
  init(hue: Hue?) {
    self = Self.allCases.first { $0.hue == hue } ?? .none
  }

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
  if ms == -1 { return String(localized: "Never") }
  if ms < 0 { return String(localized: "Expired") }
  return String(localized: "in \(formatTTLDuration(seconds: ms / 1000))")
}

/// "23 min", "1 day": how long a key has left.
func formatTTLDuration(seconds: Int64) -> String {
  switch seconds {
  case ..<60: String(localized: "\(seconds) s")
  case ..<3600: String(localized: "\(seconds / 60) min")
  case ..<86400: String(localized: "\(seconds / 3600) hr")
  default: seconds / 86400 == 1 ? String(localized: "1 day") : String(localized: "\(seconds / 86400) days")
  }
}

func formatBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .memory) }
