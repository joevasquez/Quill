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

private enum OrbHue {
  static let dictate: Double = 248
  static let edit: Double = 305
  static let action: Double = 188
  static let success: Double = 150
}

private extension TranscriptionIndicatorView.Mode {
  var orbHue: Double {
    switch self {
    case .dictate: return OrbHue.dictate
    case .edit:    return OrbHue.edit
    case .action:  return OrbHue.action
    }
  }
}

// MARK: - Size constants

private enum OrbSize {
  static let core: CGFloat = 81
  static let field: CGFloat = 160
  static let fieldWithRing: CGFloat = 220
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
  var lockedActionIntegration: Integration.Identifier?
  var isPinnedToTop: Bool = false
  var onCycleMode: () -> Void
  var onEditAccept: () -> Void
  var onEditUndo: () -> Void
  var onToggleActionIntegration: (Integration.Identifier) -> Void = { _ in }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var displayedHue: Double = OrbHue.dictate
  @State private var displayedSaturation: Double = 0.5
  @State private var intuitedTarget: Integration.Identifier?

  private var isLive: Bool { status != .idle }
  private var isListening: Bool { status == .recording }
  private var isTranscribing: Bool { status == .transcribing || status == .aiProcessing }

  private var isActMode: Bool { mode == .action }

  private var showResult: Bool {
    status == .idle && pendingEditResult != nil
  }

  private var targetHue: Double {
    showResult ? OrbHue.success : mode.orbHue
  }

  private var targetSaturation: Double {
    isLive ? 0.75 : 0.5
  }

  private var orbColor: Color {
    Color(hue: displayedHue / 360.0, saturation: displayedSaturation, brightness: 0.9)
  }

  private var audioLevel: Double {
    isListening ? min(1.0, meter.averagePower * 2.5) : 0
  }

  /// The currently-highlighted integration: user lock wins, then AI intuition.
  private var activeTarget: Integration.Identifier? {
    lockedActionIntegration ?? intuitedTarget
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
    .onAppear {
      displayedHue = targetHue
      displayedSaturation = targetSaturation
    }
    .onChange(of: targetHue) { _, newHue in
      withAnimation(.easeInOut(duration: 0.6)) {
        displayedHue = newHue
      }
    }
    .onChange(of: targetSaturation) { _, newSat in
      withAnimation(.easeInOut(duration: 0.4)) {
        displayedSaturation = newSat
      }
    }
    .onChange(of: partialTranscript) { _, text in
      guard isActMode, lockedActionIntegration == nil else { return }
      withAnimation(.easeOut(duration: 0.25)) {
        intuitedTarget = Self.intuitTarget(from: text, integrations: actionIntegrations)
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
    let fieldSize = isActMode && !actionIntegrations.isEmpty ? OrbSize.fieldWithRing : OrbSize.field
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
      .frame(width: fieldSize, height: fieldSize)

      orbCaption
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .background(orbBackdrop)
  }

  private var orbBackdrop: some View {
    RoundedRectangle(cornerRadius: 24, style: .continuous)
      .fill(.ultraThinMaterial)
      .overlay(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(.black.opacity(0.45))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .strokeBorder(.white.opacity(0.12), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
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
        .foregroundStyle(Color(hue: OrbHue.success / 360.0, saturation: 0.6, brightness: 0.9))
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
    VStack(spacing: 6) {
      modeBadge
      captionText
      statusLine
    }
    .frame(width: 300)
    .padding(.top, 4)
  }

  @ViewBuilder
  private var modeBadge: some View {
    if isLive {
      HStack(spacing: 7) {
        Circle()
          .fill(orbColor)
          .frame(width: 6, height: 6)
          .shadow(color: orbColor, radius: 4)
        Text(mode.rawValue)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(orbColor)
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
            .foregroundStyle(.white.opacity(0.6))
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

  private var satelliteRing: some View {
    let integrations = Array(actionIntegrations.prefix(9))
    return ZStack {
      ForEach(Array(integrations.enumerated()), id: \.element) { index, id in
        OrbSatelliteTile(
          identifier: id,
          isTarget: activeTarget == id,
          index: index,
          total: integrations.count,
          radius: OrbSize.satelliteRingRadius,
          onTap: { onToggleActionIntegration(id) }
        )
      }
    }
    .transition(.opacity.animation(.easeOut(duration: 0.35)))
  }

  private var satelliteTether: some View {
    let integrations = Array(actionIntegrations.prefix(9))
    return Canvas { context, size in
      guard let target = activeTarget,
            let index = integrations.firstIndex(of: target)
      else { return }
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let angle = Self.satelliteAngle(index: index, total: integrations.count)
      let dest = CGPoint(
        x: center.x + OrbSize.satelliteRingRadius * cos(angle),
        y: center.y + OrbSize.satelliteRingRadius * sin(angle)
      )
      let integration = Integration.all.first { $0.identifier == target }
      let hue = integration?.satelliteHue ?? 200
      let color = Color(hue: hue / 360.0, saturation: 0.6, brightness: 0.85)
      var path = Path()
      path.move(to: center)
      path.addLine(to: dest)
      context.stroke(
        path,
        with: .color(color.opacity(0.6)),
        style: StrokeStyle(lineWidth: 1.5, dash: [3, 4])
      )
    }
    .allowsHitTesting(false)
    .animation(.easeOut(duration: 0.3), value: activeTarget)
  }

  // MARK: - Destination classifier

  static func intuitTarget(
    from text: String,
    integrations: [Integration.Identifier]
  ) -> Integration.Identifier? {
    guard !text.isEmpty else { return nil }
    let lowered = " " + text.lowercased() + " "
    let priority: [Integration.Identifier] = [
      .todoist, .gmail, .googleCalendar, .appleReminders, .calendar,
      .notion, .things, .slack, .linear,
    ]
    for id in priority {
      guard integrations.contains(id) else { continue }
      let integration = Integration.all.first { $0.identifier == id }
      guard let keywords = integration?.intuitKeywords else { continue }
      for kw in keywords {
        if lowered.contains(kw) { return id }
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

// MARK: - Satellite tile (Act-mode integration button)

private struct OrbSatelliteTile: View {
  let identifier: Integration.Identifier
  let isTarget: Bool
  let index: Int
  let total: Int
  let radius: CGFloat
  let onTap: () -> Void

  private var integration: Integration? {
    Integration.all.first { $0.identifier == identifier }
  }

  private var accentColor: Color {
    let hue = integration?.satelliteHue ?? 200
    return Color(hue: hue / 360.0, saturation: 0.6, brightness: 0.85)
  }

  private var angle: CGFloat {
    OrbView.satelliteAngle(index: index, total: total)
  }

  var body: some View {
    let x = radius * cos(angle)
    let y = radius * sin(angle)
    Button(action: onTap) {
      Image(systemName: integration?.systemImage ?? "questionmark.circle")
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
    .accessibilityLabel("Send to \(integration?.name ?? identifier.rawValue)")
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
