//
//  ActCommandField.swift
//  Quill (macOS)
//
//  The typed-command input, shared by Home and the menu bar's
//  "Type a Command…" panel.
//
//  Two things it does beyond a plain TextField:
//
//  1. Grows with the text (1→4 lines) instead of scrolling a single line
//     out of sight — commands are often a sentence and a half.
//  2. `@` opens a destination menu, and the accepted tag renders as a small
//     pill *inline in the sentence* (see `ActCommandTextView`). A pin is a
//     hard targeting signal, not a hint: pinned destinations are stripped
//     from the text and handed to the planner as a directive, and
//     everything outside the pin is withheld from the prompt entirely.
//
//  Grammar and matching live in `HexCore/Logic/ConnectionMentions.swift`
//  so iOS's typed sheet shares the open/close rules rather than
//  reimplementing them.
//

import HexCore
import SwiftUI

struct ActCommandField: View {
  /// Destinations offered by the `@` menu — connected, minus anything the
  /// user muted on the chip row.
  var destinations: [QuillActDestination]
  var icon: String = "bolt.fill"
  var accent: Color = QuillDesign.actionAccent
  var placeholder: String
  /// Shown under the field when it's empty; nil hides the row entirely.
  var hint: String?
  /// Clean text (mention tokens removed) plus the destinations they pinned.
  var onSubmit: (String, [QuillActDestination]) -> Void

  @State private var text = ""
  @State private var caret = 0
  @State private var fieldHeight: CGFloat = 17
  @State private var highlighted = 0
  @State private var menuDismissed = false

  private var trimmed: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var menu: ConnectionMentions.Menu? {
    guard !menuDismissed else { return nil }
    return ConnectionMentions.menu(in: text, utf16Caret: caret, destinations: destinations)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      field
        // The menu is an overlay — no layout footprint — so it has to be
        // offset by the measured field height and drawn above its siblings.
        .overlay(alignment: .topLeading) {
          if let menu {
            mentionMenu(menu)
              // Card height (text + 10pt padding top and bottom) + a 6pt gap.
              .offset(y: fieldHeight + 26)
          }
        }
        .zIndex(1)

      if let hint, trimmed.isEmpty, !destinations.isEmpty {
        Text(hint)
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .padding(.leading, 2)
      }
    }
    // Same reason, one level up: the chip row and the cards below the
    // capture row are later siblings in Home's stack.
    .zIndex(1)
    .onChange(of: text) { _, _ in
      highlighted = 0
      menuDismissed = false
    }
  }

  // MARK: - Field

  private var field: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: icon)
        .foregroundStyle(accent)
        .padding(.top, 1)

      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text(placeholder)
            .foregroundStyle(.tertiary)
            .allowsHitTesting(false)
        }
        ActCommandTextView(
          text: $text,
          caret: $caret,
          height: $fieldHeight,
          destinations: destinations,
          isMenuOpen: menu != nil,
          onMenuCommand: handleMenuCommand,
          onSubmit: submit
        )
        .frame(height: fieldHeight)
      }

      if !trimmed.isEmpty {
        Button(action: submit) {
          Image(systemName: "return")
        }
        .buttonStyle(.borderless)
        .help("Run command")
        .accessibilityLabel("Run command")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .quillCard()
  }

  private func handleMenuCommand(_ command: ActCommandTextView.MenuCommand) {
    guard let menu else { return }
    switch command {
    case .up:
      highlighted = max(highlighted - 1, 0)
    case .down:
      highlighted = min(highlighted + 1, menu.matches.count - 1)
    case .accept:
      accept(menu.matches[min(highlighted, menu.matches.count - 1)], in: menu)
    case .dismiss:
      menuDismissed = true
    }
  }

  private func accept(_ destination: QuillActDestination, in menu: ConnectionMentions.Menu) {
    let completed = ConnectionMentions.complete(text, with: destination, replacing: menu.range)
    // Caret lands after the inserted token so typing carries on where the
    // user left off — and, because an exact name match closes the menu,
    // this is also what dismisses it.
    let offset = text.distance(from: text.startIndex, to: menu.range.lowerBound)
      + destination.name.count + 2
    text = completed
    caret = min(offset, (completed as NSString).length)
    highlighted = 0
  }

  private func submit() {
    let result = ConnectionMentions.extract(from: text, destinations: destinations)
    guard !result.text.isEmpty else { return }
    text = ""
    caret = 0
    menuDismissed = false
    onSubmit(result.text, result.pinned)
  }

  // MARK: - Mention menu

  private func mentionMenu(_ menu: ConnectionMentions.Menu) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(menu.matches.enumerated()), id: \.element.id) { index, destination in
        let isHighlighted = index == min(highlighted, menu.matches.count - 1)
        Button {
          accept(destination, in: menu)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: destination.systemImage)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(destination.palette.color())
              .frame(width: 20, height: 20)
              .background(
                RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
                  .fill(destination.palette.color(0.15))
              )
            Text(destination.name)
              .font(.system(size: 12.5, weight: .medium))
            if destination.isMCP {
              Text("MCP")
                .font(.system(size: 8.5, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(
                  RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
            }
            Spacer(minLength: 12)
            if isHighlighted {
              Text("↵")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 5)
          .padding(.horizontal, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .fill(isHighlighted ? Color.primary.opacity(0.08) : .clear)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(5)
    .frame(width: 260, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    )
    .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
  }
}
