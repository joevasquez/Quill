//
//  TypedActionPanel.swift
//  Quill (macOS)
//
//  "Type a Command…" — the quiet-room sibling of the hotkey. A small
//  key-capable floating panel with one text field; whatever is typed
//  runs through the exact same agent pipeline as a spoken action
//  (routine triggers, memory, MCP tools, confirmation panel) via
//  `TranscriptionFeature.Action.typedActionSubmitted`. Opened from the
//  menu bar's app menu.
//

import ComposableArchitecture
import HexCore
import SwiftUI

@MainActor
final class TypedActionPanelController {
  static let shared = TypedActionPanelController()

  private var panel: NSPanel?

  func show(store: StoreOf<TranscriptionFeature>) {
    // Re-showing while open just brings it forward.
    if let panel {
      NSApp.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
      return
    }

    let content = TypedActionView(
      onSubmit: { [weak self] text in
        store.send(.typedActionSubmitted(text))
        self?.close()
      },
      onCancel: { [weak self] in self?.close() }
    )

    let host = NSHostingController(rootView: content)
    let panel = NSPanel(contentViewController: host)
    panel.styleMask = [.titled, .closable, .fullSizeContentView]
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.isReleasedWhenClosed = false
    panel.setContentSize(NSSize(width: 440, height: 150))
    panel.center()

    self.panel = panel
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  private func close() {
    panel?.orderOut(nil)
    panel = nil
  }
}

private struct TypedActionView: View {
  var onSubmit: (String) -> Void
  var onCancel: () -> Void

  @State private var text = ""
  @FocusState private var focused: Bool

  private var canRun: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "keyboard")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(QuillDesign.actionAccent)
        Text("Type a command")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
      }

      TextField("Remind me to send the deck tomorrow at 9…", text: $text)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13))
        .focused($focused)
        .onSubmit { run() }

      HStack {
        Text("Runs through your agent — routines, memory, and connections included.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Run", action: run)
          .keyboardShortcut(.defaultAction)
          .disabled(!canRun)
      }
    }
    .padding(16)
    .frame(width: 440)
    .onAppear { focused = true }
  }

  private func run() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSubmit(trimmed)
  }
}
