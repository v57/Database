import SwiftUI

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Plain-text clipboard writes for the "Copy …" context-menu items.
enum Clipboard {
  static func copy(_ text: String) {
#if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#else
    UIPasteboard.general.string = text
#endif
  }
}

extension View {
  /// Grows a small icon button's hit area to a comfortable touch size on iOS
  /// (Apple's 44pt guideline by default); pointer platforms keep their look.
  func touchTarget(_ size: CGFloat = 44) -> some View {
#if os(iOS)
    frame(minWidth: size, minHeight: size).contentShape(Rectangle())
#else
    self
#endif
  }
}

extension View {
  /// The ↔ resize pointer over a column edge (macOS 15+; older systems keep
  /// the arrow, the drag still works).
  @ViewBuilder func columnResizePointer() -> some View {
#if os(macOS)
    if #available(macOS 15, *) { pointerStyle(.columnResize) } else { self }
#else
    self
#endif
  }
}

extension String {
  /// The text with typographic quotes (“ ” ‘ ’) made straight, or nil when
  /// there are none. iOS Smart Punctuation curls quotes as they're typed,
  /// which turns `{ a: "x" }` into an unparseable query; SwiftUI offers no
  /// way to switch it off per field, so query fields straighten their text.
  var withStraightQuotes: String? {
    guard contains(where: { "“”„‘’‚".contains($0) }) else { return nil }
    return String(
      map { character -> Character in
        switch character {
        case "“", "”", "„": "\""
        case "‘", "’", "‚": "'"
        default: character
        }
      })
  }
}

extension View {
  /// A bar pinned to the top edge that content scrolls under: `safeAreaBar`
  /// where available (macOS/iOS 26), a plain safe-area inset before that.
  @ViewBuilder func topBar(@ViewBuilder _ content: () -> some View) -> some View {
    if #available(macOS 26, iOS 26, *) {
      safeAreaBar(edge: .top, content: content)
    } else {
      safeAreaInset(edge: .top, spacing: 0, content: content)
    }
  }

  /// Window/navigation subtitle (iOS has one from iOS 26; older iOS shows none).
  @ViewBuilder func subtitle(_ text: String) -> some View {
#if os(macOS)
    navigationSubtitle(text)
#else
    if #available(iOS 26, *) { navigationSubtitle(text) } else { self }
#endif
  }
}
