//
//  OrbView.swift
//  Hex
//
//  Alternative "Orb" display mode for the floating HUD. A single
//  luminous sphere whose hue encodes the mode (Dictate/Edit/Action)
//  and whose motion encodes the phase (idle/listening/transcribing/result).
//  Same inputs as TranscriptionIndicatorView — just a different skin.
//

import HexCore
import SwiftUI

// MARK: - Orb colour constants

// Shared by OrbView and ChipMorphView, and with iOS via QuillDesign — the
// two platforms render one palette so the orb reads the same on both.
//
// These are OKLCH hues and must be rendered through `OKLCH`, never through
// `Color(hue:saturation:brightness:)`. The spaces disagree at the same
// number: HSB 248 is blue-violet, OKLCH 248 is sky blue.
enum OrbHue {
  static let auto = QuillDesign.Hue.auto
  static let dictate = QuillDesign.Hue.dictate
  static let edit = QuillDesign.Hue.edit
  static let action = QuillDesign.Hue.action
  static let success = QuillDesign.Hue.success
}

extension TranscriptionIndicatorView.Mode {
  /// The mode's full-strength colour — hue, chroma and lightness together.
  var orbPalette: OKLCH {
    switch self {
    case .auto:    return QuillDesign.ModePalette.auto
    case .dictate: return QuillDesign.ModePalette.dictate
    case .edit:    return QuillDesign.ModePalette.edit
    case .action:  return QuillDesign.ModePalette.act
    }
  }

  var orbHue: Double { orbPalette.H }
}

// MARK: - Size constants

private enum OrbSize {
  static let core: CGFloat = 81
  static let field: CGFloat = 160
  static let fieldWithRing: CGFloat = 220
  /// Idle is deliberately compact — the orb sits on screen all day, so
  /// at rest it shrinks to a small, quiet presence and only blooms to
  /// full size while recording/processing. The content is scaled (not
  /// re-laid-out) so every sub-view keeps its proportions. 0.72 keeps
  /// the caption and mode legible; an earlier 0.58 was too small to read.
  static let idleScale: CGFloat = 0.72
  static let idleField: CGFloat = 118
  static let idleFieldWithRing: CGFloat = 172
  static let satelliteRingRadius: CGFloat = 90
  static let satelliteTileSize: CGFloat = 32
  static let meterFrame: CGFloat = 130
  static let meterRadius: CGFloat = 50
  static let arcFrame: CGFloat = 100
  static let glowBlur: CGFloat = 28
  static let gradientEnd: CGFloat = 40
  static let sheenEnd: CGFloat = 36
}

// MARK: - Orb View

struct OrbView: View {
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
  /// Enabled MCP servers — shown as branded satellites alongside the
  /// integrations (display + live intuition; tap-to-lock stays on
  /// integrations, whose lock overrides the parsed target).
  var mcpServerNames: [String] = []
  var lockedActionIntegration: Integration.Identifier?
  /// When mode is .auto, the detected sub-mode (dictate/edit/action).
  var autoDetectedMode: Mode = .dictate
  var isPinnedToTop: Bool = false
  var onCycleMode: () -> Void
  var onEditAccept: () -> Void
  var onEditUndo: () -> Void
  var onToggleActionIntegration: (Integration.Identifier) -> Void = { _ in }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The orb is quiet at rest and saturates as it comes alive. These scale
  /// the mode's own chroma rather than replacing it, so each mode keeps its
  /// intended intensity.
  private static let idleChromaScale: Double = 0.667
  private static let autoIdleChromaScale: Double = 0.4

  @State private var displayedHue: Double = QuillDesign.ModePalette.dictate.H
  @State private var displayedChroma: Double = QuillDesign.ModePalette.dictate.C * OrbView.idleChromaScale
  @State private var displayedLightness: Double = QuillDesign.ModePalette.dictate.L
  @State private var intuitedTarget: OrbRingTarget?

  private var isLive: Bool { status != .idle }
  private var isListening: Bool { status == .recording }
  private var isTranscribing: Bool { status == .transcribing || status == .aiProcessing }

  private var isActMode: Bool {
    mode == .action || (mode == .auto && autoDetectedMode == .action)
  }

  private var showResult: Bool {
    status == .idle && pendingEditResult != nil
  }

  /// The colour the orb is heading toward. In Auto mode it shifts to the
  /// detected sub-mode's colour during recording.
  private var targetPalette: OKLCH {
    if showResult { return QuillDesign.ModePalette.resolved }
    if mode == .auto && isLive { return autoDetectedMode.orbPalette }
    return mode.orbPalette
  }

  private var targetChroma: Double {
    let full = targetPalette.C
    if mode == .auto && !isLive { return full * Self.autoIdleChromaScale }
    return isLive ? full : full * Self.idleChromaScale
  }

  private var orbColor: Color {
    OKLCH(displayedLightness, displayedChroma, displayedHue).color()
  }

  private var audioLevel: Double {
    isListening ? min(1.0, meter.averagePower * 2.5) : 0
  }

  /// The currently-highlighted target: user lock wins, then AI intuition.
  private var activeTarget: OrbRingTarget? {
    lockedActionIntegration.map { .integration($0) } ?? intuitedTarget
  }

  // MARK: Body

  var body: some View {
    VStack(spacing: 6) {
      orbField
        .onTapGesture { onCycleMode() }
        .accessibilityLabel("Quill orb, \(mode.rawValue) mode")
        .accessibilityValue(statusAccessibilityLabel)

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
    .animation(.snappy(duration: 0.3), value: status)
    .animation(.snappy(duration: 0.25), value: mode)
    .animation(.snappy(duration: 0.25), value: editMessage != nil)
    .animation(.snappy(duration: 0.25), value: pendingEditResult != nil)
    .animation(.snappy(duration: 0.25), value: partialTranscript.isEmpty)
    .animation(.snappy(duration: 0.25), value: lockedActionIntegration)
    .animation(.snappy(duration: 0.25), value: intuitedTarget)
    .animation(.snappy(duration: 0.3), value: autoDetectedMode)
    .onAppear {
      displayedHue = targetPalette.H
      displayedChroma = targetChroma
      displayedLightness = targetPalette.L
    }
    .onChange(of: targetPalette) { _, palette in
      withAnimation(.easeInOut(duration: 0.6)) {
        displayedHue = OKLCH.nearestEquivalentHue(to: palette.H, from: displayedHue)
        displayedLightness = palette.L
      }
    }
    .onChange(of: targetChroma) { _, chroma in
      withAnimation(.easeInOut(duration: 0.4)) {
        displayedChroma = chroma
      }
    }
    .onChange(of: partialTranscript) { _, text in
      guard isActMode, lockedActionIntegration == nil else { return }
      withAnimation(.easeOut(duration: 0.25)) {
        intuitedTarget = Self.intuitRingTarget(
          from: text,
          integrations: actionIntegrations,
          mcpServers: mcpServerNames
        )
      }
    }
    .onChange(of: mode) { _, newMode in
      if newMode != .action {
        intuitedTarget = nil
      }
    }
    .onChange(of: status) { _, newStatus in
      if newStatus == .idle {
        intuitedTarget = nil
      }
    }
  }

  private var statusAccessibilityLabel: String {
    switch status {
    case .idle: return "idle"
    case .recording: return "listening"
    case .transcribing: return "transcribing"
    case .aiProcessing: return "enhancing"
    }
  }

  // MARK: - Orb field (sphere + effects + backdrop)

  private var orbField: some View {
    let hasRing = isActMode && !actionIntegrations.isEmpty
    let fieldSize: CGFloat = isLive
      ? (hasRing ? OrbSize.fieldWithRing : OrbSize.field)
      : (hasRing ? OrbSize.idleFieldWithRing : OrbSize.idleField)
    return VStack(spacing: 0) {
      ZStack {
        if isActMode, !actionIntegrations.isEmpty {
          satelliteTether
        }
        orbGlow
        pulseRings
        orbMeter
        spinnerArc
        orbCore
        checkMark
        if isActMode, !actionIntegrations.isEmpty {
          satelliteRing
        } else {
          orbParticles
        }
      }
      .scaleEffect(isLive ? 1 : OrbSize.idleScale)
      .frame(width: fieldSize, height: fieldSize)

      orbCaption
    }
    .padding(.horizontal, isLive ? 24 : 12)
    .padding(.vertical, isLive ? 16 : 10)
    .background(orbBackdrop)
  }

  private var orbBackdrop: some View {
    // Quieter at rest: less darkening, softer shadow. The stronger
    // treatment only appears while live, when contrast matters for the
    // transcript text.
    RoundedRectangle(cornerRadius: isLive ? 24 : 18, style: .continuous)
      .fill(.ultraThinMaterial)
      .overlay(
        RoundedRectangle(cornerRadius: isLive ? 24 : 18, style: .continuous)
          .fill(.black.opacity(isLive ? 0.45 : 0.28))
      )
      .overlay(
        RoundedRectangle(cornerRadius: isLive ? 24 : 18, style: .continuous)
          .strokeBorder(.white.opacity(isLive ? 0.12 : 0.08), lineWidth: 1)
      )
      .shadow(color: .black.opacity(isLive ? 0.4 : 0.22), radius: isLive ? 20 : 10, y: isLive ? 8 : 4)
  }

  // MARK: Glow

  private var orbGlow: some View {
    Circle()
      .fill(orbColor)
      .frame(width: OrbSize.core, height: OrbSize.core)
      .blur(radius: OrbSize.glowBlur)
      .opacity(0.6 + audioLevel * 0.4)
  }

  // MARK: Pulse rings

  @ViewBuilder
  private var pulseRings: some View {
    if isListening {
      OrbPulseRing(color: orbColor, audioLevel: audioLevel, delay: 0)
      OrbPulseRing(color: orbColor, audioLevel: audioLevel, delay: 1.1)
    }
  }

  // MARK: Audio-reactive ring meter

  @ViewBuilder
  private var orbMeter: some View {
    if isListening {
      TimelineView(.animation) { timeline in
        let phase = timeline.date.timeIntervalSinceReferenceDate
        OrbMeterRing(phase: phase, level: audioLevel, color: orbColor)
      }
      .frame(width: OrbSize.meterFrame, height: OrbSize.meterFrame)
      .transition(.opacity.animation(.easeIn(duration: 0.25)))
    }
  }

  // MARK: Spinner arc

  @ViewBuilder
  private var spinnerArc: some View {
    if isTranscribing {
      OrbSpinnerArc(color: orbColor)
        .transition(.opacity.animation(.easeIn(duration: 0.25)))
    }
  }

  // MARK: Orb core (the sphere)

  private var orbCore: some View {
    let audioScale: CGFloat = isListening ? 1.0 + CGFloat(audioLevel) * 0.05 : 1.0
    return Circle()
      .fill(
        RadialGradient(
          colors: [
            .white.opacity(0.96),
            .white.opacity(0.6),
            .white.opacity(0.35),
          ],
          center: UnitPoint(x: 0.36, y: 0.30),
          startRadius: 0,
          endRadius: OrbSize.gradientEnd
        )
      )
      .colorMultiply(orbColor)
      .frame(width: OrbSize.core, height: OrbSize.core)
      .overlay(orbSheen)
      .shadow(color: orbColor, radius: 20 + CGFloat(audioLevel) * 30)
      .shadow(color: .white.opacity(0.2), radius: 3, y: -1)
      .scaleEffect(audioScale)
      .modifier(OrbBreathModifier(active: !isLive && !reduceMotion))
      .animation(.interpolatingSpring(stiffness: 280, damping: 14), value: audioLevel)
  }

  private var orbSheen: some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [.white.opacity(0.45), .clear],
          center: UnitPoint(x: 0.70, y: 0.78),
          startRadius: 0,
          endRadius: OrbSize.sheenEnd
        )
      )
  }

  // MARK: Check mark (result phase)

  @ViewBuilder
  private var checkMark: some View {
    if showResult {
      Image(systemName: "checkmark")
        .font(.system(size: 28, weight: .bold))
        .foregroundStyle(QuillDesign.ModePalette.resolved.color())
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
  }

  // MARK: Idle orbit particles

  @ViewBuilder
  private var orbParticles: some View {
    if !isLive {
      OrbIdleParticles(color: orbColor, reduceMotion: reduceMotion)
        .transition(.opacity.animation(.easeOut(duration: 0.45)))
    }
  }

  // MARK: - Caption (below the orb — single transcript location)

  private var orbCaption: some View {
    VStack(spacing: 4) {
      modeBadge
      captionText
      statusLine
    }
    .frame(width: isLive ? 280 : 168)
    .padding(.top, 2)
  }

  @ViewBuilder
  private var modeBadge: some View {
    if isLive {
      HStack(spacing: 7) {
        Circle()
          .fill(orbColor)
          .frame(width: 6, height: 6)
          .shadow(color: orbColor, radius: 4)
        if mode == .auto {
          HStack(spacing: 4) {
            Text("Auto")
              .font(.system(size: 12.5, weight: .semibold))
              .foregroundStyle(.white.opacity(0.6))
            Text("\u{00B7}")
              .font(.system(size: 12.5, weight: .semibold))
              .foregroundStyle(.white.opacity(0.35))
            Text(autoDetectedMode.rawValue)
              .font(.system(size: 12.5, weight: .semibold))
              .foregroundStyle(orbColor)
          }
        } else {
          Text(mode.rawValue)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(orbColor)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .background(
        Capsule()
          .fill(orbColor.opacity(0.2))
          .overlay(Capsule().strokeBorder(orbColor, lineWidth: 1))
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private var captionText: some View {
    Group {
      switch status {
      case .idle:
        if pendingEditResult != nil {
          Text("\u{2713} Edit applied")
            .foregroundStyle(.white.opacity(0.85))
        } else {
          Text(hotkeyHint)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        }
      case .recording:
        if !partialTranscript.isEmpty {
          Text(partialTranscript)
            .foregroundStyle(.white.opacity(0.92))
        } else {
          Text("Listening\u{2026}")
            .foregroundStyle(.white.opacity(0.6))
        }
      case .transcribing:
        Text("Transcribing\u{2026}")
          .foregroundStyle(.white.opacity(0.6))
      case .aiProcessing:
        Text("Enhancing\u{2026}")
          .foregroundStyle(.white.opacity(0.6))
      }
    }
    .font(.system(size: 14, weight: .medium))
    .lineLimit(3)
    .multilineTextAlignment(.center)
    .frame(minHeight: 20)
    .animation(.easeOut(duration: 0.22), value: partialTranscript)
  }

  private var statusLine: some View {
    Group {
      switch status {
      case .idle:
        Text("")
      case .recording:
        if let startTime = recordingStartTime {
          TimelineView(.periodic(from: startTime, by: 1.0)) { ctx in
            let elapsed = max(0, ctx.date.timeIntervalSince(startTime))
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            Text("listening\u{2026} \(String(format: "%d:%02d", mins, secs))")
          }
        } else {
          Text("listening\u{2026}")
        }
      case .transcribing:
        Text("transcribing\u{2026}")
      case .aiProcessing:
        Text("enhancing\u{2026}")
      }
    }
    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
    .tracking(0.4)
    .foregroundStyle(.white.opacity(0.5))
    .frame(height: 14)
  }

  // MARK: - Act-mode satellite ring

  /// Cap the ring at 6 tiles so it stays legible as the integration +
  /// MCP catalog grows — extras collapse into a "+N" overflow tile. The
  /// active target (locked or intuited) is always swapped into view.
  private static let maxVisibleSatellites = 6

  /// Integrations + enabled MCP servers, in one branded ring.
  private var allSatellites: [OrbRingTarget] {
    actionIntegrations.map { .integration($0) } + mcpServerNames.map { .mcp($0) }
  }

  private var visibleSatellites: [OrbRingTarget] {
    let all = allSatellites
    guard all.count > Self.maxVisibleSatellites + 1 else { return all }
    var visible = Array(all.prefix(Self.maxVisibleSatellites))
    if let target = activeTarget, !visible.contains(target), all.contains(target) {
      visible[visible.count - 1] = target
    }
    return visible
  }

  private var overflowSatelliteCount: Int {
    max(0, allSatellites.count - visibleSatellites.count)
  }

  private var satelliteRing: some View {
    let visible = visibleSatellites
    let overflow = overflowSatelliteCount
    let total = visible.count + (overflow > 0 ? 1 : 0)
    return ZStack {
      ForEach(Array(visible.enumerated()), id: \.element) { index, target in
        OrbSatelliteTile(
          target: target,
          isTarget: activeTarget == target,
          index: index,
          total: total,
          radius: OrbSize.satelliteRingRadius,
          onTap: {
            // Tap-to-lock only applies to integrations — the lock
            // overrides the parsed intent's target, which has no MCP
            // equivalent (the confirmation panel stays the arbiter).
            if case .integration(let id) = target {
              onToggleActionIntegration(id)
            }
          }
        )
      }
      if overflow > 0 {
        let angle = Self.satelliteAngle(index: visible.count, total: total)
        Text("+\(overflow)")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white.opacity(0.6))
          .frame(width: OrbSize.satelliteTileSize, height: OrbSize.satelliteTileSize)
          .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(Color.white.opacity(0.06))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
          )
          .offset(
            x: OrbSize.satelliteRingRadius * cos(angle),
            y: OrbSize.satelliteRingRadius * sin(angle)
          )
          .help("\(overflow) more connected — say the name to target them")
      }
    }
    .transition(.opacity.animation(.easeOut(duration: 0.35)))
  }

  private var satelliteTether: some View {
    let satellites = visibleSatellites
    let overflow = overflowSatelliteCount
    let total = satellites.count + (overflow > 0 ? 1 : 0)
    return Canvas { context, size in
      guard let target = activeTarget,
            let index = satellites.firstIndex(of: target)
      else { return }
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let angle = Self.satelliteAngle(index: index, total: total)
      let dest = CGPoint(
        x: center.x + OrbSize.satelliteRingRadius * cos(angle),
        y: center.y + OrbSize.satelliteRingRadius * sin(angle)
      )
      var path = Path()
      path.move(to: center)
      path.addLine(to: dest)
      context.stroke(
        path,
        with: .color(target.accentColor.opacity(0.6)),
        style: StrokeStyle(lineWidth: 1.5, dash: [3, 4])
      )
    }
    .allowsHitTesting(false)
    .animation(.easeOut(duration: 0.3), value: activeTarget)
  }

  // MARK: - Destination classifier

  /// Legacy integration-only entry point (used by the Corner Bloom's
  /// destination rows). New callers use `intuitRingTarget`.
  static func intuitTarget(
    from text: String,
    integrations: [Integration.Identifier]
  ) -> Integration.Identifier? {
    if case .integration(let id) = intuitRingTarget(from: text, integrations: integrations, mcpServers: []) {
      return id
    }
    return nil
  }

  /// Scans the live transcript for a destination. Explicit MCP server
  /// names beat integration keywords (a name mention is the strongest
  /// possible signal); integration priority order is unchanged.
  static func intuitRingTarget(
    from text: String,
    integrations: [Integration.Identifier],
    mcpServers: [String]
  ) -> OrbRingTarget? {
    guard !text.isEmpty else { return nil }
    let lowered = " " + text.lowercased() + " "

    for server in mcpServers {
      let name = server.lowercased().trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { continue }
      if lowered.contains(" \(name) ") || lowered.contains(" \(name),") || lowered.contains(" \(name).") {
        return .mcp(server)
      }
    }

    let priority: [Integration.Identifier] = [
      .todoist, .gmail, .googleCalendar, .appleReminders, .calendar,
      .notion, .things, .slack, .linear,
    ]
    for id in priority {
      guard integrations.contains(id) else { continue }
      let integration = Integration.all.first { $0.identifier == id }
      guard let keywords = integration?.intuitKeywords else { continue }
      for kw in keywords {
        if lowered.contains(kw) { return .integration(id) }
      }
    }
    return nil
  }

  static func satelliteAngle(index: Int, total: Int) -> CGFloat {
    let startAngle = -CGFloat.pi / 2 // top
    return startAngle + CGFloat(index) * (2 * .pi / CGFloat(total))
  }

  // MARK: - Edit acceptance pill (reused)

  private var editAcceptancePill: some View {
    HStack(spacing: 2) {
      Button {
        onEditUndo()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
          Text("Reject")
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.white.opacity(0.08))
        )
      }
      .buttonStyle(.plain)

      Button {
        onEditAccept()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
          Text("Keep")
            .font(.system(size: 11, weight: .semibold))
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.white.opacity(0.25))
            .frame(width: 14, height: 14)
            .overlay(
              Image(systemName: "return")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
            )
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.green)
        )
      }
      .buttonStyle(.plain)
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.black.opacity(0.7))
    )
  }
}

// MARK: - Breathing animation modifier

private struct OrbBreathModifier: ViewModifier {
  let active: Bool
  @State private var breathing = false

  func body(content: Content) -> some View {
    content
      .scaleEffect(active && breathing ? 1.045 : 1.0)
      .onAppear {
        guard active else { return }
        withAnimation(.easeInOut(duration: 2.3).repeatForever(autoreverses: true)) {
          breathing = true
        }
      }
      .onChange(of: active) { _, newValue in
        if newValue {
          withAnimation(.easeInOut(duration: 2.3).repeatForever(autoreverses: true)) {
            breathing = true
          }
        } else {
          withAnimation(.easeOut(duration: 0.3)) {
            breathing = false
          }
        }
      }
  }
}

// MARK: - Pulse ring

private struct OrbPulseRing: View {
  let color: Color
  let audioLevel: Double
  let delay: Double

  @State private var animating = false

  var body: some View {
    Circle()
      .strokeBorder(color, lineWidth: 1.5)
      .frame(width: OrbSize.core, height: OrbSize.core)
      .scaleEffect(animating ? 2.1 : 1.0)
      .opacity(animating ? 0 : 0.5 + audioLevel * 0.3)
      .onAppear {
        withAnimation(
          .easeOut(duration: 2.2)
          .repeatForever(autoreverses: false)
          .delay(delay)
        ) {
          animating = true
        }
      }
  }
}

// MARK: - Audio-reactive ring meter (~44 bars)

private struct OrbMeterRing: View {
  let phase: Double
  let level: Double
  let color: Color

  private let barCount = 44

  var body: some View {
    ZStack {
      ForEach(0..<barCount, id: \.self) { i in
        OrbMeterBar(
          index: i,
          total: barCount,
          phase: phase,
          level: level,
          radius: OrbSize.meterRadius,
          color: color
        )
      }
    }
  }
}

private struct OrbMeterBar: View {
  let index: Int
  let total: Int
  let phase: Double
  let level: Double
  let radius: CGFloat
  let color: Color

  @State private var multiplier: Double = 1.0

  var body: some View {
    let angle = Double(index) * (360.0 / Double(total))
    let local = 0.5 + 0.5 * sin(phase * 0.12 + Double(index) * 0.5)
    let h = 5.0 + level * 18.0 * (0.35 + 0.65 * local) * multiplier
    let scaleY = h / 6.0

    RoundedRectangle(cornerRadius: 3)
      .fill(color)
      .frame(width: 2, height: 6)
      .scaleEffect(y: scaleY, anchor: .bottom)
      .opacity(0.5 + level * 0.5)
      .offset(y: -radius)
      .rotationEffect(.degrees(angle))
      .onAppear {
        multiplier = 0.6 + Double.random(in: 0...0.8)
      }
  }
}

// MARK: - Spinner arc (transcribing)

private struct OrbSpinnerArc: View {
  let color: Color
  @State private var rotation: Double = 0

  var body: some View {
    Circle()
      .trim(from: 0, to: 0.25)
      .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
      .frame(width: OrbSize.arcFrame, height: OrbSize.arcFrame)
      .rotationEffect(.degrees(rotation))
      .overlay(
        Circle()
          .stroke(color.opacity(0.2), lineWidth: 2.5)
          .frame(width: OrbSize.arcFrame, height: OrbSize.arcFrame)
      )
      .onAppear {
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
          rotation = 360
        }
      }
  }
}

// MARK: - Idle ambient particles (tilted elliptical orbits)

private struct OrbIdleParticles: View {
  let color: Color
  let reduceMotion: Bool

  private let specs: [(radius: CGFloat, tilt: Double, duration: Double, size: CGFloat, reverse: Bool)] = [
    (50, 18, 8, 3.5, false),
    (62, -26, 12, 2.5, true),
    (54, 62, 10, 3.0, false),
    (68, 116, 15, 2.2, true),
    (48, -68, 9, 3.2, false),
    (64, 150, 13, 2.0, false),
  ]

  var body: some View {
    ZStack {
      ForEach(Array(specs.enumerated()), id: \.offset) { index, spec in
        OrbParticle(
          orbitRadius: spec.radius,
          tilt: spec.tilt,
          duration: reduceMotion ? spec.duration * 2.5 : spec.duration,
          size: spec.size,
          reverse: spec.reverse,
          delayIndex: index,
          color: color,
          reduceMotion: reduceMotion
        )
      }
    }
  }
}

private struct OrbParticle: View {
  let orbitRadius: CGFloat
  let tilt: Double
  let duration: Double
  let size: CGFloat
  let reverse: Bool
  let delayIndex: Int
  let color: Color
  let reduceMotion: Bool

  @State private var orbitAngle: Double = 0
  @State private var twinkleOpacity: Double = 0.5

  var body: some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [.white, color],
          center: UnitPoint(x: 0.4, y: 0.35),
          startRadius: 0,
          endRadius: size
        )
      )
      .frame(width: size, height: size)
      .shadow(color: color, radius: 4)
      .opacity(reduceMotion ? 0.7 : twinkleOpacity)
      .offset(x: orbitRadius)
      .rotationEffect(.degrees(orbitAngle))
      .scaleEffect(x: 1, y: 0.5)
      .rotationEffect(.degrees(tilt))
      .onAppear {
        let initialAngle = Double(delayIndex) * 60.0
        orbitAngle = initialAngle
        withAnimation(
          .linear(duration: duration)
          .repeatForever(autoreverses: false)
        ) {
          orbitAngle = initialAngle + (reverse ? -360 : 360)
        }
        if !reduceMotion {
          withAnimation(
            .easeInOut(duration: 1.7)
            .repeatForever(autoreverses: true)
            .delay(Double(delayIndex) * 0.4)
          ) {
            twinkleOpacity = 1.0
          }
        }
      }
  }
}

// MARK: - Satellite targets (integration OR MCP server)

/// One tile on the Act-mode ring. Integrations keep their satellite hue
/// and tap-to-lock; MCP servers get their directory branding (or a
/// neutral steel tone for unknown servers) and highlight from intuition.
enum OrbRingTarget: Hashable {
  case integration(Integration.Identifier)
  case mcp(String)

  var connection: ConnectionTarget {
    switch self {
    case .integration(let id): .integration(id)
    case .mcp(let name): .mcpServer(name)
    }
  }

  var accentColor: Color {
    switch self {
    case .integration(let id):
      let hue = Integration.all.first { $0.identifier == id }?.satelliteHue ?? 200
      return Color(hue: hue / 360.0, saturation: 0.6, brightness: 0.85)
    case .mcp:
      if let hex = connection.tintHex, let color = Color(hex: hex) {
        return color
      }
      return Color(hue: 220 / 360.0, saturation: 0.25, brightness: 0.75)
    }
  }
}

// MARK: - Satellite tile (Act-mode ring button)

private struct OrbSatelliteTile: View {
  let target: OrbRingTarget
  let isTarget: Bool
  let index: Int
  let total: Int
  let radius: CGFloat
  let onTap: () -> Void

  private var accentColor: Color { target.accentColor }

  private var angle: CGFloat {
    OrbView.satelliteAngle(index: index, total: total)
  }

  var body: some View {
    let x = radius * cos(angle)
    let y = radius * sin(angle)
    Button(action: onTap) {
      Image(systemName: target.connection.systemImage)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(isTarget ? .white : .white.opacity(0.7))
        .frame(width: OrbSize.satelliteTileSize, height: OrbSize.satelliteTileSize)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isTarget ? accentColor : Color.white.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(
              isTarget ? accentColor : Color.white.opacity(0.15),
              lineWidth: 1
            )
        )
        .shadow(
          color: isTarget ? accentColor.opacity(0.6) : .clear,
          radius: isTarget ? 10 : 0
        )
        .scaleEffect(isTarget ? 1.16 : 1.0)
    }
    .buttonStyle(.plain)
    .offset(x: x, y: y)
    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isTarget)
    .accessibilityLabel("Send to \(target.connection.displayName)")
  }
}

// MARK: - Preview

#Preview("Orb States") {
  VStack(spacing: 30) {
    OrbView(
      status: .idle, mode: .dictate,
      meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold \u{2325} Space to dictate",
      onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
    )
  }
  .frame(width: 400, height: 400)
  .background(.black)
}
