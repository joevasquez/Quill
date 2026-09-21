//
//  MarkdownTextEditorIOS.swift
//  Quill (iOS)
//
//  UITextView wrapper with live markdown highlighting — the iOS
//  counterpart of macOS's `MarkdownTextEditor` in NotesView. Storage
//  stays plain text (markdown); the visual formatting is applied via
//  `textStorage` attributes after every edit using the shared HexCore
//  `MarkdownHighlighter`, so both platforms style notes identically.
//  A keyboard accessory toolbar provides Bold/Italic/Strikethrough/
//  Code/Heading/Bullet/Numbered/Quote, and Enter auto-continues lists
//  via `MarkdownListContinuation`.
//

import HexCore
import SwiftUI
import UIKit

struct MarkdownTextEditorIOS: UIViewRepresentable {
  @Binding var text: String
  var focusOnAppear = false

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeUIView(context: Context) -> UITextView {
    let tv = UITextView()
    tv.delegate = context.coordinator
    context.coordinator.textView = tv
    tv.font = MarkdownHighlighter.baseFont
    tv.textColor = .label
    tv.backgroundColor = .clear
    tv.smartQuotesType = .no
    tv.smartDashesType = .no
    tv.autocorrectionType = .default
    tv.alwaysBounceVertical = true
    tv.keyboardDismissMode = .interactive
    tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    tv.inputAccessoryView = context.coordinator.makeToolbar()
    tv.text = text
    Coordinator.applyHighlight(tv)
    if focusOnAppear {
      DispatchQueue.main.async { tv.becomeFirstResponder() }
    }
    return tv
  }

  func updateUIView(_ tv: UITextView, context: Context) {
    context.coordinator.parent = self
    // Only update if the source of truth changed externally — reassigning
    // attributedText on every SwiftUI pass would reset the caret.
    if tv.text != text {
      let savedSelection = tv.selectedRange
      tv.text = text
      let clamped = NSRange(location: min(savedSelection.location, (text as NSString).length), length: 0)
      tv.selectedRange = clamped
      Coordinator.applyHighlight(tv)
    }
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: MarkdownTextEditorIOS
    weak var textView: UITextView?

    init(_ parent: MarkdownTextEditorIOS) {
      self.parent = parent
    }

    /// Runs the shared highlighter over the view's storage with undo
    /// registration suspended (highlighting is cosmetic, not an edit)
    /// and the caret preserved.
    static func applyHighlight(_ tv: UITextView) {
      let savedSelection = tv.selectedRange
      tv.undoManager?.disableUndoRegistration()
      MarkdownHighlighter.highlight(tv.textStorage)
      tv.undoManager?.enableUndoRegistration()
      tv.selectedRange = savedSelection
    }

    func textViewDidChange(_ textView: UITextView) {
      parent.text = textView.text
      Self.applyHighlight(textView)
    }

    /// Enter auto-continues markdown lists ("- ", "1. ", "> ") and exits
    /// the list when the item is empty — shared logic with macOS.
    func textView(
      _ textView: UITextView,
      shouldChangeTextIn range: NSRange,
      replacementText replacement: String
    ) -> Bool {
      guard replacement == "\n", range.length == 0 else { return true }
      switch MarkdownListContinuation.handleNewline(text: textView.text, caretLocation: range.location) {
      case .exitList(let clearRange):
        replaceText(in: textView, range: clearRange, with: "")
        return false
      case .continueList(let insert):
        replaceText(in: textView, range: range, with: insert)
        return false
      case .none:
        return true
      }
    }

    private func replaceText(in textView: UITextView, range: NSRange, with replacement: String) {
      guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
            let end = textView.position(from: start, offset: range.length),
            let textRange = textView.textRange(from: start, to: end)
      else { return }
      // Goes through replace(_:withText:) so UIKit registers undo and
      // fires textViewDidChange (which re-highlights + syncs the binding).
      textView.replace(textRange, withText: replacement)
    }

    // MARK: - Formatting toolbar

    func makeToolbar() -> UIView {
      // A scrolling accessory avoids compressing UIKit bar-button wrappers
      // to zero width on narrow keyboards. Done remains outside the scroller.
      let accessory = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
      accessory.autoresizingMask = [.flexibleWidth]
      accessory.backgroundColor = .secondarySystemBackground
      let scroll = UIScrollView()
      scroll.showsHorizontalScrollIndicator = false
      scroll.translatesAutoresizingMaskIntoConstraints = false
      let row = UIStackView(arrangedSubviews: [
        button("bold", "Bold") { [weak self] in self?.wrapSelection(prefix: "**", suffix: "**") },
        button("italic", "Italic") { [weak self] in self?.wrapSelection(prefix: "_", suffix: "_") },
        button("strikethrough", "Strikethrough") { [weak self] in self?.wrapSelection(prefix: "~~", suffix: "~~") },
        button("chevron.left.forwardslash.chevron.right", "Code") { [weak self] in self?.wrapSelection(prefix: "`", suffix: "`") },
        button("number", "Heading") { [weak self] in self?.insertAtLineStart("# ") },
        button("list.bullet", "Bulleted list") { [weak self] in self?.insertAtLineStart("- ") },
        button("checklist", "Checklist") { [weak self] in self?.insertAtLineStart("- [ ] ") },
        button("list.number", "Numbered list") { [weak self] in self?.insertAtLineStart("1. ") },
        button("text.quote", "Quote") { [weak self] in self?.insertAtLineStart("> ") },
      ])
      row.translatesAutoresizingMaskIntoConstraints = false
      row.axis = .horizontal
      let done = UIButton(type: .system)
      done.setTitle("Done", for: .normal)
      done.translatesAutoresizingMaskIntoConstraints = false
      done.addAction(UIAction { [weak self] _ in self?.textView?.resignFirstResponder() }, for: .touchUpInside)
      accessory.addSubview(scroll)
      accessory.addSubview(done)
      scroll.addSubview(row)
      NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
        scroll.topAnchor.constraint(equalTo: accessory.topAnchor),
        scroll.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
        scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor),
        done.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
        done.topAnchor.constraint(equalTo: accessory.topAnchor),
        done.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
        done.widthAnchor.constraint(equalToConstant: 64),
        row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
        row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
        row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
      ])
      return accessory
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> UIButton {
      let button = UIButton(type: .system)
      button.setImage(UIImage(systemName: symbol), for: .normal)
      button.accessibilityLabel = label
      button.widthAnchor.constraint(equalToConstant: 44).isActive = true
      button.addAction(UIAction { _ in action() }, for: .touchUpInside)
      return button
    }

    /// Wraps the current selection in markdown markers; with no selection,
    /// inserts an empty pair and places the caret between the markers.
    private func wrapSelection(prefix: String, suffix: String) {
      guard let tv = textView else { return }
      let range = tv.selectedRange
      let ns = tv.text as NSString
      if range.length > 0 {
        let selected = ns.substring(with: range)
        replaceText(in: tv, range: range, with: prefix + selected + suffix)
        tv.selectedRange = NSRange(location: range.location + (prefix + selected + suffix).utf16.count, length: 0)
      } else {
        replaceText(in: tv, range: range, with: prefix + suffix)
        tv.selectedRange = NSRange(location: range.location + (prefix as NSString).length, length: 0)
      }
    }

    private func insertAtLineStart(_ marker: String) {
      guard let tv = textView else { return }
      let range = tv.selectedRange
      let formatted = MarkdownLineFormatting.apply(marker: marker, to: tv.text, selection: range)
      guard formatted.text != tv.text else { return }
      let current = tv.text as NSString
      let revised = formatted.text as NSString
      let commonPrefix = (0..<min(current.length, revised.length)).prefix {
        current.character(at: $0) == revised.character(at: $0)
      }.count
      replaceText(
        in: tv,
        range: NSRange(location: commonPrefix, length: current.length - commonPrefix),
        with: revised.substring(from: commonPrefix)
      )
      tv.selectedRange = formatted.selection
    }
  }
}
