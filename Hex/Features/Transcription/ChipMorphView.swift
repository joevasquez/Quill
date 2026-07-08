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
//  Geometry, hues (OKLCH 248/305/188/150 ≈ shared OrbHue), and timings
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

/// Spec's adaptive chip palette. The status bar window's effective
/// appearance tracks the wallpaper, and the hosted view's `colorScheme`
/// tracks the window — so semantic switching happens for free.
private struct ChipPalette {
  let bg: Color
  let ring: Color
  let fg: Color

  init(_ scheme: ColorScheme) {
    if scheme == .light {
      // Light wallpaper → light chip surface, dark glyph.
      bg = Color.white.opacity(0.55)
      ring = Color.black.opacity(0.16)
      fg = Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.85)
    } else {
      bg = Color.black.opacity(0.30)
      ring = Color.white.opacity(0.35)
      fg = Color.white.opacity(0.92)
    }
  }
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
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var flash = ResultFlash()
  @State private var breathe = false

  private var status: TranscriptionIndicatorView.Status { liveStatus(store) }
  private var isListening: Bool { status == .recording }
  /// The orb is showing (vs the feather).
  private var live: Bool {
    status != .idle || flash.active || store.pendingEditResult != nil
  }

  private var hue: Double {
    if flash.active || store.pendingEditResult != nil { return OrbHue.success }
    let mode = store.selectedMode
    if mode == .auto {
      return status != .idle ? store.autoDetectedMode.orbHue : OrbHue.auto
    }
    return mode.orbHue
  }

  private var orbColor: Color {
    Color(hue: hue / 360.0, saturation: live ? 0.72 : 0.28, brightness: 0.92)
  }

  private var level: Double {
    isListening ? min(1.0, store.meter.averagePower * 2.5) : 0
  }

  var body: some View {
    let palette = ChipPalette(colorScheme)
    ZStack {
      // Chip surface — 18px capsule, blur behind, 0.5px inner ring.
      Capsule(style: .continuous)
        .fill(palette.bg)
        .overlay(Capsule(style: .continuous).strokeBorder(palette.ring, lineWidth: 0.5))
        .frame(width: ChipSpec.chipWidth, height: ChipSpec.chipHeight)
        .background(
          Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(width: ChipSpec.chipWidth, height: ChipSpec.chipHeight)
        )

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

      // Feather — idle, with the 4.8s breath.
      FeatherShape()
        .stroke(palette.fg, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        .frame(width: ChipSpec.feather.width, height: ChipSpec.feather.height)
        .opacity(live ? 0 : (breathe ? 1.0 : 0.8))
        .scaleEffect(live ? 0.42 : (breathe ? 1.07 : 1.0))
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
        ChipMeter(level: level, color: palette.fg)
          .transition(.opacity)
      }
    }
    // Morph: 400ms ink-drop overshoot ≈ cubic-bezier(.34,1.56,.64,1).
    .animation(
      reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.62),
      value: live
    )
    .animation(.easeInOut(duration: 0.3), value: hue)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { if !reduceMotion { breathe = true } }
    .onChange(of: status) { old, new in flash.statusChanged(from: old, to: new) }
    .accessibilityLabel("Quill, \(store.selectedMode.rawValue), \(accessibilityStatus)")
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

/// Spec geometry at true menu-bar scale.
enum ChipSpec {
  static let chipHeight: CGFloat = 18
  static let chipWidth: CGFloat = 28  // fixed widest footprint (orb 12 / feather 13 + padding)
  static let orb: CGFloat = 12
  static let feather = CGSize(width: 13, height: 14)
  static let itemLength: CGFloat = 36  // NSStatusItem length (chip + breathing room)
  static let bloomWidth: CGFloat = 232
}

// MARK: - Feather glyph

/// The Quill 3-stroke feather, ported from the handoff SVG
/// (`M20 4C11 6 7 11 6 20  M20 4c-2 7-6 10-14 12  M20 4l-2 7-5 2`,
/// 24×24 viewBox). Drawn as three subpaths, scaled to the frame.
struct FeatherShape: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height) / 24.0
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
    }
    var path = Path()
    // 1. Spine
    path.move(to: p(20, 4))
    path.addCurve(to: p(6, 20), control1: p(11, 6), control2: p(7, 11))
    // 2. Barb
    path.move(to: p(20, 4))
    path.addCurve(to: p(6, 16), control1: p(18, 11), control2: p(14, 14))
    // 3. Stem
    path.move(to: p(20, 4))
    path.addLine(to: p(18, 11))
    path.addLine(to: p(13, 13))
    return path
  }
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

  private var hue: Double {
    if showResult { return OrbHue.success }
    let mode = store.selectedMode
    if mode == .auto {
      return status != .idle ? store.autoDetectedMode.orbHue : OrbHue.auto
    }
    return mode.orbHue
  }

  private var accent: Color {
    Color(hue: hue / 360.0, saturation: 0.72, brightness: 0.92)
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
