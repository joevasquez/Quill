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
        button.addSubview(host)
        NSLayoutConstraint.activate([
          host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
          host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
          host.topAnchor.constraint(equalTo: button.topAnchor),
          host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        chipHostView = host
      }
      statusItem.length = ChipSpec.itemLength
    } else {
      chipHostView?.removeFromSuperview()
      chipHostView = nil
      button.image = HexApp.menuBarIcon
      statusItem.length = NSStatusItem.squareLength
      setBloomVisible(false)
    }
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
        .foregroundColor: NSColor(
          hue: mode.orbHue / 360.0, saturation: 0.6, brightness: 0.9, alpha: 1
        ),
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
