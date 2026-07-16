//
//  QuillStatusItemController.swift
//  Hex (macOS)
//
//  Owns Quill's menu-bar presence: a single NSStatusItem that shows the
//  static template feather in HUD/Orb display modes and becomes the live
//  "Chip + Morph" view (frosted chip, feather↔orb morph, mic meter) in
//  Chip mode — per the design handoff, which specs the orb as a custom
//  layer-backed status-item view rather than a floating panel.
//
//  Also owns:
//  - the app NSMenu (replaces the old SwiftUI MenuBarExtra; spec order:
//    header + mode chip, Check for Updates, Paste Last Transcript,
//    Mode submenu, pending offline actions, Settings, Quit)
//  - the Corner Bloom panel: a non-activating NSPanel anchored under the
//    status item, hosting the live transcript card (SwiftUI drives its
//    content and reports visibility/size; this controller positions it).
//
//  Click behavior (spec): idle → open menu; while capturing → cancel.
//

import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

@MainActor
final class QuillStatusItemController: NSObject, NSMenuDelegate {
  private let store: StoreOf<AppFeature>
  private let transcriptionStore: StoreOf<TranscriptionFeature>
  private let onOpenSettings: () -> Void

  private let statusItem: NSStatusItem
  private var chipHostView: NSHostingView<MenuBarChipView>?

  private let appMenu = NSMenu()
  private let headerItem = NSMenuItem()
  private let pasteItem = NSMenuItem()
  private let pendingItem = NSMenuItem()
  private let modeSubmenu = NSMenu(title: "Mode")

  private var bloomPanel: NSPanel?
  private var bloomCardSize: CGSize = .zero
  private var bloomVisible = false
  /// Shadow margin baked into the hosted bloom view (see CornerBloomHost).
  private let bloomMargin: CGFloat = 30

  /// Flashes the current mode from the top of the screen when the menu bar
  /// is hidden (full-screen app) and the status item isn't visible.
  private let modeSwitchHUD = ModeSwitchHUDController()

  @Shared(.hexSettings) private var hexSettings: HexSettings

  init(store: StoreOf<AppFeature>, onOpenSettings: @escaping () -> Void) {
    self.store = store
    self.transcriptionStore = store.scope(state: \.transcription, action: \.transcription)
    self.onOpenSettings = onOpenSettings
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()

    buildMenu()
    setUpBloomPanel()

    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusItemClicked)
    statusItem.behavior = []

    applyDisplayMode()

    NotificationCenter.default.addObserver(
      self, selector: #selector(displayModeChanged),
      name: .displayModeChanged, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(modeDidChange),
      name: .modeDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(screenParamsChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil
    )
  }

  // MARK: - Label (static feather ↔ live chip)

  @objc private func displayModeChanged() {
    applyDisplayMode()
  }

  private func applyDisplayMode() {
    guard let button = statusItem.button else { return }
    if hexSettings.displayMode == .chip {
      button.image = nil
      button.attributedTitle = NSAttributedString(string: "")  // chip host draws its own label
      if chipHostView == nil {
        let host = NSHostingView(rootView: MenuBarChipView(
          store: transcriptionStore,
          onDesiredLengthChanged: { [weak self] length in
            // Guard against a stale mode-reveal timer firing after the
            // user leaves chip mode (would wrongly widen the feather icon).
            guard let self, self.hexSettings.displayMode == .chip else { return }
            self.statusItem.length = length
          }
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        // Fill the pinned frame instead of hugging the SwiftUI content's
        // intrinsic size. Without this the hosting view sizes to the ~18px
        // glyph, so the chip pill can never fill the menu-bar height (and
        // `chipVMargin` appears to do nothing).
        host.sizingOptions = []
        button.addSubview(host)
        NSLayoutConstraint.activate([
          host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
          host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
          host.topAnchor.constraint(equalTo: button.topAnchor),
          host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        chipHostView = host
      }
      // Size to the persistent label straight away (the chip's onAppear
      // also reports this, but setting it here avoids a first-frame jump).
      statusItem.length = MenuBarChipView.itemLength(for: store.state.transcription.selectedMode)
    } else {
      chipHostView?.removeFromSuperview()
      chipHostView = nil
      button.image = HexApp.menuBarIcon
      button.imagePosition = .imageLeading
      statusItem.length = NSStatusItem.variableLength
      updateStaticModeLabel()
      setBloomVisible(false)
    }
  }

  /// Persistent "feather + colored mode name" for the HUD/Orb display modes
  /// (Chip draws its own label). Keeps the current mode legible in the menu
  /// bar at all times, not just during a capture.
  private func updateStaticModeLabel() {
    guard hexSettings.displayMode != .chip, let button = statusItem.button else { return }
    let mode = store.state.transcription.selectedMode
    // Adaptive label color (not white) — the HUD/Orb label sits directly on
    // the menu bar with no pill behind it, so it must stay legible on a
    // light menu bar too. `labelColor` renders like native menu-bar text.
    button.attributedTitle = NSAttributedString(
      string: " \(mode.rawValue)",
      attributes: [
        .foregroundColor: NSColor.labelColor,
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
      ]
    )
  }

  @objc private func modeDidChange() {
    updateStaticModeLabel()
  }

  // MARK: - Click handling

  @objc private func statusItemClicked() {
    // Spec: clicking the orb while a capture is live cancels it.
    let t = store.state.transcription
    if hexSettings.displayMode == .chip,
       t.isRecording || t.isTranscribing || t.isAIProcessing {
      transcriptionStore.send(.cancel)
      return
    }
    // Otherwise pop the app menu. Assign-and-click so the button action
    // (and its live/cancel branch) stays in control; menuDidClose detaches.
    statusItem.menu = appMenu
    statusItem.button?.performClick(nil)
  }

  func menuDidClose(_ menu: NSMenu) {
    statusItem.menu = nil
  }

  // MARK: - Menu

  private func buildMenu() {
    appMenu.delegate = self
    appMenu.autoenablesItems = false

    headerItem.isEnabled = false
    appMenu.addItem(headerItem)

    let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    updates.target = self
    appMenu.addItem(updates)

    pasteItem.title = "Paste Last Transcript"
    pasteItem.action = #selector(pasteLastTranscript)
    pasteItem.target = self
    appMenu.addItem(pasteItem)

    let typeCommand = NSMenuItem(title: "Type a Command…", action: #selector(openTypedAction), keyEquivalent: "t")
    typeCommand.target = self
    appMenu.addItem(typeCommand)

    appMenu.addItem(.separator())

    let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
    for mode in TranscriptionIndicatorView.Mode.allCases {
      let item = NSMenuItem(title: mode.rawValue, action: #selector(selectMode(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = mode.rawValue
      modeSubmenu.addItem(item)
    }
    modeSubmenu.autoenablesItems = false
    modeItem.submenu = modeSubmenu
    appMenu.addItem(modeItem)

    pendingItem.action = #selector(openSettingsFromPending)
    pendingItem.target = self
    pendingItem.isHidden = true
    appMenu.addItem(pendingItem)

    appMenu.addItem(.separator())

    let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    appMenu.addItem(settings)

    appMenu.addItem(.separator())

    let quit = NSMenuItem(title: "Quit Quill", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    appMenu.addItem(quit)
  }

  func menuWillOpen(_ menu: NSMenu) {
    let mode = store.state.transcription.selectedMode

    // Header: "Quill" + mode chip, matching the spec's header row.
    let header = NSMutableAttributedString(
      string: "Quill",
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    header.append(NSAttributedString(
      string: "   \(mode.rawValue)",
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor(mode.orbPalette.color()),
      ]
    ))
    headerItem.attributedTitle = header

    // Paste Last Transcript: preview + enabled state + shortcut display.
    @Shared(.transcriptionHistory) var history: TranscriptionHistory
    let lastText = history.history.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let lastText, !lastText.isEmpty {
      let snippet = lastText.prefix(28)
      pasteItem.title = "Paste Last Transcript  (\(snippet)\(lastText.count > 28 ? "…" : ""))"
      pasteItem.isEnabled = true
    } else {
      pasteItem.title = "Paste Last Transcript"
      pasteItem.isEnabled = false
    }
    if let hotkey = hexSettings.pasteLastTranscriptHotkey,
       let key = hotkey.key, key.toString.count == 1 {
      pasteItem.keyEquivalent = key.toString.lowercased()
      var mask: NSEvent.ModifierFlags = []
      if hotkey.modifiers.contains(kind: .command) { mask.insert(.command) }
      if hotkey.modifiers.contains(kind: .option) { mask.insert(.option) }
      if hotkey.modifiers.contains(kind: .shift) { mask.insert(.shift) }
      if hotkey.modifiers.contains(kind: .control) { mask.insert(.control) }
      pasteItem.keyEquivalentModifierMask = mask
    } else {
      pasteItem.keyEquivalent = ""
    }

    // Mode submenu checkmarks.
    for item in modeSubmenu.items {
      item.state = (item.representedObject as? String) == mode.rawValue ? .on : .off
    }

    // Pending offline actions — async count; the menu updates in place.
    pendingItem.isHidden = true
    Task { [pendingItem] in
      let count = await ActionQueueManager.shared.snapshot().count
      if count > 0 {
        pendingItem.title = "\(count) Pending Offline Action\(count == 1 ? "" : "s")…"
        pendingItem.isHidden = false
        pendingItem.isEnabled = true
      }
    }
  }

  @objc private func checkForUpdates() { CheckForUpdatesViewModel.shared.checkForUpdates() }
  @objc private func pasteLastTranscript() { store.send(.pasteLastTranscript) }

  @objc private func openTypedAction() {
    TypedActionPanelController.shared.show(store: transcriptionStore)
  }
  @objc private func openSettings() { onOpenSettings() }
  @objc private func openSettingsFromPending() { onOpenSettings() }
  @objc private func quit() { NSApplication.shared.terminate(nil) }

  @objc private func selectMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let mode = TranscriptionIndicatorView.Mode(rawValue: raw)
    else { return }
    transcriptionStore.send(.setMode(mode))
  }

  // MARK: - Corner Bloom panel

  private final class BloomPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }

  private func setUpBloomPanel() {
    let panel = BloomPanel(
      contentRect: .init(x: 0, y: 0, width: ChipSpec.bloomWidth + 60, height: 160),
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
    panel.isMovableByWindowBackground = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]

    let host = NSHostingView(
      rootView: CornerBloomHost(
        store: transcriptionStore,
        onVisibilityChanged: { [weak self] visible in self?.setBloomVisible(visible) },
        onSizeChanged: { [weak self] size in
          self?.bloomCardSize = size
          self?.repositionBloom()
        }
      )
    )
    panel.contentView = host
    bloomPanel = panel
  }

  private func setBloomVisible(_ visible: Bool) {
    guard let panel = bloomPanel else { return }
    let shouldShow = visible && hexSettings.displayMode == .chip
    guard shouldShow != bloomVisible else { return }
    bloomVisible = shouldShow
    if shouldShow {
      repositionBloom()
      panel.orderFrontRegardless()
    } else {
      // Give the SwiftUI fade a beat before pulling the window.
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(220))
        guard let self, !self.bloomVisible else { return }
        self.bloomPanel?.orderOut(nil)
      }
    }
  }

  @objc private func screenParamsChanged() {
    if bloomVisible { repositionBloom() }
  }

  /// Anchors the bloom card 4pt below the menu bar, right-aligned to the
  /// status item. The panel is larger than the card (shadow margin), so
  /// alignment targets the card edges, not the window edges.
  private func repositionBloom() {
    guard let panel = bloomPanel,
          let buttonWindow = statusItem.button?.window
    else { return }
    let anchor = buttonWindow.frame
    let panelSize = CGSize(
      width: bloomCardSize.width > 0 ? bloomCardSize.width + bloomMargin * 2 : ChipSpec.bloomWidth + bloomMargin * 2,
      height: bloomCardSize.height > 0 ? bloomCardSize.height + bloomMargin * 2 : 160
    )
    var x = anchor.maxX - (panelSize.width - bloomMargin)  // card right edge == item right edge
    let y = anchor.minY - 4 + bloomMargin - panelSize.height  // card top 4pt below the bar

    if let screen = buttonWindow.screen ?? NSScreen.main {
      x = min(max(x, screen.visibleFrame.minX - bloomMargin + 8),
              screen.visibleFrame.maxX - panelSize.width + bloomMargin - 8)
    }
    panel.setFrame(
      NSRect(origin: CGPoint(x: x, y: y), size: panelSize),
      display: true
    )
  }
}
