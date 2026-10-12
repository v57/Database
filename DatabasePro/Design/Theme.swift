import DatabaseCore
import SwiftUI

/// The engine's color, used for its two-letter tile.
extension EngineKind {
  var tint: Color {
    switch self {
    case .postgres: Color(red: 0.18, green: 0.42, blue: 0.75)
    case .mysql: Color(red: 0.05, green: 0.50, blue: 0.45)
    case .mariadb: Color(red: 0.55, green: 0.36, blue: 0.20)
    case .sqlserver: Color(red: 0.62, green: 0.13, blue: 0.27)
    case .sqlite: Color(red: 0.30, green: 0.37, blue: 0.47)
    case .duckdb: Color(red: 0.62, green: 0.50, blue: 0.0)
    case .mongodb: Color(red: 0.13, green: 0.50, blue: 0.27)
    case .redis: Color(red: 0.72, green: 0.25, blue: 0.08)
    case .cassandra: Color(red: 0.22, green: 0.31, blue: 0.68)
    case .scylla: Color(red: 0.45, green: 0.22, blue: 0.62)
    }
  }
}

/// The rounded two-letter engine tile.
struct EngineTile: View {
  let engine: EngineKind
  var size: CGFloat = 22

  var body: some View {
    Text(engine.monogram)
      .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
      .foregroundStyle(engine.tint)
      .frame(width: size, height: size)
      .background(engine.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
      .accessibilityHidden(true)
  }
}

extension ColorTag {
  var color: Color? {
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

/// A small capsule label ("Production", "Read only").
struct TagLabel: View {
  let text: String
  var color: Color = .secondary
  var systemImage: String?

  var body: some View {
    HStack(spacing: 3) {
      if let systemImage { Image(systemName: systemImage).imageScale(.small) }
      Text(text)
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(color)
    .padding(.horizontal, 7)
    .padding(.vertical, 2)
    .background(color.opacity(0.14), in: Capsule())
  }
}

/// Type label next to a field ("Int32", "ZSET").
struct TypeBadge: View {
  let text: String
  var color: Color

  init(_ text: String, color: Color? = nil) {
    self.text = text
    self.color = color ?? TypeBadge.color(for: text)
  }

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      .lineLimit(1)
      .fixedSize()
  }

  static func color(for type: String) -> Color {
    switch type.uppercased() {
    case "STRING", "TEXT": .blue
    case "HASH", "INT32", "INT64", "DOUBLE", "DECIMAL128", "NUMBER": .purple
    case "LIST", "ARRAY", "OBJECT": .green
    case "SET": .teal
    case "ZSET", "DATE", "TIMESTAMP": .orange
    case "STREAM", "OBJECTID", "KEY": .brown
    case "BOOLEAN": .indigo
    default: .gray
    }
  }
}

/// Production / read-only markers for a connection.
struct SafetyTags: View {
  let profile: ConnectionProfile

  var body: some View {
    HStack(spacing: 4) {
      if profile.isProduction { TagLabel(text: "Production", color: .red) }
      if profile.isReadOnly { TagLabel(text: "Read only", color: .secondary, systemImage: "lock.fill") }
    }
  }
}

/// A status pill for common status words in a cell (shipped, pending, …).
enum StatusPill {
  static func color(for text: String) -> Color? {
    switch text.lowercased() {
    case "shipped", "done", "active", "paid", "completed", "success", "ok", "true": .green
    case "pending", "waiting", "processing", "draft", "open": .orange
    case "cancelled", "canceled", "failed", "error", "rejected", "false": .red
    case "refunded", "archived", "closed", "inactive": .gray
    default: nil
    }
  }
}

/// One button look everywhere: the system's bordered buttons in a capsule.
extension View {
  func appButtonShape() -> some View { buttonBorderShape(.capsule) }
}

extension View {
  /// Inset table with alternating rows on the Mac; plain inset on iPhone and iPad.
  @ViewBuilder func stripedTableStyle() -> some View {
    #if os(macOS)
      tableStyle(.inset(alternatesRowBackgrounds: true))
    #else
      tableStyle(.inset)
    #endif
  }

  /// A text link that opens something else in the app.
  @ViewBuilder func linkButtonStyle() -> some View {
    #if os(macOS)
      buttonStyle(.link)
    #else
      buttonStyle(.borderless)
    #endif
  }
}

/// Monospaced text for values, ids and code.
extension Font {
  static let code = Font.system(.body, design: .monospaced)
  static let codeSmall = Font.system(.caption, design: .monospaced)
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
