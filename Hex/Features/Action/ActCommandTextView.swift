//
//  ActCommandTextView.swift
//  Quill (macOS)
//
//  The text surface behind `ActCommandField`. A plain SwiftUI TextField
//  can't do the two things the command bar needs, so this wraps NSTextView:
//
//  1. **Inline tokens.** A completed `@Dex` renders as a small tinted pill
//     inside the sentence you're typing, not as a separate row of chips
//     below the field. The underlying string stays literal text — only its
//     presentation changes — so extraction, undo, and editing all behave
//     like normal typing. (A real NSTextAttachment token would divorce the
//     display from the string and take a mapping table to keep them honest.)
//  2. **A real caret position**, so tagging works mid-sentence rather than
//     only at the end.
//
//  Rounded pill backgrounds need a custom NSLayoutManager — AppKit's
//  `.backgroundColor` attribute only paints a tight rectangle.
//

import AppKit
import HexCore
import SwiftUI

/// Marks a range as a destination token; the value is the fill colour.
private extension NSAttributedString.Key {
  static let actToken = NSAttributedString.Key("quill.actToken")
}

struct ActCommandTextView: NSViewRepresentable {
  @Binding var text: String
  /// Caret offset (UTF-16), published so the mention menu can follow it.
  @Binding var caret: Int
  /// Content height, clamped by the view to `maxLines`.
  @Binding var height: CGFloat

  var destinations: [QuillActDestination]
  var font: NSFont = .systemFont(ofSize: 13)
  var maxLines: Int = 4
  /// True while the mention menu is showing — the arrow keys, tab and
  /// return belong to it, not to the text.
  var isMenuOpen: Bool
  var onMenuCommand: (MenuCommand) -> Void
  var onSubmit: () -> Void

  enum MenuCommand { case up, down, accept, dismiss }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    // Built by hand rather than `NSTextView.scrollableTextView()` because a
    // custom layout manager means TextKit 1.
    let storage = NSTextStorage()
    let layout = TokenLayoutManager()
    let container = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    container.widthTracksTextView = true
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)

    let textView = ActNSTextView(frame: .zero, textContainer: container)
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    textView.usesFontPanel = false
    textView.font = font
    textView.textColor = .labelColor
    textView.drawsBackground = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 0, height: 1)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false

    let scrollView = NSScrollView()
    scrollView.documentView = textView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    DispatchQueue.main.async {
      textView.window?.makeFirstResponder(textView)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scrollView.documentView as? NSTextView else { return }

    // AppKit fires `textViewDidChangeSelection` *synchronously* from both
    // assignments below, and this runs inside SwiftUI's update pass — so
    // without this flag the delegate writes `caret` back mid-update, which
    // is exactly the "Modifying state during view update" warning. Accepting
    // a mention is the trigger: it's the one path that sets `text` and
    // `caret` programmatically.
    context.coordinator.isApplyingUpdate = true
    defer { context.coordinator.isApplyingUpdate = false }

    if textView.string != text {
      textView.string = text
      // Honour the caret the *binding* asks for rather than preserving the
      // old selection: after a completion the caller has already worked out
      // where the caret belongs (past the inserted token), and clamping the
      // pre-edit location put it mid-token when tagging mid-sentence.
      let location = min(max(caret, 0), (text as NSString).length)
      textView.setSelectedRange(NSRange(location: location, length: 0))
    }
    applyTokens(to: textView)
    context.coordinator.publishMetrics(textView)
  }

  /// Re-marks every completed mention. Cosmetic, so undo registration is
  /// suspended — otherwise ⌘Z would step through highlight passes.
  func applyTokens(to textView: NSTextView) {
    guard let storage = textView.textStorage else { return }
    let undoManager = textView.undoManager
    undoManager?.disableUndoRegistration()
    defer { undoManager?.enableUndoRegistration() }

    let full = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.removeAttribute(.actToken, range: full)
    storage.addAttribute(.font, value: font, range: full)
    storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)

    let tokenFont = NSFont.systemFont(ofSize: font.pointSize - 1.5, weight: .semibold)
    for token in ConnectionMentions.tokenRanges(in: textView.string, destinations: destinations) {
      let range = NSRange(token.range, in: textView.string)
      let tint = NSColor(token.destination.palette.color())
      storage.addAttributes(
        [
          .font: tokenFont,
          .foregroundColor: tint,
          .actToken: tint.withAlphaComponent(0.16),
        ],
        range: range
      )
    }
    storage.endEditing()
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ActCommandTextView
    /// True while `updateNSView` is pushing SwiftUI's values into the text
    /// view. The delegate callbacks below must not write bindings back
    /// during that window — see the note in `updateNSView`.
    var isApplyingUpdate = false

    init(_ parent: ActCommandTextView) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard !isApplyingUpdate else { return }
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
      parent.applyTokens(to: textView)
      publishMetrics(textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard !isApplyingUpdate else { return }
      guard let textView = notification.object as? NSTextView else { return }
      let location = textView.selectedRange().location
      if parent.caret != location { parent.caret = location }
    }

    /// Height for the SwiftUI frame: content, clamped to `maxLines`.
    func publishMetrics(_ textView: NSTextView) {
      guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
      layout.ensureLayout(for: container)
      let content = layout.usedRect(for: container).height
      let line = textView.font?.boundingRectForFont.height ?? 16
      let clamped = min(max(content, line), line * CGFloat(parent.maxLines)) + 2
      if abs(parent.height - clamped) > 0.5 {
        DispatchQueue.main.async { self.parent.height = clamped }
      }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      // Option+Return always means "newline", menu or not.
      if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
        return false
      }

      guard parent.isMenuOpen else {
        if selector == #selector(NSResponder.insertNewline(_:)) {
          parent.onSubmit()
          return true
        }
        return false
      }

      switch selector {
      case #selector(NSResponder.moveUp(_:)):
        parent.onMenuCommand(.up)
        return true
      case #selector(NSResponder.moveDown(_:)):
        parent.onMenuCommand(.down)
        return true
      case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
        parent.onMenuCommand(.accept)
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onMenuCommand(.dismiss)
        return true
      default:
        return false
      }
    }
  }
}

/// Keeps the caret visible without the scroll view stealing focus rings.
private final class ActNSTextView: NSTextView {
  override var isOpaque: Bool { false }
}

/// Draws the rounded pill behind `.actToken` ranges. AppKit's
/// `.backgroundColor` attribute would paint a hard-edged rectangle.
private final class TokenLayoutManager: NSLayoutManager {
  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    if let storage = textStorage, let container = textContainers.first {
      let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
      storage.enumerateAttribute(.actToken, in: characterRange) { value, range, _ in
        guard let color = value as? NSColor else { return }
        let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        self.enumerateEnclosingRects(
          forGlyphRange: glyphRange,
          withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
          in: container
        ) { rect, _ in
          let pill = rect
            .offsetBy(dx: origin.x, dy: origin.y)
            .insetBy(dx: -2.5, dy: 0.5)
          color.setFill()
          NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        }
      }
    }
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
  }
}
