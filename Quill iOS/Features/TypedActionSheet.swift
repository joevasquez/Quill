//
//  TypedActionSheet.swift
//  Quill (iOS)
//
//  Type-a-command entry point — the quiet-room sibling of the mic.
//  Whatever is typed runs through the exact same agent pipeline as a
//  spoken action (routine triggers, memory, MCP tools, confirmation
//  sheet). Opened from the keyboard button in the FAB fan.
//
//  `@` tags a destination: the mention is stripped from the text and the
//  destination is handed to the planner as a hard directive (everything
//  else is withheld from the prompt). Same grammar as macOS — the parsing
//  lives in `HexCore/Logic/ConnectionMentions.swift`.
//

import HexCore
import SwiftUI

struct TypedActionSheet: View {
  /// Destinations the `@` menu offers — connected, minus anything muted on
  /// the Act chip row.
  var destinations: [QuillActDestination] = []
  /// Clean text (mention tokens removed) plus the destinations they pinned.
  var onSubmit: (String, [QuillActDestination]) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var text = ""
  @FocusState private var focused: Bool
  @AppStorage(QuillIOSSettingsKey.agentName) private var agentName = QuillIOSSettingsKey.defaultAgentName

  private var theme: QuillTheme { .of(colorScheme) }

  private var canRun: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The open mention menu, if any. `ConnectionMentions.menu` owns the
  /// close rules — notably closing on an exact name match, which is what
  /// dismisses the row after a selection (a completed "@Dex " would
  /// otherwise keep matching Dex, since queries may contain spaces).
  private var mentionMenu: ConnectionMentions.Menu? {
    ConnectionMentions.menu(in: text, destinations: destinations)
  }

  private var pinned: [QuillActDestination] {
    ConnectionMentions.extract(from: text, destinations: destinations).pinned
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          ZStack {
            Circle()
              .fill(QuillDesign.actionAccent.opacity(0.18))
              .frame(width: 34, height: 34)
            Image(systemName: "keyboard")
              .quillFont(15, weight: .semibold)
              .foregroundStyle(QuillDesign.actionAccent)
          }
          VStack(alignment: .leading, spacing: 1) {
            Text("Tell \(agentName) what to do")
              .quillFont(15, weight: .semibold)
            Text("Same as speaking — just quieter")
              .quillFont(12)
              .foregroundStyle(.secondary)
          }
        }

        TextField(
          "Remind me to send the deck tomorrow at 9…",
          text: $text,
          axis: .vertical
        )
        .lineLimit(3...6)
        .focused($focused)
        .textFieldStyle(.plain)
        .quillFont(15)
        .padding(12)
        .quillCard()
        .submitLabel(.go)
        .onSubmit { run() }

        if let mentionMenu {
          mentionRow(mentionMenu)
        } else if !pinned.isEmpty {
          pinnedRow
        } else if !destinations.isEmpty {
          Text("Type @ to send this to a specific app")
            .quillFont(12)
            .foregroundStyle(.tertiary)
        }

        Button(action: run) {
          Label("Run", systemImage: "bolt.fill")
            .quillFont(14, weight: .semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
                .fill(canRun ? QuillDesign.actionAccent : QuillDesign.actionAccent.opacity(0.4))
            )
        }
        .disabled(!canRun)

        Spacer(minLength: 0)
      }
      .padding(18)
      .navigationTitle("Type a Command")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .onAppear { focused = true }
    }
    .presentationDetents([.height(330), .medium])
    .presentationDragIndicator(.visible)
  }

  // MARK: - Mentions

  /// Horizontal chips rather than a dropdown: on a phone the keyboard owns
  /// the bottom half of the screen, and a row directly under the field is
  /// reachable with the thumb already resting there.
  private func mentionRow(_ menu: ConnectionMentions.Menu) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 7) {
        ForEach(menu.matches) { destination in
          Button {
            accept(destination, in: menu)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: destination.systemImage)
                .quillFont(11, weight: .semibold)
                .foregroundStyle(destination.palette.color())
              Text(destination.name)
                .quillFont(13, weight: .semibold)
                .foregroundStyle(theme.text)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 11)
            .background(
              Capsule()
                .fill(destination.palette.color(0.14))
                .overlay(Capsule().strokeBorder(destination.palette.color(0.4), lineWidth: 0.5))
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 1)
    }
  }

  private var pinnedRow: some View {
    HStack(spacing: 6) {
      Text("Routing to")
        .quillFont(12)
        .foregroundStyle(.secondary)
      ForEach(pinned) { destination in
        HStack(spacing: 4) {
          Image(systemName: destination.systemImage)
            .quillFont(10, weight: .semibold)
          Text(destination.name)
            .quillFont(12, weight: .semibold)
        }
        .foregroundStyle(destination.palette.color())
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(destination.palette.color(0.14)))
      }
      Spacer(minLength: 0)
    }
  }

  private func accept(_ destination: QuillActDestination, in menu: ConnectionMentions.Menu) {
    text = ConnectionMentions.complete(text, with: destination, replacing: menu.range)
  }

  private func run() {
    let result = ConnectionMentions.extract(from: text, destinations: destinations)
    guard !result.text.isEmpty else { return }
    dismiss()
    onSubmit(result.text, result.pinned)
  }
}
