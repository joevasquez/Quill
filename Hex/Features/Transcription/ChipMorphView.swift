//
//  ChipMorphView.swift
//  Hex (macOS)
//
//  "Chip + Morph" display mode — the SwiftUI halves of the menu-bar
//  presence, per the Quill design handoff (design_handoff_menu_bar_orb):
//
//  - `MenuBarChipView` renders INSIDE the NSStatusItem's button (hosted by
//    QuillStatusItemController): an 18px adaptive frosted chip showing the
//    Quill feather at rest; on capture the feather condenses into a
//    mode-hued 12px orb (400ms ink-drop overshoot); while listening the
//    orb face is a 4-bar meter; on resolve it flashes green ~1.7s, then
//    morphs back.
//  - `CornerBloomHost` renders inside the bloom NSPanel anchored under the
//    status item: mode badge + status string, live transcript, Act-mode
//    destination rows, the edit Accept/Undo pill, and error banners.
//
//  Geometry, hues (the shared QuillDesign.ModePalette), and timings
//  follow the spec exactly at menu-bar scale. Both views observe the
//  TranscriptionFeature store directly, so the AppKit controller stays
//  dumb: it only installs views, positions the panel, and shows/hides it
//  when the SwiftUI side reports visibility changes.
//

import ComposableArchitecture
import HexCore
import SwiftUI

// MARK: - Shared derivations

private func liveStatus(_ store: StoreOf<TranscriptionFeature>) -> TranscriptionIndicatorView.Status {
  if store.isAIProcessing { return .aiProcessing }
  if store.isTranscribing { return .transcribing }
  if store.isRecording { return .recording }
  return .idle
}

/// Fixed chip style. The design's `.ultraThinMaterial` + wallpaper-adaptive
/// palette rendered inconsistently inside the status-item hosting view
/// (opaque black on one display, translucent on another — SwiftUI's
/// material needs an NSVisualEffectView backdrop it doesn't get here), and
/// the appearance flip could put a dark feather on a dark chip. A fixed
/// translucent-dark pill with a white glyph is legible on any wallpaper and
/// identical across displays — the same tack as the solid system mic pill.
private enum ChipStyle {
  static let bg = Color.black.opacity(0.34)
  static let ring = Color.white.opacity(0.26)
  static let fg = Color.white.opacity(0.95)
}

/// Tracks the "resolved" flash: when a capture finishes (transcribing/
/// enhancing → idle), the spec holds a green ✓ state for ~1.7s before
/// morphing back to the feather.
@MainActor
private final class ResultFlash: ObservableObject {
  @Published var active = false
  private var task: Task<Void, Never>?

  func statusChanged(from old: TranscriptionIndicatorView.Status, to new: TranscriptionIndicatorView.Status) {
    guard new == .idle, old == .transcribing || old == .aiProcessing else { return }
    task?.cancel()
    active = true
    task = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1700))
      if !Task.isCancelled { self?.active = false }
    }
  }
}

// MARK: - Menu-bar chip (feather ↔ orb morph)

struct MenuBarChipView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  /// Reports the chip's desired status-item width so the controller can
  /// grow/shrink the NSStatusItem when the mode-name reveal appears.
  var onDesiredLengthChanged: (CGFloat) -> Void = { _ in }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var flash = ResultFlash()
  @State private var breathe = false

  private var status: TranscriptionIndicatorView.Status { liveStatus(store) }
  private var isListening: Bool { status == .recording }
  /// The orb is showing (vs the feather).
  private var live: Bool {
    status != .idle || flash.active || store.pendingEditResult != nil
  }

  private var palette: OKLCH {
    if flash.active || store.pendingEditResult != nil { return QuillDesign.ModePalette.resolved }
    let mode = store.selectedMode
    if mode == .auto {
      return status != .idle ? store.autoDetectedMode.orbPalette : QuillDesign.ModePalette.auto
    }
    return mode.orbPalette
  }

  private var orbColor: Color {
    palette.chromaScaled(live ? 1 : Self.restingChromaScale).color()
  }

  /// The chip sits in the menu bar all day, so at rest its orb is muted
  /// well below the mode's full chroma.
  private static let restingChromaScale: Double = 0.39

  private var level: Double {
    isListening ? min(1.0, store.meter.averagePower * 2.5) : 0
  }

  var body: some View {
    HStack(spacing: ChipSpec.labelGap) {
      glyph
        .frame(width: ChipSpec.glyphSlot, height: ChipSpec.glyphSlot)

      // Persistent mode label so the current mode is always legible in the
      // menu bar (not just a transient flash on switch). Keeping it always-on
      // also removes the grow/shrink status-item resize that made switching
      // look glitchy. White on the dark pill for maximum legibility.
      Text(store.selectedMode.rawValue)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(ChipStyle.fg)
        .fixedSize()
        .lineLimit(1)
    }
    .padding(.horizontal, ChipSpec.chipHPad)
    // Fill the button height so the pill matches the system mic pill,
    // insetting a hair from the bar edges. No fixed height → never clips
    // regardless of the exact menu-bar thickness.
    .frame(maxHeight: .infinity)
    .background(
      Capsule(style: .continuous)
        .fill(ChipStyle.bg)
        .overlay(Capsule(style: .continuous).strokeBorder(ChipStyle.ring, lineWidth: 0.5))
    )
    .padding(.vertical, ChipSpec.chipVMargin)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(reduceMotion ? .easeInOut(duration: 0.18)
               : .spring(response: 0.32, dampingFraction: 0.82), value: store.selectedMode)
    .onAppear {
      if !reduceMotion { breathe = true }
      onDesiredLengthChanged(Self.itemLength(for: store.selectedMode))
    }
    .onChange(of: status) { old, new in flash.statusChanged(from: old, to: new) }
    .onChange(of: store.selectedMode) { _, new in
      onDesiredLengthChanged(Self.itemLength(for: new))
    }
    .accessibilityLabel("Quill, \(store.selectedMode.rawValue), \(accessibilityStatus)")
  }

  /// The orb/feather/meter stack (the morph glyph), without the chip capsule.
  private var glyph: some View {
    ZStack {
      // Orb — glow scales with mic level.
      Circle()
        .fill(
          RadialGradient(
            colors: [.white.opacity(0.96), .white.opacity(0.60), .white.opacity(0.34)],
            center: UnitPoint(x: 0.36, y: 0.30),
            startRadius: 0,
            endRadius: ChipSpec.orb * 0.55
          )
        )
        .colorMultiply(orbColor)
        .frame(width: ChipSpec.orb, height: ChipSpec.orb)
        .shadow(color: orbColor.opacity(0.9), radius: 3 + level * 12)
        .opacity(live && !isListening ? 1 : 0)
        .scaleEffect(live ? 1 : 0.30)

      // Feather — the original brand feather (asset), white; idle, with a
      // gentle SCALE breath only. The old opacity breath (0.8↔1.0) read as
      // the feather "pulsing to transparent", so opacity stays solid.
      Image(nsImage: HexApp.menuBarIcon)
        .resizable()
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(ChipStyle.fg)
        .frame(width: ChipSpec.feather.width, height: ChipSpec.feather.height)
        .opacity(live ? 0 : 1)
        .scaleEffect(live ? 0.42 : (breathe ? 1.05 : 1.0))
        .rotationEffect(.degrees(live ? -14 : 0))
        .offset(y: live ? 2 : 0)
        .animation(
          reduceMotion || live
            ? .default
            : .easeInOut(duration: 4.8).repeatForever(autoreverses: true),
          value: breathe
        )

      // 4-bar meter replaces the orb face while listening.
      if isListening {
        ChipMeter(level: level, color: ChipStyle.fg)
          .transition(.opacity)
      }
    }
    // Morph: 400ms ink-drop overshoot ≈ cubic-bezier(.34,1.56,.64,1).
    .animation(
      reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.62),
      value: live
    )
    .animation(.easeInOut(duration: 0.3), value: palette)
  }

  /// Status-item width needed to show the chip + the (persistent) mode
  /// label. Static so the controller can size the item on install without
  /// waiting for the SwiftUI onAppear.
  static func itemLength(for mode: TranscriptionIndicatorView.Mode) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let textW = (mode.rawValue as NSString).size(withAttributes: [.font: font]).width
    let chip = ChipSpec.chipHPad * 2 + ChipSpec.glyphSlot + ChipSpec.labelGap + ceil(textW)
    return chip + ChipSpec.slotSlack
  }

  private var accessibilityStatus: String {
    switch status {
    case .idle: return flash.active ? "done" : "idle"
    case .recording: return "listening"
    case .transcribing: return "transcribing"
    case .aiProcessing: return "enhancing"
    }
  }
}

/// Menu-bar geometry. The chip pill fills the status-item button height
/// (minus `chipVMargin`) so it matches the system dictation mic pill (~25px)
/// by construction, rather than a fixed height that could differ per Mac.
enum ChipSpec {
  static let orb: CGFloat = 16
  static let feather = CGSize(width: 17, height: 17)
  /// Fixed slot the orb/feather/meter render in (widest glyph state).
  static let glyphSlot: CGFloat = 20
  static let chipHPad: CGFloat = 9
  /// Inset from the top/bottom bar edges — the pill fills the rest. A few
  /// points of margin keeps the pill from sitting flush against the bar
  /// edges, giving it a bit of breathing room top and bottom.
  static let chipVMargin: CGFloat = 3
  /// Gap between the glyph and the persistent mode label.
  static let labelGap: CGFloat = 5
  /// Extra room around the chip within the status-item slot.
  static let slotSlack: CGFloat = 8
  static let bloomWidth: CGFloat = 232
}

// MARK: - Listening meter (4 bars, 2×12, gap 1.5)

private struct ChipMeter: View {
  let level: Double
  let color: Color

  var body: some View {
    TimelineView(.animation) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      HStack(spacing: 1.5) {
        ForEach(0..<4, id: \.self) { i in
          let phase = 0.5 + 0.5 * sin(t * 6 + Double(i) * 0.9)
          let scale = 0.3 + level * (0.4 + 0.9 * phase)
          Capsule()
            .fill(color)
            .frame(width: 2, height: 12)
            .scaleEffect(y: max(0.3, scale), anchor: .center)
        }
      }
    }
    .frame(height: 12)
  }
}

// MARK: - Corner Bloom (the live card under the status item)

struct CornerBloomHost: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  /// The AppKit controller shows/hides + repositions the panel from these.
  var onVisibilityChanged: (Bool) -> Void
  var onSizeChanged: (CGSize) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var flash = ResultFlash()
  @State private var intuitedTarget: Integration.Identifier?

  private var status: TranscriptionIndicatorView.Status { liveStatus(store) }

  private var isActMode: Bool {
    store.selectedMode == .action
      || (store.selectedMode == .auto && store.autoDetectedMode == .action)
  }

  private var showResult: Bool {
    status == .idle && (flash.active || store.pendingEditResult != nil)
  }

  private var isVisible: Bool {
    status != .idle || showResult || store.editNeedsSelectionMessage != nil
  }

  private var palette: OKLCH {
    if showResult { return QuillDesign.ModePalette.resolved }
    let mode = store.selectedMode
    if mode == .auto {
      return status != .idle ? store.autoDetectedMode.orbPalette : QuillDesign.ModePalette.auto
    }
    return mode.orbPalette
  }

  private var accent: Color {
    palette.color()
  }

  private var activeTarget: Integration.Identifier? {
    store.lockedActionIntegration ?? intuitedTarget
  }

  private var modeLabel: String {
    let mode = store.selectedMode
    if mode == .auto {
      return status != .idle ? "Auto · \(store.autoDetectedMode.rawValue)" : "Auto"
    }
    return mode.rawValue
  }

  var body: some View {
    Group {
      if isVisible {
        card
          .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.96, anchor: .top)))
      } else {
        Color.clear.frame(width: 1, height: 1)
      }
    }
    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8), value: isVisible)
    .onChange(of: isVisible) { _, visible in onVisibilityChanged(visible) }
    .onChange(of: status) { old, new in
      flash.statusChanged(from: old, to: new)
      if new == .idle { intuitedTarget = nil }
    }
    .onChange(of: store.partialTranscript) { _, text in
      guard isActMode, store.lockedActionIntegration == nil else { return }
      withAnimation(.easeOut(duration: 0.25)) {
        intuitedTarget = OrbView.intuitTarget(from: text, integrations: store.availableActionIntegrations)
      }
    }
    .onAppear { onVisibilityChanged(isVisible) }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 9) {
      // Header: mode badge + right-aligned status string.
      HStack(spacing: 8) {
        Text(modeLabel)
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(accent)
        Spacer(minLength: 12)
        Text(statusString)
          .font(.system(size: 9, weight: .medium, design: .monospaced))
          .tracking(0.3)
          .foregroundStyle(.white.opacity(0.36))
      }

      captionLine

      if isActMode, !store.availableActionIntegrations.isEmpty, !showResult {
        VStack(spacing: 2) {
          ForEach(store.availableActionIntegrations, id: \.self) { id in
            BloomDestinationRow(
              identifier: id,
              isSelected: activeTarget == id,
              onTap: { store.send(.toggleActionIntegrationLock(id)) }
            )
          }
        }
        .padding(.top, 1)
      }

      if let msg = store.editNeedsSelectionMessage {
        Text(msg)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.white.opacity(0.9))
          .padding(.horizontal, 9)
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 7).fill(.red.opacity(0.55)))
      }

      if store.pendingEditResult != nil {
        HStack(spacing: 8) {
          Button { store.send(.inlineEditAccept) } label: {
            Label("Keep", systemImage: "checkmark")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(Capsule().fill(Color.green.opacity(0.85)))
          }
          .buttonStyle(.plain)
          Button { store.send(.inlineEditUndo) } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(Capsule().fill(.white.opacity(0.18)))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 12)
    .frame(width: ChipSpec.bloomWidth, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .background(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(.black.opacity(0.42))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 26, y: 14)
    )
    .background(
      GeometryReader { proxy in
        Color.clear
          .onAppear { onSizeChanged(proxy.size) }
          .onChange(of: proxy.size) { _, size in onSizeChanged(size) }
      }
    )
    .padding(30)  // room for the drop shadow inside the panel window
  }

  @ViewBuilder
  private var captionLine: some View {
    if showResult {
      Text("\u{2713} \(store.pendingEditResult != nil ? "Edit applied" : "Done")")
        .font(.system(size: 12.5))
        .foregroundStyle(.white.opacity(0.34))
    } else if status == .recording, store.partialTranscript.isEmpty {
      Text(isActMode ? "Say \u{201C}add to\u{2026}\u{201D}, or pick an app" : "Listening\u{2026}")
        .font(.system(size: 12.5))
        .foregroundStyle(.white.opacity(0.34))
    } else {
      Text(store.partialTranscript.isEmpty ? "\u{2026}" : store.partialTranscript)
        .font(.system(size: 12.5))
        .lineSpacing(2)
        .foregroundStyle(.white.opacity(0.72))
        .lineLimit(5)
        .truncationMode(.head)
        .animation(.easeOut(duration: 0.2), value: store.partialTranscript)
    }
  }

  private var statusString: String {
    switch status {
    case .recording:
      if isActMode, let target = activeTarget {
        let name = Integration.all.first { $0.identifier == target }?.name ?? "app"
        return (store.lockedActionIntegration != nil ? "steered \u{2192} " : "routing \u{2192} ") + name
      }
      return "listening\u{2026}"
    case .transcribing: return "transcribing\u{2026}"
    case .aiProcessing: return "enhancing\u{2026}"
    case .idle:
      if showResult {
        if isActMode, let target = activeTarget {
          let name = Integration.all.first { $0.identifier == target }?.name ?? "app"
          return "\u{2192} \(name)"
        }
        return "done"
      }
      return ""
    }
  }
}

// MARK: - Bloom destination row (Act mode)

private struct BloomDestinationRow: View {
  let identifier: Integration.Identifier
  let isSelected: Bool
  let onTap: () -> Void

  @State private var isHovering = false

  private var integration: Integration? {
    Integration.all.first { $0.identifier == identifier }
  }

  private var accent: Color {
    let hue = integration?.satelliteHue ?? 220
    return Color(hue: hue / 360.0, saturation: 0.55, brightness: 0.85)
  }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 9) {
        Image(systemName: integration?.systemImage ?? "app")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(isSelected ? .white : accent)
          .frame(width: 15)
        Text(integration?.name ?? identifier.rawValue)
          .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? .white : .white.opacity(0.56))
        Spacer()
        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(.white.opacity(isHovering && !isSelected ? 0.06 : 0))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}
