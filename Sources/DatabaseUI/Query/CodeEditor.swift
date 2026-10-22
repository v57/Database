import CodeHighlighting
import DatabaseKit
import SwiftUI

extension EngineKind {
  /// The CodeHighlighting (`../Code`) language its queries are written in.
  var highlighting: String {
    switch family {
    case .sql: "sql"
    case .document: "javascript"  // mongosh
    case .keyValue: "redis"
    case .wideColumn: "cql"
    }
  }
}

/// Colors code by token with CodeHighlighting; shared by the Mac and iOS editors.
enum SyntaxColoring {
  /// The tokens to color: everything but plain text, which keeps the label color.
  static func tokens(_ text: String, language: String) -> [CodeToken] {
    CodeHighlighter.tokens(in: text, language: language).filter { $0.kind != .plainText }
  }

  /// The color of `kind` in Xcode's default theme for the given appearance.
  static func hex(_ kind: SyntaxKind, isDark: Bool) -> UInt32 {
    EditorTheme.systemAware(isDark: isDark).syntax.color(for: kind)
  }

  /// The word before the cursor, for completion.
  static func partialWord(in text: String, at location: Int) -> NSRange {
    let ns = text as NSString
    var start = location
    while start > 0 {
      let c = ns.character(at: start - 1)
      guard let scalar = Unicode.Scalar(c), CharacterSet.alphanumerics.contains(scalar) || c == 95 || c == 36 else { break }
      start -= 1
    }
    return NSRange(location: start, length: location - start)
  }
}

/// Read-only code, colored like the editors: the statements a review will run.
struct HighlightedCode: View {
  let text: String
  let language: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Text(attributed)
  }

  private var attributed: AttributedString {
    var result = AttributedString(text)
    for token in SyntaxColoring.tokens(text, language: language) {
      guard let range = Range(token.range, in: text),
        let lower = AttributedString.Index(range.lowerBound, within: result),
        let upper = AttributedString.Index(range.upperBound, within: result)
      else { continue }
      let hex = SyntaxColoring.hex(token.kind, isDark: colorScheme == .dark)
      result[lower..<upper].foregroundColor = Color(
        red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    return result
  }
}

#if os(macOS)
  import AppKit

  extension SyntaxKind {
    /// Follows the appearance: Xcode's light or dark theme color.
    var color: NSColor {
      NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hex = SyntaxColoring.hex(self, isDark: isDark)
        return NSColor(
          srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      }
    }
  }

  /// A plain-text code editor with highlighting, line numbers and completion.
  struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: String
    var completions: [Completion]
    var isEditable = true
    var onRun: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSTextView.scrollableTextView()
      let textView = scroll.documentView as! NSTextView
      textView.delegate = context.coordinator
      textView.isRichText = false
      textView.allowsUndo = true
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      textView.isAutomaticTextReplacementEnabled = false
      textView.isAutomaticSpellingCorrectionEnabled = false
      textView.isContinuousSpellCheckingEnabled = false
      textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      textView.textContainerInset = NSSize(width: 6, height: 8)
      textView.backgroundColor = .clear
      textView.drawsBackground = false
      textView.isEditable = isEditable
      textView.string = text
      scroll.drawsBackground = false
      scroll.hasVerticalRuler = true
      scroll.rulersVisible = true
      let ruler = LineNumberRuler(textView: textView)
      scroll.verticalRulerView = ruler
      context.coordinator.textView = textView
      context.coordinator.highlight()
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      context.coordinator.parent = self
      guard let textView = scroll.documentView as? NSTextView else { return }
      textView.isEditable = isEditable
      if textView.string != text {
        textView.string = text
        context.coordinator.highlight()
      }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
      var parent: CodeEditor
      weak var textView: NSTextView?
      private var completing = false

      init(_ parent: CodeEditor) { self.parent = parent }

      func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        parent.text = textView.string
        highlight()
        (textView.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.needsDisplay = true
        // Offer completions after two letters of a word.
        guard !completing, !parent.completions.isEmpty else { return }
        let location = textView.selectedRange().location
        let partial = SyntaxColoring.partialWord(in: textView.string, at: location)
        if partial.length >= 2 {
          completing = true
          textView.complete(nil)
          completing = false
        }
      }

      func highlight() {
        guard let textView, let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), range: full)
        for token in SyntaxColoring.tokens(storage.string, language: parent.language) where NSMaxRange(token.range) <= storage.length {
          storage.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
        }
        storage.endEditing()
      }

      func textView(
        _ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
      ) -> [String] {
        let partial = (textView.string as NSString).substring(with: charRange).lowercased()
        index?.pointee = -1
        var seen = Set<String>()
        return parent.completions.map(\.text).filter { candidate in
          candidate.lowercased().hasPrefix(partial) && candidate.lowercased() != partial && seen.insert(candidate).inserted
        }.prefix(40).map { $0 }
      }

      func textView(_ textView: NSTextView, rangeForUserCompletion charRange: NSRange) -> NSRange {
        SyntaxColoring.partialWord(in: textView.string, at: textView.selectedRange().location)
      }

      func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), NSEvent.modifierFlags.contains(.command), let run = parent.onRun {
          run()
          return true
        }
        return false
      }
    }
  }

  /// Line numbers down the left edge.
  final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
      self.textView = textView
      super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
      ruleThickness = 34
      NotificationCenter.default.addObserver(
        self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification,
        object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
      guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
      let text = textView.string as NSString
      let visible = textView.visibleRect
      let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
      let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      var line = 1
      text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
        line += 1
      }
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        .foregroundColor: NSColor.tertiaryLabelColor,
      ]
      var index = characters.location
      repeat {
        let lineRange = text.lineRange(for: NSRange(location: min(index, max(0, text.length - 1)), length: 0))
        let glyphRange = layout.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0), actualCharacterRange: nil)
        var lineRect = layout.lineFragmentRect(forGlyphAt: min(glyphRange.location, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil)
        if text.length == 0 { lineRect = NSRect(x: 0, y: 0, width: 0, height: 17) }
        let y = lineRect.minY + textView.textContainerInset.height - visible.minY
        let label = "\(line)" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (lineRect.height - size.height) / 2), withAttributes: attributes)
        line += 1
        index = NSMaxRange(lineRange)
      } while index < NSMaxRange(characters) && index < text.length
    }
  }
#elseif os(iOS)
  import UIKit

  extension SyntaxKind {
    /// Follows the appearance: Xcode's light or dark theme color.
    var color: UIColor {
      UIColor { traits in
        let hex = SyntaxColoring.hex(self, isDark: traits.userInterfaceStyle == .dark)
        return UIColor(
          red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      }
    }
  }

  struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var language: String
    var completions: [Completion]
    var isEditable = true
    var onRun: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
      let view = UITextView()
      view.delegate = context.coordinator
      view.autocapitalizationType = .none
      view.autocorrectionType = .no
      view.smartQuotesType = .no
      view.smartDashesType = .no
      view.spellCheckingType = .no
      view.backgroundColor = .clear
      view.font = .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
      view.text = text
      view.isEditable = isEditable
      context.coordinator.highlight(view)
      return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
      context.coordinator.parent = self
      view.isEditable = isEditable
      if view.text != text {
        view.text = text
        context.coordinator.highlight(view)
      }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
      var parent: CodeEditor
      init(_ parent: CodeEditor) { self.parent = parent }

      func textViewDidChange(_ view: UITextView) {
        parent.text = view.text
        highlight(view)
      }

      func highlight(_ view: UITextView) {
        let selected = view.selectedRange
        let storage = view.textStorage
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(
          [.font: UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular), .foregroundColor: UIColor.label],
          range: full)
        for token in SyntaxColoring.tokens(storage.string, language: parent.language) where NSMaxRange(token.range) <= storage.length {
          storage.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
        }
        storage.endEditing()
        view.selectedRange = selected
      }
    }
  }
#else
  /// A plain monospaced editor where neither AppKit nor UIKit is around (Windows, Linux); ⌘↩ runs.
  struct CodeEditor: View {
    @Binding var text: String
    var language: String
    var completions: [Completion]
    var isEditable = true
    var onRun: (() -> Void)?

    var body: some View {
      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .disabled(!isEditable)
        .onKeyPress(.return, phases: .down) { press in
          guard press.modifiers.contains(.command), let onRun else { return .ignored }
          onRun()
          return .handled
        }
    }
  }
#endif
