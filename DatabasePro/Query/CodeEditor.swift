import DatabaseProKit
import SwiftUI

enum CodeLanguage {
  case sql, mongo, redis
}

extension EngineKind {
  var highlighting: CodeLanguage {
    switch self {
    case .mongodb: .mongo
    case .redis: .redis
    default: .sql
    }
  }
}

/// Colors code by token; shared by the Mac and iOS editors.
enum SyntaxHighlighter {
  struct Span {
    var range: NSRange
    var kind: Kind
  }

  enum Kind { case keyword, string, number, comment, operatorName, function }

  static let sqlKeywords: Set<String> = [
    "select", "from", "where", "and", "or", "not", "null", "is", "in", "like", "ilike", "between", "order", "by",
    "group", "having", "limit", "offset", "join", "left", "right", "inner", "outer", "full", "cross", "on", "as",
    "distinct", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "drop", "with",
    "case", "when", "then", "else", "end", "union", "all", "exists", "desc", "asc", "primary", "key", "foreign",
    "references", "index", "view", "begin", "commit", "rollback", "transaction", "returning", "true", "false",
    "date", "interval", "top", "fetch", "next", "rows", "only", "use", "allow", "filtering", "keyspace", "batch",
    "apply", "using", "ttl", "if", "explain", "analyze", "default", "unique", "check", "constraint", "cascade",
    "schema", "database", "grant", "revoke", "count", "sum", "avg", "min", "max", "cast", "coalesce", "over",
    "partition", "window", "lateral", "recursive", "materialized", "temporary", "replace", "truncate", "go",
  ]

  static let regexes: [(NSRegularExpression, Kind)] = {
    func r(_ p: String, _ k: Kind) -> (NSRegularExpression, Kind) {
      (try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]), k)
    }
    return [
      r(#"\b\d+(\.\d+)?([eE][-+]?\d+)?\b"#, .number),
      r(#"\$[A-Za-z_][A-Za-z0-9_]*"#, .operatorName),
      r(#"\b[A-Za-z_][A-Za-z0-9_]*(?=\()"#, .function),
      r(#"'(?:[^'\\]|\\.|'')*'|"(?:[^"\\]|\\.)*""#, .string),
      r(#"--[^\n]*|//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/"#, .comment),
    ]
  }()

  static let wordRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z_]+\b"#)

  static func spans(_ text: String, language: CodeLanguage) -> [Span] {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    var spans: [Span] = []
    switch language {
    case .sql:
      for match in wordRegex.matches(in: text, range: full) where sqlKeywords.contains(ns.substring(with: match.range).lowercased()) {
        spans.append(Span(range: match.range, kind: .keyword))
      }
    case .redis:
      // The first word of each line is the command.
      ns.enumerateSubstrings(in: full, options: .byLines) { line, range, _, _ in
        guard let line else { return }
        let trimmed = line.drop { $0 == " " }
        let leading = line.count - trimmed.count
        let word = trimmed.prefix { $0 != " " }
        if !word.isEmpty {
          spans.append(Span(range: NSRange(location: range.location + leading, length: (String(word) as NSString).length), kind: .keyword))
        }
      }
    case .mongo:
      for match in wordRegex.matches(in: text, range: full) {
        let word = ns.substring(with: match.range)
        if ["db", "true", "false", "null", "show", "use", "new"].contains(word) {
          spans.append(Span(range: match.range, kind: .keyword))
        }
      }
    }
    for (regex, kind) in regexes {
      if language == .sql && kind == .operatorName { continue }
      if language != .redis && kind == .comment, regex.pattern.contains("#") {
        // "#" starts a comment only in Redis scripts; strip it for others.
        let other = try! NSRegularExpression(pattern: #"--[^\n]*|//[^\n]*|/\*[\s\S]*?\*/"#)
        for match in other.matches(in: text, range: full) { spans.append(Span(range: match.range, kind: kind)) }
        continue
      }
      for match in regex.matches(in: text, range: full) { spans.append(Span(range: match.range, kind: kind)) }
    }
    return spans
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

#if os(macOS)
  import AppKit

  extension SyntaxHighlighter.Kind {
    var color: NSColor {
      switch self {
      case .keyword: .systemPink
      case .string: .systemRed
      case .number: .systemBlue
      case .comment: .secondaryLabelColor
      case .operatorName: .systemPurple
      case .function: .systemTeal
      }
    }
  }

  /// A plain-text code editor with highlighting, line numbers and completion.
  struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
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
        let partial = SyntaxHighlighter.partialWord(in: textView.string, at: location)
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
        for span in SyntaxHighlighter.spans(storage.string, language: parent.language) where NSMaxRange(span.range) <= storage.length {
          storage.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
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
        SyntaxHighlighter.partialWord(in: textView.string, at: textView.selectedRange().location)
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
#else
  import UIKit

  extension SyntaxHighlighter.Kind {
    var color: UIColor {
      switch self {
      case .keyword: .systemPink
      case .string: .systemRed
      case .number: .systemBlue
      case .comment: .secondaryLabel
      case .operatorName: .systemPurple
      case .function: .systemTeal
      }
    }
  }

  struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
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
        for span in SyntaxHighlighter.spans(storage.string, language: parent.language) where NSMaxRange(span.range) <= storage.length {
          storage.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
        }
        storage.endEditing()
        view.selectedRange = selected
      }
    }
  }
#endif
