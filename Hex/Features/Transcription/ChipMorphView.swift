//
//  ChipMorphView.swift
//  Hex (macOS)
//
//  Third display mode: "Chip + Morph" (from the Quill design handoff).
//  A compact frosted chip that shows the Quill feather at rest and morphs
//  into a mode-hued orb the moment capture starts — an ink-drop overshoot.
//  While listening the orb face becomes a 4-bar meter; a "Corner Bloom"
//  card drops below with the live transcript and, in Action mode, the
//  connected destinations.
//
//  This is a native SwiftUI recreation of the HTML/JS prototype
//  (design_handoff_menu_bar_orb). The spec targets an NSStatusItem in the
//  menu bar; here it renders inside the shared HUDPanel like the other two
//  display modes — same inputs, same floating-panel model. Geometry is
//  scaled ~1.8× from the 18px menu-bar spec so it reads as a floating HUD
//  element while keeping the exact proportions, motion curves, and hues.
//
//  Reuses OrbHue / Mode.orbHue (shared with OrbView) so the Chip and Orb
//  modes are colour-identical, and OrbView.intuitTarget for Act routing.
//

import HexCore
import Inject
import SwiftUI

struct ChipMorphView: View {
  typealias Status = TranscriptionIndicatorView.Status
  typealias Mode = TranscriptionIndicatorView.Mode

  var status: Status
  var mode: Mode
  var meter: Meter
  var recordingStartTime: Date?
  var hotkeyHint: String
  var editMessage: String?
  var pendingEditResult: TranscriptionFeature.PendingEditResult?
  var partialTranscript: String = ""
  var actionIntegrations: [Integration.Identifier] = []
  var lockedActionIntegration: Integration.Identifier?
  var autoDetectedMode: Mode = .dictate
  var isPinnedToTop: Bool = false
  var onCycleMode: () -> Void
  var onEditAccept: () -> Void
  var onEditUndo: () -> Void
  var onToggleActionIntegration: (Integration.Identifier) -> Void = { _ in }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var displayedHue: Double = OrbHue.dictate
  @State private var displayedSaturation: Double = 0.28
  @State private var intuitedTarget: Integration.Identifier?
  @State private var breathe = false

  // MARK: Derived state

  private var isLive: Bool { status != .idle }
  private var isListening: Bool { status == .recording }
  private var showResult: Bool { status == .idle && pendingEditResult != nil }

  private var isActMode: Bool {
    mode == .action || (mode == .auto && autoDetectedMode == .action)
  }

  /// The resolved sub-mode when in Auto: Auto borrows the detected mode's
  /// hue while live, neutral otherwise.
  private var effectiveMode: Mode {
    (mode == .auto && isLive) ? autoDetectedMode : mode
  }

  private var targetHue: Double {
    if showResult { return OrbHue.success }
    if mode == .auto && !isLive { return OrbHue.auto }
    return effectiveMode.orbHue
  }

  /// Chroma spec: idle .06, active .16 (OKLCH). Mapped to HSB saturation.
  private var targetSaturation: Double {
    if mode == .auto && !isLive { return 0.22 }
    return isLive || showResult ? 0.72 : 0.28
  }

  private var orbColor: Color {
    Color(hue: displayedHue / 360.0, saturation: displayedSaturation, brightness: 0.92)
  }

  private var audioLevel: Double {
    isListening ? min(1.0, meter.averagePower * 2.5) : 0
  }

  private var activeTarget: Integration.Identifier? {
    lockedActionIntegration ?? intuitedTarget
  }

  private var modeLabel: String {
    if mode == .auto { return isLive ? "Auto · \(autoDetectedMode.rawValue)" : "Auto" }
    return mode.rawValue
  }

  // MARK: Body

  var body: some View {
    VStack(spacing: ChipSize.stackGap) {
      chip
        .onTapGesture { onCycleMode() }
        .accessibilityLabel("Quill, \(modeLabel), \(statusAccessibilityLabel)")

      if isLive || showResult {
        bloomCard
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      if let msg = editMessage {
        Text(msg)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Capsule().fill(.red.opacity(0.85)))
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      if pendingEditResult != nil {
        editAcceptancePill
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.snappy(duration: 0.3), value: isLive)
    .animation(.snappy(duration: 0.25), value: showResult)
    .animation(.snappy(duration: 0.25), value: editMessage != nil)
    .animation(.snappy(duration: 0.25), value: pendingEditResult != nil)
    .animation(.snappy(duration: 0.25), value: partialTranscript.isEmpty)
    .onAppear {
      displayedHue = targetHue
      displayedSaturation = targetSaturation
      if !reduceMotion { breathe = true }
    }
    .onChange(of: targetHue) { _, newHue in
      withAnimation(.easeInOut(duration: 0.3)) { displayedHue = newHue }
    }
    .onChange(of: targetSaturation) { _, newSat in
      withAnimation(.easeInOut(duration: 0.3)) { displayedSaturation = newSat }
    }
    .onChange(of: partialTranscript) { _, text in
      guard isActMode, lockedActionIntegration == nil else { return }
      withAnimation(.easeOut(duration: 0.25)) {
        intuitedTarget = OrbView.intuitTarget(from: text, integrations: actionIntegrations)
      }
    }
    .onChange(of: status) { _, newStatus in
      if newStatus == .idle { intuitedTarget = nil }
    }
    .onChange(of: mode) { _, newMode in
      if newMode != .action { intuitedTarget = nil }
    }
  }

  private var statusAccessibilityLabel: String {
    switch status {
    case .idle: return showResult ? "done" : "idle"
    case .recording: return "listening"
    case .transcribing: return "transcribing"
    case .aiProcessing: return "enhancing"
    }
  }

  // MARK: - The chip (feather ↔ orb morph)

  private var chip: some View {
    ZStack {
      // Orb glow — scales with mic level, only while live.
      if isLive || showResult {
        Circle()
          .fill(orbColor)
          .frame(width: ChipSize.orb, height: ChipSize.orb)
          .blur(radius: 8)
          .opacity(0.55 + audioLevel * 0.4)
          .animation(.interpolatingSpring(stiffness: 260, damping: 16), value: audioLevel)
      }

      // The orb sphere.
      orbSphere
        .opacity(isLive || showResult ? (isListening ? 0 : 1) : 0)
        .scaleEffect(isLive || showResult ? 1 : 0.30)

      // The feather (idle).
      FeatherShape()
        .stroke(chipForeground, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .frame(width: ChipSize.feather.width, height: ChipSize.feather.height)
        .opacity(isLive || showResult ? 0 : 1)
        .scaleEffect(isLive || showResult ? 0.42 : (breathe ? 1.07 : 1.0), anchor: .center)
        .rotationEffect(.degrees(isLive || showResult ? -14 : 0))
        .offset(y: isLive || showResult ? 2 : 0)
        .animation(
          reduceMotion ? .none : .easeInOut(duration: 4.8).repeatForever(autoreverses: true),
          value: breathe
        )

      // The 4-bar meter — replaces the orb face while listening.
      if isListening {
        ChipMeter(level: audioLevel, color: chipForeground)
      }
    }
    // Morph timing: ink-drop overshoot (cubic-bezier(.34,1.56,.64,1)).
    .animation(
      reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.62),
      value: isLive
    )
    .frame(width: ChipSize.orb, height: ChipSize.orb)
    .padding(.horizontal, ChipSize.hPad)
    .frame(height: ChipSize.height)
    .background(chipBackground)
  }

  private var orbSphere: some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [.white.opacity(0.96), .white.opacity(0.62), .white.opacity(0.34)],
          center: UnitPoint(x: 0.36, y: 0.30),
          startRadius: 0,
          endRadius: ChipSize.orb * 0.55
        )
      )
      .colorMultiply(orbColor)
      .overlay(
        Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.5)
          .blur(radius: 0.4)
      )
      .frame(width: ChipSize.orb, height: ChipSize.orb)
  }

  /// Adaptive frosted chip. `.ultraThinMaterial` tracks the desktop behind
  /// the panel; a subtle dark scrim + inner ring give the "contrast floor"
  /// the spec asks the chip to guarantee on any wallpaper.
  private var chipBackground: some View {
    Capsule(style: .continuous)
      .fill(.ultraThinMaterial)
      .overlay(Capsule(style: .continuous).fill(.black.opacity(0.22)))
      .overlay(
        Capsule(style: .continuous)
          .strokeBorder(.white.opacity(0.30), lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(isPinnedToTop ? 0 : 0.35), radius: 10, y: 4)
      .shadow(color: orbColor.opacity(isLive ? 0.35 : 0), radius: 12)
  }

  private var chipForeground: Color { .white.opacity(0.92) }

  // MARK: - Corner Bloom card

  private var bloomCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      // Header: mode badge + status string.
      HStack(spacing: 8) {
        Text(modeLabel)
          .font(.system(size: 11.5, weight: .bold))
          .foregroundStyle(orbColor)
        Spacer()
        Text(statusString)
          .font(.system(size: 9.5, weight: .medium, design: .monospaced))
          .tracking(0.3)
          .foregroundStyle(.white.opacity(0.4))
      }

      // Body: live transcript, or the muted result / prompt line.
      captionLine

      // Act mode: connected destinations.
      if isActMode, !actionIntegrations.isEmpty, !showResult {
        VStack(spacing: 2) {
          ForEach(actionIntegrations, id: \.self) { id in
            BloomDestinationRow(
              identifier: id,
              isSelected: activeTarget == id,
              onTap: { onToggleActionIntegration(id) }
            )
          }
        }
        .padding(.top, 1)
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 12)
    .frame(width: ChipSize.bloomWidth, alignment: .leading)
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
        .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
    )
  }

  @ViewBuilder
  private var captionLine: some View {
    if showResult {
      Text("\u{2713} \(resultText)")
        .font(.system(size: 12.5))
        .foregroundStyle(.white.opacity(0.32))
    } else if isListening, !partialTranscript.isEmpty {
      Text(partialTranscript)
        .font(.system(size: 12.5))
        .lineSpacing(2)
        .foregroundStyle(.white.opacity(0.72))
        .lineLimit(4)
        .truncationMode(.head)
        .animation(.easeOut(duration: 0.2), value: partialTranscript)
    } else if status == .transcribing || status == .aiProcessing {
      Text(partialTranscript.isEmpty ? "\u{2026}" : partialTranscript)
        .font(.system(size: 12.5))
        .lineSpacing(2)
        .foregroundStyle(.white.opacity(0.72))
        .lineLimit(4)
    } else {
      // listening, no words yet
      Text(promptText)
        .font(.system(size: 12.5))
        .foregroundStyle(.white.opacity(0.32))
    }
  }

  private var promptText: String {
    isActMode ? "Say \u{201C}add to\u{2026}\u{201D}, or pick an app" : hotkeyHint
  }

  private var statusString: String {
    switch status {
    case .recording:
      if isActMode, let target = activeTarget {
        let name = Integration.all.first { $0.identifier == target }?.name ?? "app"
        return "routing \u{2192} \(name)"
      }
      return "listening\u{2026}"
    case .transcribing:
      return "transcribing\u{2026}"
    case .aiProcessing:
      return "enhancing\u{2026}"
    case .idle:
      if showResult { return isActMode ? resultStatus : "done" }
      return ""
    }
  }

  private var resultStatus: String {
    if isActMode, let target = activeTarget {
      let name = Integration.all.first { $0.identifier == target }?.name ?? "app"
      return "\u{2192} \(name)"
    }
    return "done"
  }

  private var resultText: String {
    switch pendingEditResult {
    case .some: return "Edit applied"
    case .none: return "Done"
    }
  }

  // MARK: - Edit acceptance pill (Accept / Undo)

  private var editAcceptancePill: some View {
    HStack(spacing: 8) {
      Button(action: onEditAccept) {
        Label("Keep", systemImage: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Capsule().fill(Color.green.opacity(0.85)))
      }
      .buttonStyle(.plain)
      Button(action: onEditUndo) {
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

// MARK: - Geometry (scaled ~1.8× from the 18px menu-bar spec)

private enum ChipSize {
  static let height: CGFloat = 34
  static let hPad: CGFloat = 13
  static let orb: CGFloat = 22
  static let feather = CGSize(width: 23, height: 25)
  static let stackGap: CGFloat = 9
  static let bloomWidth: CGFloat = 244
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

    // 1. Spine: M20 4 C 11 6, 7 11, 6 20
    path.move(to: p(20, 4))
    path.addCurve(to: p(6, 20), control1: p(11, 6), control2: p(7, 11))

    // 2. Barb: M20 4 c -2 7, -6 10, -14 12  → abs C 18 11, 14 14, 6 16
    path.move(to: p(20, 4))
    path.addCurve(to: p(6, 16), control1: p(18, 11), control2: p(14, 14))

    // 3. Stem: M20 4 l -2 7 l -5 2  → L 18 11, L 13 13
    path.move(to: p(20, 4))
    path.addLine(to: p(18, 11))
    path.addLine(to: p(13, 13))

    return path
  }
}

// MARK: - Listening meter (4 bars)

private struct ChipMeter: View {
  let level: Double
  let color: Color

  var body: some View {
    TimelineView(.animation) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      HStack(spacing: 2.5) {
        ForEach(0..<4, id: \.self) { i in
          let phase = 0.5 + 0.5 * sin(t * 6 + Double(i) * 0.9)
          let scale = 0.3 + level * (0.4 + 0.9 * phase)
          Capsule()
            .fill(color)
            .frame(width: 3, height: 20)
            .scaleEffect(y: max(0.3, scale), anchor: .center)
        }
      }
    }
    .frame(height: 20)
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

// MARK: - Preview

#Preview("Chip states") {
  VStack(spacing: 26) {
    ChipMorphView(
      status: .idle, mode: .dictate, meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold \u{2325} Space to dictate",
      onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
    )
    ChipMorphView(
      status: .recording, mode: .action, meter: .init(averagePower: 0.6, peakPower: 0.8),
      hotkeyHint: "Hold \u{2325} Space", partialTranscript: "add to todoist write the launch email",
      actionIntegrations: [.todoist, .gmail, .calendar, .appleReminders],
      onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
    )
  }
  .padding(50)
  .frame(width: 420, height: 460)
  .background(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
}
