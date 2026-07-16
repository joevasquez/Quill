//
//  ModeSwitchHUDController.swift
//  Quill (macOS)
//
//  A brief "you're now in X mode" bubble that drops from the top-center of
//  the screen on every mode switch (cycle hotkey or the menu Mode submenu).
//  Like the macOS input-source / volume HUD, it always flashes on a switch:
//  the menu-bar feather/chip label is the persistent indicator, and this is
//  the momentary confirmation that also covers cases where the menu bar is
//  hidden OR occluded (e.g. a full-screen app, or Citrix drawing over the
//  bar) — situations that can't be detected reliably, so we don't try.
//
//  Driven purely by the `.modeDidChange` notification, so it's independent
//  of the display mode (HUD/Orb/Chip). Owned for the app's lifetime by
//  QuillStatusItemController.
//

import AppKit
import SwiftUI

@MainActor
final class ModeSwitchHUDController {
  private let panel: BubblePanel
  private let model = ModeHUDModel()
  private var dismissTask: Task<Void, Never>?

  /// Generous fixed panel so the centered capsule never clips; the bubble
  /// itself is content-sized and horizontally centered inside.
  private let panelWidth: CGFloat = 320
  private let panelHeight: CGFloat = 64

  /// Non-activating, click-through panel that can float over another app's
  /// full-screen Space (same collection behavior as the Corner Bloom).
  private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }

  init() {
    panel = BubblePanel(
      contentRect: .init(x: 0, y: 0, width: panelWidth, height: panelHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.canHide = false
    panel.ignoresMouseEvents = true  // purely informational — never steal input
    panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]

    let host = NSHostingView(rootView: ModeSwitchHUDBubble(model: model))
    host.sizingOptions = []
    panel.contentView = host

    NotificationCenter.default.addObserver(
      self, selector: #selector(modeDidChange(_:)),
      name: .modeDidChange, object: nil
    )
  }

  @objc private func modeDidChange(_ note: Notification) {
    guard let name = note.userInfo?[ModeChangeNotification.modeNameKey] as? String,
          let mode = TranscriptionIndicatorView.Mode(rawValue: name)
    else { return }
    show(mode)
  }

  private func show(_ mode: TranscriptionIndicatorView.Mode) {
    reposition()
    model.show(mode)
    panel.orderFrontRegardless()

    // Keep it up ~1.4s, then fade. Rapid cycling cancels the pending
    // dismissal and just swaps the label, so the bubble stays put.
    dismissTask?.cancel()
    dismissTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1400))
      guard let self, !Task.isCancelled else { return }
      self.model.hide()
      try? await Task.sleep(for: .milliseconds(300))  // let the SwiftUI fade finish
      guard !Task.isCancelled else { return }
      self.panel.orderOut(nil)
    }
  }

  /// Top-center of the active screen, dropped BELOW the menu bar / camera
  /// notch (like the action-confirmation panel) so the capsule never renders
  /// behind the notch on notched Macs. `topInset` is the larger of the menu-
  /// bar height (frame → visibleFrame gap) and the safe-area (notch) inset,
  /// so it clears both whether the menu bar is visible or hidden.
  private func reposition() {
    guard let screen = NSScreen.main else { return }
    let menuBarGap = screen.frame.maxY - screen.visibleFrame.maxY
    let topInset = max(menuBarGap, screen.safeAreaInsets.top)
    let x = screen.frame.midX - panelWidth / 2
    let y = screen.frame.maxY - topInset - panelHeight
    panel.setFrame(
      NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
      display: true
    )
  }
}

// MARK: - View model

@MainActor
final class ModeHUDModel: ObservableObject {
  @Published var mode: TranscriptionIndicatorView.Mode = .dictate
  @Published var visible = false

  func show(_ newMode: TranscriptionIndicatorView.Mode) {
    mode = newMode
    visible = true
  }

  func hide() { visible = false }
}

// MARK: - Bubble

private struct ModeSwitchHUDBubble: View {
  @ObservedObject var model: ModeHUDModel

  var body: some View {
    VStack {
      if model.visible {
        HStack(spacing: 8) {
          Image(systemName: model.mode.icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(model.mode.accentColor)
          Text(model.mode.rawValue)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
          Capsule().strokeBorder(model.mode.accentColor.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, 6)
    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.visible)
  }
}
