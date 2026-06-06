//
//  HUDPanel.swift
//  Hex
//
//  A small floating panel for the always-visible mode HUD.
//  Draggable, non-activating, stays on top of all windows
//  and persists across Spaces. Position saved to UserDefaults.
//

import AppKit
import SwiftUI

class HUDPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private static let positionKey = "com.joevasquez.Quill.hudPosition"
  private(set) var isPinned: Bool = false

  init() {
    let styleMask: NSWindow.StyleMask = [
      .borderless,
      .nonactivatingPanel,
      .utilityWindow,
    ]

    // Height accommodates both display modes:
    //  - Standard HUD: pill (~36) + integration row (~40) + live
    //    transcript card (~108) + spacing/shadow buffer
    //  - Orb: sphere (~220) + caption (~120) + transcript card
    // Width covers the 520pt transcript card with breathing room.
    super.init(
      contentRect: .init(x: 0, y: 0, width: 560, height: 460),
      styleMask: styleMask,
      backing: .buffered,
      defer: false
    )

    level = .statusBar
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    canHide = false
    // Native AppKit window dragging — any opaque region of the
    // SwiftUI pill that isn't a button becomes the drag handle.
    // No SwiftUI DragGesture needed (those wobble because the
    // coordinate system shifts as the panel moves).
    isMovableByWindowBackground = true
    collectionBehavior = [
      .fullScreenAuxiliary,
      .canJoinAllSpaces,
      .stationary,
      .ignoresCycle,
    ]

    restorePosition()

    // Persist position after every drag.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidMove),
      name: NSWindow.didMoveNotification,
      object: self
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleHUDPositionModeChanged(_:)),
      name: .hudPositionModeChanged,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Position Mode

  func setPinned(_ pinned: Bool) {
    isPinned = pinned
    if pinned {
      isMovableByWindowBackground = false
      pinToTop()
    } else {
      isMovableByWindowBackground = true
      restorePosition()
    }
  }

  @objc private func handleHUDPositionModeChanged(_ notification: Notification) {
    let pinned = (notification.userInfo?["pinned"] as? Bool) ?? false
    setPinned(pinned)
  }

  private func pinToTop() {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let visible = screen.visibleFrame
    let x = visible.midX - frame.width / 2
    let y = visible.maxY - frame.height
    setFrameOrigin(NSPoint(x: x, y: y))
  }

  // MARK: - Position Persistence

  private func restorePosition() {
    if let dict = UserDefaults.standard.dictionary(forKey: Self.positionKey),
       let x = dict["x"] as? CGFloat,
       let y = dict["y"] as? CGFloat
    {
      // Validate the saved point against the *current* display layout.
      // If the user disconnected an external display (or rearranged
      // them in System Settings) since last launch, the saved origin
      // can land entirely offscreen — `setFrameOrigin` will happily
      // accept it and `orderFrontRegardless()` does nothing visible.
      // Use `intersects` rather than `contains` so a deliberately
      // edge-flushed pill isn't re-centered just because one pixel
      // is technically off the screen — only fully-offscreen origins
      // get reset.
      let candidate = NSRect(origin: NSPoint(x: x, y: y), size: frame.size)
      let visibleSomewhere = NSScreen.screens.contains { screen in
        screen.frame.intersects(candidate)
      }
      if visibleSomewhere {
        setFrameOrigin(candidate.origin)
        return
      }
    }
    centerOnMainScreen()
  }

  private func centerOnMainScreen() {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    // Use `visibleFrame` (excludes menu bar + dock) so we don't tuck the
    // pill behind the menu bar. `setFrameOrigin` positions the panel's
    // BOTTOM-LEFT corner — we want the panel TOP near the top of the
    // visible area, so subtract the panel height to land the top edge
    // 16 pt below the menu bar.
    let visible = screen.visibleFrame
    let x = visible.midX - frame.width / 2
    let y = visible.maxY - frame.height - 16
    setFrameOrigin(NSPoint(x: x, y: y))
  }

  @objc private func windowDidMove(_ notification: Notification) {
    guard !isPinned else { return }
    let origin = frame.origin
    UserDefaults.standard.set(
      ["x": origin.x, "y": origin.y],
      forKey: Self.positionKey
    )
  }

  // MARK: - Factory

  static func hosting<V: View>(_ view: V) -> HUDPanel {
    let panel = HUDPanel()
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = panel.contentView!.bounds
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    return panel
  }
}
