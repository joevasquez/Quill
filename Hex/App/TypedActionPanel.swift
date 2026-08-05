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
      onSubmit: { [weak self] text, pinned in
        store.send(
          .typedActionSubmitted(text, targeting: ActTargeting(routable: [], pinned: pinned))
        )
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
    panel.setContentSize(NSSize(width: 440, height: 248))
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
  var onSubmit: (String, [QuillActDestination]) -> Void
  var onCancel: () -> Void

  @AppStorage(IntegrationConnectionStore.userDefaultsKey) private var connectedIntegrationsData = Data()
  @Shared(.hexSettings) private var hexSettings: HexSettings

  /// Everything connected right now — the `@` menu's contents. The panel
  /// has no chip row of its own (it's a 440pt scratchpad), so nothing is
  /// muted here; pins are the only targeting signal.
  private var destinations: [QuillActDestination] {
    QuillActDestination.connected(
      integrations: IntegrationConnectionStore.decode(connectedIntegrationsData),
      servers: hexSettings.mcpServers
    )
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

      ActCommandField(
        destinations: destinations,
        placeholder: "Remind me to send the deck tomorrow at 9…",
        hint: "Type @ to send this to a specific app",
        onSubmit: onSubmit
      )

      Spacer(minLength: 0)

      HStack {
        Text("Runs through your agent — routines, memory, and connections included.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(16)
    // Tall enough that the `@` menu — an overlay, so it never grows its
    // parent — isn't clipped by the panel's content bounds.
    .frame(width: 440, height: 248, alignment: .top)
  }
}
