//
//  OwlView.swift
//  Hex
//
//  The Owl display mode: a pixel-art owl that acts out what Quill is
//  doing — waiting, writing on its notepad while you dictate, thinking
//  while a task runs. Chrome (avatar card, mode pill, transcription
//  bubble) follows the "Quill — Owl avatar view mode" design handoff.
//
//  The owl is hosted in the same `HUDPanel` as the standard HUD and the
//  orb, so it inherits that panel's drag, position persistence, and
//  non-activating/all-Spaces behaviour.
//

import HexCore
import SwiftUI

struct OwlView: View {
  typealias Status = TranscriptionIndicatorView.Status
  typealias Mode = TranscriptionIndicatorView.Mode

  var status: Status
  var mode: Mode
  var meter: Meter
  var editMessage: String?
  var pendingEditResult: TranscriptionFeature.PendingEditResult?
  var partialTranscript: String = ""
  /// When mode is .auto, the detected sub-mode (dictate/edit/action).
  var autoDetectedMode: Mode = .dictate
  var onCycleMode: () -> Void
  var onEditAccept: () -> Void
  var onEditUndo: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  /// One monotonic clock for the sprite. Never reset on a mode change —
  /// each state loops on its own period, so a shared clock keeps the
  /// motion continuous through the cut.
  @State private var mountedAt = Date()
  /// Rasterized sprite layers, rebuilt only when the accent changes.
  @State private var layers: QuillOwlSprite.Layers?

  // MARK: - Layout constants (design handoff)

  private enum Layout {
    /// Displayed avatar size in points. Sprite is 48², so one sprite pixel
    /// is 1.5 pt — exactly 3 device pixels on a 2× display.
    static let avatar: CGFloat = 72
    static let spriteScale = 3            // canvas pixels per sprite pixel
    static let cardPadding: CGFloat = 6
    static let pillGap: CGFloat = 5
    static let bubbleGap: CGFloat = 12
    static let bubbleLift: CGFloat = 26   // bubble sits above the row baseline
    static let bubbleMaxWidth: CGFloat = 320
    static let textMinWidth: CGFloat = 210
    static let textMaxWidth: CGFloat = 263
    static let barSize = CGSize(width: 2, height: 18)
    static let barFloor: CGFloat = 0.22
    /// Avatar card width. The column is pinned to it so a transient
    /// message below can't nudge the owl sideways.
    static let column: CGFloat = avatar + cardPadding * 2
  }

  private enum Palette {
    static let cardSurface = Color(hex: "#14111b")!
    static let cardHairline = Color(hex: "#322b40")!
    static let bubbleHairline = Color(hex: "#362e46")!
    static let pillHairline = Color(hex: "#2c2539")!
    static let textPrimary = Color(hex: "#e6dfd2")!
    static let textMuted = Color(hex: "#9d94a9")!
  }

  // MARK: - Derived state

  private var owlMode: OwlSpriteMode {
    switch status {
    case .idle: return .ready
    case .recording: return .writing
    case .transcribing, .aiProcessing: return .working
    }
  }

  /// The owl wears Quill's mode colour on its hat band, progress bar,
  /// waveform, and caret — so the mode reads even without the pill text.
  private var accentPalette: OKLCH {
    if mode == .auto, status != .idle { return autoDetectedMode.orbPalette }
    return mode.orbPalette
  }

  private var accentColor: Color { accentPalette.color() }

  /// At rest the pill names the Quill mode (Auto/Dictate/Edit/Action);
  /// once the owl is busy it names what the owl is doing.
  private var pillText: String {
    switch status {
    case .idle: return mode.rawValue
    case .recording: return "Writing"
    case .transcribing, .aiProcessing: return "Working"
    }
  }

  private var pillColor: Color {
    status == .idle ? accentColor : Palette.textMuted
  }

  // MARK: - Body

  var body: some View {
    HStack(alignment: .bottom, spacing: Layout.bubbleGap) {
      // Fixed-width slot so the owl never shifts as the bubble appears or
      // as words arrive — the bubble grows up and to the left inside it.
      bubbleSlot
        .frame(width: Layout.bubbleMaxWidth, alignment: .trailing)

      VStack(spacing: Layout.pillGap) {
        owlDock
        if let editMessage {
          Text(editMessage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.red.opacity(0.85)))
            .fixedSize()
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if pendingEditResult != nil {
          editAcceptancePill
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .frame(width: Layout.column)
    }
    .quillAnimation(.snappy(duration: 0.25), value: status)
    .quillAnimation(.snappy(duration: 0.25), value: mode)
    .quillAnimation(.snappy(duration: 0.25), value: editMessage != nil)
    .quillAnimation(.snappy(duration: 0.25), value: pendingEditResult != nil)
  }

  // MARK: - Avatar

  /// Owl + mode pill. The whole dock is the drag handle — a press that
  /// doesn't move the panel still counts as a click and cycles the mode.
  /// The edit message and Reject/Keep pill stay outside it so their
  /// buttons keep receiving clicks.
  private var owlDock: some View {
    VStack(spacing: Layout.pillGap) {
      avatarCard
      modePill
    }
    .overlay(WindowDragHandle(onClick: onCycleMode))
  }

  private var avatarCard: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let elapsed = context.date.timeIntervalSince(mountedAt)
      let sprite = layers
      let colors = QuillOwlSprite.DynamicColors(accent: accentColor)
      Canvas { gfx, size in
        guard let sprite else { return }
        QuillOwlSprite.draw(
          in: gfx,
          unit: size.width / CGFloat(QuillOwlSprite.spriteSize),
          t: elapsed,
          mode: owlMode,
          layers: sprite,
          colors: colors
        )
      }
      .frame(width: Layout.avatar, height: Layout.avatar)
    }
    .onAppear { rebuildLayers() }
    .onChange(of: accentPalette) { _, _ in rebuildLayers() }
    .padding(Layout.cardPadding)
    .background(surface(opacity: 0.82, radius: QuillDesign.Radius.panel, hairline: Palette.cardHairline))
    .shadow(color: .black.opacity(0.55), radius: 19, y: 8)
    .accessibilityElement()
    .accessibilityLabel("Quill owl, \(mode.rawValue) mode")
    .accessibilityValue(statusDescription)
    .accessibilityHint("Cycles the capture mode")
    .accessibilityAddTraits(.isButton)
    // The drag handle sits above this view and swallows real clicks, so
    // VoiceOver activation needs its own route to the same action.
    .accessibilityAction { onCycleMode() }
  }

  private func rebuildLayers() {
    layers = QuillOwlSprite.makeLayers(accent: accentPalette, scale: Layout.spriteScale)
  }

  private var statusDescription: String {
    switch status {
    case .idle: return "waiting"
    case .recording: return "listening"
    case .transcribing: return "transcribing"
    case .aiProcessing: return "enhancing"
    }
  }

  // MARK: - Mode pill

  private var modePill: some View {
    // Silkscreen (the handoff's pixel face) isn't bundled — the documented
    // fallback is uppercase monospace.
    Text(pillText.uppercased())
      .font(.system(size: 9, weight: .regular, design: .monospaced))
      .tracking(1.26)                       // 0.14em at 9pt
      .foregroundStyle(pillColor)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(surface(opacity: 0.82, radius: 999, hairline: Palette.pillHairline))
      .accessibilityHidden(true)            // the avatar already announces it
  }

  // MARK: - Transcription bubble

  @ViewBuilder
  private var bubbleSlot: some View {
    if status == .recording {
      transcriptionBubble
        .padding(.bottom, Layout.bubbleLift)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
  }

  private var transcriptionBubble: some View {
    HStack(alignment: .center, spacing: 10) {
      waveform
      bubbleText
    }
    .padding(.horizontal, 15)
    .padding(.vertical, 11)
    .background(
      bubbleShape
        .fill(reduceTransparency ? AnyShapeStyle(Palette.cardSurface) : AnyShapeStyle(.ultraThinMaterial))
        .overlay(bubbleShape.fill(Palette.cardSurface.opacity(reduceTransparency ? 1 : 0.92)))
        .overlay(bubbleShape.strokeBorder(Palette.bubbleHairline, lineWidth: 1))
    )
    .compositingGroup()
    .shadow(color: .black.opacity(0.5), radius: 17, y: 7)
  }

  /// The small corner points at the owl.
  private var bubbleShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      topLeadingRadius: QuillDesign.Radius.panel,
      bottomLeadingRadius: QuillDesign.Radius.panel,
      bottomTrailingRadius: QuillDesign.Radius.xs,
      topTrailingRadius: QuillDesign.Radius.panel,
      style: .continuous
    )
  }

  private var bubbleText: some View {
    Group {
      if partialTranscript.isEmpty {
        Text("Listening\u{2026}")
          .foregroundStyle(Palette.textMuted)
      } else {
        // Keep the tail visible rather than growing unbounded.
        Text(partialTranscript).foregroundStyle(Palette.textPrimary)
          + Text(verbatim: "\u{2581}").foregroundColor(accentColor)
      }
    }
    .font(.system(size: 13))
    .lineSpacing(13 * 0.45)
    .lineLimit(3)
    .truncationMode(.head)
    .multilineTextAlignment(.leading)
    .frame(minWidth: Layout.textMinWidth, maxWidth: Layout.textMaxWidth, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .animation(.easeOut(duration: 0.18), value: partialTranscript)
  }

  /// Four bars driven by the real mic level, with per-bar weights so they
  /// read as speech rather than a metronome. The 0.22 floor keeps every
  /// bar visible.
  private var waveform: some View {
    HStack(spacing: 3) {
      ForEach(0..<4, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .fill(accentColor)
          .frame(width: Layout.barSize.width, height: Layout.barSize.height)
          .scaleEffect(y: barScale(i), anchor: .center)
      }
    }
    .frame(height: Layout.barSize.height)
    .animation(.easeOut(duration: 0.12), value: meter.averagePower)
    .accessibilityHidden(true)
  }

  private static let barWeights: [Double] = [1.0, 0.68, 0.86, 0.55]

  private func barScale(_ index: Int) -> CGFloat {
    let level = min(1, max(0, meter.averagePower * 2.5))
    let weighted = level * Self.barWeights[index]
    return Layout.barFloor + CGFloat(weighted) * (1 - Layout.barFloor)
  }

  // MARK: - Edit acceptance pill

  private var editAcceptancePill: some View {
    HStack(spacing: 2) {
      Button(action: onEditUndo) {
        HStack(spacing: 4) {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
          Text("Reject").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .fill(.white.opacity(0.08))
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Reject edit")

      Button(action: onEditAccept) {
        HStack(spacing: 4) {
          Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
          Text("Keep").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .fill(.green)
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Keep edit")
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(.black.opacity(0.7))
    )
    .fixedSize()
  }

  // MARK: - Shared surface

  /// Dark vibrancy card. Reduce Transparency swaps the material for the
  /// opaque surface — translucency is the elevation model here.
  private func surface(opacity: Double, radius: CGFloat, hairline: Color) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return shape
      .fill(reduceTransparency ? AnyShapeStyle(Palette.cardSurface) : AnyShapeStyle(.ultraThinMaterial))
      .overlay(shape.fill(Palette.cardSurface.opacity(reduceTransparency ? 1 : opacity)))
      .overlay(shape.strokeBorder(hairline, lineWidth: 1))
  }
}

// MARK: - Window drag handle

/// Drags the host panel natively via `NSWindow.performDrag`.
///
/// Three reasons this is AppKit rather than a SwiftUI `DragGesture`:
/// `performDrag` runs AppKit's own tracking loop, so the drag doesn't
/// wobble as the window moves out from under the gesture's coordinate
/// space; `acceptsFirstMouse` lets the owl respond on the *first* click
/// while Quill is in the background (the normal state for a dictation
/// HUD); and it can tell a drag from a click, so tap-to-cycle-mode
/// survives — a press that leaves the panel where it found it is a click.
private struct WindowDragHandle: NSViewRepresentable {
  var onClick: () -> Void

  final class HandleView: NSView {
    var onClick: () -> Void = {}

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      // Cursor rects only apply to the key window and the HUD panel never
      // becomes key, so drive the cursor from an always-active tracking area.
      addTrackingArea(NSTrackingArea(
        rect: .zero,
        options: [.activeAlways, .inVisibleRect, .cursorUpdate],
        owner: self
      ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
      NSCursor.openHand.set()
    }

    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      // "Pin HUD to Top" parks the panel deliberately — respect it.
      if let hud = window as? HUDPanel, hud.isPinned {
        onClick()
        return
      }
      let origin = window.frame.origin
      window.performDrag(with: event)   // returns on mouse-up
      if window.frame.origin == origin { onClick() }
    }
  }

  func makeNSView(context: Context) -> HandleView {
    let view = HandleView()
    view.onClick = onClick
    return view
  }

  func updateNSView(_ nsView: HandleView, context: Context) {
    nsView.onClick = onClick
  }
}

// MARK: - Preview

#Preview("Owl — ready") {
  OwlView(
    status: .idle,
    mode: .dictate,
    meter: Meter(averagePower: 0, peakPower: 0),
    onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
  )
  .padding(40)
  .background(.black)
}

#Preview("Owl — writing") {
  OwlView(
    status: .recording,
    mode: .action,
    meter: Meter(averagePower: 0.35, peakPower: 0.5),
    partialTranscript: "Move the Thursday draft into the archive and flag it for review.",
    onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
  )
  .padding(40)
  .background(.black)
}

#Preview("Owl — working") {
  OwlView(
    status: .transcribing,
    mode: .edit,
    meter: Meter(averagePower: 0, peakPower: 0),
    onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
  )
  .padding(40)
  .background(.black)
}
