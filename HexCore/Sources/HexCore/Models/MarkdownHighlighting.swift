//
//  MarkdownHighlighting.swift
//  HexCore
//
//  Live markdown highlighting shared by the macOS notes editor
//  (NSTextView) and the iOS note edit sheet (UITextView). Applies visual
//  formatting to markdown syntax in an attributed string without changing
//  the underlying text: markers (`**`, `_`, `~~`, `` ` ``) fade to
//  near-invisible while the content between them gets the typographic
//  treatment. Headings, bullets, numbered lists, and blockquotes are
//  styled at the line level; inline photo tokens are dimmed.
//
//  Platform wrappers own the text view specifics (undo suspension,
//  selection preservation) — this file is pure attributed-string work
//  over platform-typealiased fonts/colors.
//

import Foundation

#if canImport(AppKit)
import AppKit
public typealias MDFont = NSFont
public typealias MDColor = NSColor
#elseif canImport(UIKit)
import UIKit
public typealias MDFont = UIFont
public typealias MDColor = UIColor
#endif

#if canImport(AppKit) || canImport(UIKit)

@MainActor
public enum MarkdownHighlighter {
  /// Slightly larger than the system default — notes are prose, not UI
  /// chrome, and the extra 2pt plus line spacing reads much better in a
  /// full-width editor.
  public static let baseSize: CGFloat = {
    #if canImport(AppKit)
    NSFont.systemFontSize + 2
    #else
    UIFont.systemFontSize + 2
    #endif
  }()

  public static let baseFont = MDFont.systemFont(ofSize: baseSize)

  public static let paragraphStyle: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 3
    style.paragraphSpacing = 4
    return style
  }()

  // MARK: - Platform color/font shims

  private static var labelColor: MDColor {
    #if canImport(AppKit)
    .labelColor
    #else
    .label
    #endif
  }

  private static var secondaryLabelColor: MDColor {
    #if canImport(AppKit)
    .secondaryLabelColor
    #else
    .secondaryLabel
    #endif
  }

  private static var tertiaryLabelColor: MDColor {
    #if canImport(AppKit)
    .tertiaryLabelColor
    #else
    .tertiaryLabel
    #endif
  }

  private static var quaternaryLabelColor: MDColor {
    #if canImport(AppKit)
    .quaternaryLabelColor
    #else
    .quaternaryLabel
    #endif
  }

  private static func boldFont(ofSize size: CGFloat) -> MDFont {
    #if canImport(AppKit)
    .boldSystemFont(ofSize: size)
    #else
    .boldSystemFont(ofSize: size)
    #endif
  }

  /// Italic via font-descriptor symbolic traits — works on both
  /// platforms (NSFontManager is AppKit-only).
  private static func italicFont(ofSize size: CGFloat) -> MDFont {
    #if canImport(AppKit)
    let descriptor = MDFont.systemFont(ofSize: size).fontDescriptor
      .withSymbolicTraits(.italic)
    return MDFont(descriptor: descriptor, size: size)
      ?? MDFont.systemFont(ofSize: size)
    #else
    let descriptor = MDFont.systemFont(ofSize: size).fontDescriptor
      .withSymbolicTraits(.traitItalic)
    guard let descriptor else { return MDFont.italicSystemFont(ofSize: size) }
    return MDFont(descriptor: descriptor, size: size)
    #endif
  }

  // MARK: - Highlight

  /// Re-applies the full markdown styling pass over `storage`. Purely
  /// cosmetic — the string content is untouched. Callers should suspend
  /// undo registration around this (highlighting is not an edit).
  public static func highlight(_ storage: NSMutableAttributedString) {
    let string = storage.string
    let fullRange = NSRange(location: 0, length: (string as NSString).length)
    guard fullRange.length > 0 else { return }

    storage.beginEditing()

    // 1. Reset everything to the base style.
    let baseAttrs: [NSAttributedString.Key: Any] = [
      .font: baseFont,
      .foregroundColor: labelColor,
      .strikethroughStyle: 0,
      .paragraphStyle: paragraphStyle,
    ]
    storage.setAttributes(baseAttrs, range: fullRange)

    let markerAttrs: [NSAttributedString.Key: Any] = [
      .foregroundColor: tertiaryLabelColor.withAlphaComponent(0.35),
      .font: MDFont.systemFont(ofSize: baseSize * 0.85),
    ]

    // 2. Bold: **text**
    applyInline(
      pattern: #"\*\*(.+?)\*\*"#,
      storage: storage, string: string,
      contentAttrs: [.font: boldFont(ofSize: baseSize)],
      markerAttrs: markerAttrs, markerLen: 2
    )

    // 3. Italic: _text_ (word-boundary aware to avoid matching snake_case)
    applyInline(
      pattern: #"(?<![a-zA-Z0-9])_(.+?)_(?![a-zA-Z0-9])"#,
      storage: storage, string: string,
      contentAttrs: [.font: italicFont(ofSize: baseSize)],
      markerAttrs: markerAttrs, markerLen: 1
    )

    // 4. Strikethrough: ~~text~~
    applyInline(
      pattern: #"~~(.+?)~~"#,
      storage: storage, string: string,
      contentAttrs: [
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        .strikethroughColor: secondaryLabelColor,
      ],
      markerAttrs: markerAttrs, markerLen: 2
    )

    // 5. Inline code: `text`
    applyInline(
      pattern: #"`([^`]+)`"#,
      storage: storage, string: string,
      contentAttrs: [
        .font: MDFont.monospacedSystemFont(ofSize: baseSize * 0.93, weight: .regular),
        .backgroundColor: quaternaryLabelColor.withAlphaComponent(0.3),
      ],
      markerAttrs: markerAttrs, markerLen: 1
    )

    // 6. Headings: # at line start
    applyLinePattern(
      pattern: #"^(#{1,3})\s+(.+)$"#,
      string: string
    ) { match in
      let hashRange = match.range(at: 1)
      let textRange = match.range(at: 2)
      let level = hashRange.length // 1, 2, or 3
      let headingSize = baseSize + CGFloat(4 - level) * 3 // #=+9, ##=+6, ###=+3
      storage.addAttributes(markerAttrs, range: hashRange)
      storage.addAttributes([
        .font: boldFont(ofSize: headingSize),
      ], range: textRange)
    }

    // 7. Bullets: - at line start
    applyLinePattern(
      pattern: #"^(-)\s+(.+)$"#,
      string: string
    ) { match in
      storage.addAttributes([
        .foregroundColor: tertiaryLabelColor,
      ], range: match.range(at: 1))
    }

    // 7b. Checkboxes: "- [ ]" / "- [x]" — marker de-emphasized; checked
    // items render struck-through and dimmed so done-ness reads at a
    // glance. (Tap-to-toggle lives in the note canvas, not the editor.)
    applyLinePattern(
      pattern: #"^(- \[( |x|X)\])\s+(.+)$"#,
      string: string
    ) { match in
      storage.addAttributes(markerAttrs, range: match.range(at: 1))
      let checked = match.range(at: 2).length == 1
        && (string as NSString).substring(with: match.range(at: 2)).lowercased() == "x"
      if checked {
        storage.addAttributes([
          .strikethroughStyle: NSUnderlineStyle.single.rawValue,
          .strikethroughColor: secondaryLabelColor,
          .foregroundColor: secondaryLabelColor,
        ], range: match.range(at: 3))
      }
    }

    // 8. Numbered lists: "1. " at line start — marker de-emphasized
    applyLinePattern(
      pattern: #"^(\d+\.)\s+(.+)$"#,
      string: string
    ) { match in
      storage.addAttributes([
        .foregroundColor: tertiaryLabelColor,
      ], range: match.range(at: 1))
    }

    // 9. Blockquotes: "> " at line start — faded marker, italic content
    applyLinePattern(
      pattern: #"^(>)\s?(.*)$"#,
      string: string
    ) { match in
      storage.addAttributes(markerAttrs, range: match.range(at: 1))
      let contentRange = match.range(at: 2)
      if contentRange.length > 0 {
        storage.addAttributes([
          .font: italicFont(ofSize: baseSize),
          .foregroundColor: secondaryLabelColor,
        ], range: contentRange)
      }
    }

    // 10. Inline photo tokens: ![photo](uuid) — dimmed + smaller so the
    // plumbing doesn't shout in the middle of prose (iOS notes embed
    // photos this way; the token must be preserved verbatim).
    applyLinePattern(
      pattern: #"!\[photo\]\([0-9a-fA-F-]+\)"#,
      string: string
    ) { match in
      storage.addAttributes([
        .foregroundColor: tertiaryLabelColor.withAlphaComponent(0.5),
        .font: MDFont.monospacedSystemFont(ofSize: baseSize * 0.8, weight: .regular),
      ], range: match.range)
    }

    storage.endEditing()
  }

  /// Highlights an inline markdown pattern (e.g. `**bold**`). The
  /// markers get faded styling; the content between them gets the
  /// supplied attributes.
  private static func applyInline(
    pattern: String,
    storage: NSMutableAttributedString,
    string: String,
    contentAttrs: [NSAttributedString.Key: Any],
    markerAttrs: [NSAttributedString.Key: Any],
    markerLen: Int
  ) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    let nsString = string as NSString
    let fullRange = NSRange(location: 0, length: nsString.length)

    regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
      guard let matchRange = match?.range, matchRange.length > markerLen * 2 else { return }

      // Leading marker
      let leading = NSRange(location: matchRange.location, length: markerLen)
      storage.addAttributes(markerAttrs, range: leading)

      // Content
      let contentStart = matchRange.location + markerLen
      let contentLength = matchRange.length - markerLen * 2
      let content = NSRange(location: contentStart, length: contentLength)
      storage.addAttributes(contentAttrs, range: content)

      // Trailing marker
      let trailing = NSRange(location: matchRange.location + matchRange.length - markerLen, length: markerLen)
      storage.addAttributes(markerAttrs, range: trailing)
    }
  }

  /// Runs a line-anchored regex and calls the handler for each match.
  private static func applyLinePattern(
    pattern: String,
    string: String,
    handler: (NSTextCheckingResult) -> Void
  ) {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return }
    let fullRange = NSRange(location: 0, length: (string as NSString).length)
    regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
      guard let match else { return }
      handler(match)
    }
  }
}

#endif

// MARK: - Checkbox toggling

/// Pure string logic for flipping a `- [ ]` / `- [x]` marker on one line
/// of a note body. Used by the tappable checkboxes in `NoteTextView`.
public enum MarkdownCheckbox {
  /// Returns `text` with the checkbox on `lineIndex` (0-based, over
  /// newline-separated lines) toggled — or nil when that line isn't a
  /// checkbox item (caller leaves the text untouched).
  public static func toggleLine(_ lineIndex: Int, in text: String) -> String? {
    var lines = text.components(separatedBy: "\n")
    guard lineIndex >= 0, lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    let trimmed = String(line.dropFirst(indent.count))

    if trimmed.hasPrefix("- [ ] ") {
      lines[lineIndex] = indent + "- [x] " + trimmed.dropFirst(6)
    } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
      lines[lineIndex] = indent + "- [ ] " + trimmed.dropFirst(6)
    } else {
      return nil
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - List auto-continuation

/// Pure string logic for Enter-key handling in markdown editors:
/// "- ", "1. ", and "> " carry to the next line (numbered lists
/// increment); pressing Enter on an EMPTY item deletes the marker and
/// exits the list. Shared by the macOS NSTextView delegate and the iOS
/// UITextView delegate.
public enum MarkdownListContinuation {
  public enum Result: Equatable {
    /// Empty list item — remove `clearRange` (the marker) instead of
    /// inserting a newline.
    case exitList(clearRange: NSRange)
    /// Inside a list item — insert `text` (newline + next marker) at the
    /// caret instead of a plain newline.
    case continueList(insert: String)
    /// Not in a list — let the editor insert a plain newline.
    case none
  }

  /// Decide what Enter should do at `caretLocation` (a zero-length
  /// selection) in `text`.
  public static func handleNewline(text: String, caretLocation: Int) -> Result {
    let ns = text as NSString
    guard caretLocation <= ns.length else { return .none }

    let lineRange = ns.lineRange(for: NSRange(location: caretLocation, length: 0))
    let headRange = NSRange(location: lineRange.location, length: caretLocation - lineRange.location)
    let head = ns.substring(with: headRange)
    let indent = String(head.prefix(while: { $0 == " " || $0 == "\t" }))
    let trimmed = head.trimmingCharacters(in: .whitespaces)

    // Empty item + Enter = exit the list (clear the marker, stay put).
    let emptyMarkers = ["-", ">", "- [ ]", "- [x]"]
    if emptyMarkers.contains(trimmed) || trimmed.range(of: #"^\d+\.$"#, options: .regularExpression) != nil {
      return .exitList(clearRange: headRange)
    }

    if trimmed.range(of: #"^- \[( |x|X)\]\s"#, options: .regularExpression) != nil {
      // Checkbox items continue as fresh unchecked boxes.
      return .continueList(insert: "\n\(indent)- [ ] ")
    }
    if trimmed.hasPrefix("- ") {
      return .continueList(insert: "\n\(indent)- ")
    }
    if trimmed.hasPrefix("> ") {
      return .continueList(insert: "\n\(indent)> ")
    }
    if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
      let number = Int(trimmed.prefix(while: \.isNumber)) ?? 0
      return .continueList(insert: "\n\(indent)\(number + 1). ")
    }
    return .none
  }
}
