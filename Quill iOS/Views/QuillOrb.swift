//
//  QuillOrb.swift
//  Quill iOS
//
//  The hero control. A feather at rest; on capture it morphs (ink-drop)
//  into a glowing sphere whose colour is the mode and whose glow and meter
//  track the real mic level. A green pulse confirms completion.
//
//  Mode is the hue, state is the motion — the same idea as the macOS orb,
//  drawing from the same QuillDesign palette.
//
//  This view is deliberately ignorant of modes and recording: callers hand
//  it a palette and a phase. Everything animates off those two inputs.
//

import HexCore
import SwiftUI

struct QuillOrb: View {
  enum Phase {
    case idle
    case listening
    case transcribing
    case result
  }

  /// The active mode's colour. Ignored while `phase == .result`, which
  /// always shows the resolved green.
  var palette: OKLCH
  var phase: Phase = .idle
  var size: CGFloat = QuillDesign.OrbSize.focal
  /// Real mic level, 0...1 — drives the glow radius and the meter bars.
  var level: Double = 0
  /// Multiplier on the glow radius, for surfaces that want more or less bloom.
  var glow: Double = 1

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var breathing = false
  @State private var displayedLevel: Double = 0
  @State private var popTrigger = 0

  private var isLive: Bool { phase != .idle }
  private var isListening: Bool { phase == .listening }

  /// The colour actually being rendered — resolved green wins over the mode.
  private var active: OKLCH {
    phase == .result ? QuillDesign.ModePalette.resolved : palette
  }

  /// The at-rest disc and glyph sit above the spec's 0.07 idle chroma:
  /// at these sizes 0.07 reads as grey, and the prototype's own resting
  /// orb uses these values.
  private var discTint: OKLCH { OKLCH(palette.L, 0.11, palette.H) }
  private var glyphTint: OKLCH { OKLCH(palette.L, 0.14, palette.H) }

  /// CSS `radial-gradient(circle at 36% 30%, …)` defaults to
  /// farthest-corner: from (0.36, 0.30) that's the bottom-right, at
  /// √(0.64² + 0.70²) ≈ 0.9485 of the box.
  private var gradientRadius: CGFloat { size * 0.9485 }

  /// Glow grows from a constant base with the mic level.
  private var glowRadius: CGFloat {
    size * 0.13 + size * 0.6 * displayedLevel * glow
  }

  var body: some View {
    ZStack {
      idleDisc
      if isListening && !reduceMotion { ripples }
      sphere
      if isListening { meter }
      feather
    }
    .frame(width: size, height: size)
    .contentShape(Circle())
    .onAppear { breathing = true }
    .onChange(of: level) { _, newLevel in
      // The recorder publishes per-buffer; ease between samples so the
      // glow and bars don't step.
      withAnimation(.linear(duration: 0.12)) {
        displayedLevel = isListening ? newLevel : 0
      }
    }
    .onChange(of: isListening) { _, listening in
      withAnimation(.linear(duration: 0.12)) {
        displayedLevel = listening ? level : 0
      }
    }
    .onChange(of: phase) { _, newPhase in
      if newPhase == .result, !reduceMotion { popTrigger += 1 }
    }
  }

  // MARK: - Layers

  /// The tinted disc behind the resting feather. Breathes; fades out on
  /// capture as the sphere takes over.
  private var idleDisc: some View {
    Circle()
      .fill(
        RadialGradient(
          gradient: Gradient(colors: [discTint.color(0.24), discTint.color(0)]),
          center: UnitPoint(x: 0.5, y: 0.45),
          startRadius: 0,
          endRadius: size * 0.7
        )
      )
      .scaleEffect(breathing && !isLive && !reduceMotion ? 1.06 : 1)
      .opacity(isLive ? 0 : (breathing && !reduceMotion ? 1 : 0.82))
      .animation(
        (isLive || reduceMotion)
          ? nil
          : .easeInOut(duration: 4.8).repeatForever(autoreverses: true),
        value: breathing
      )
      .animation(morph, value: isLive)
  }

  /// Two rings expanding out of the orb while it listens.
  private var ripples: some View {
    TimelineView(.animation) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      ZStack {
        ForEach(0..<2, id: \.self) { i in
          // 2s cycle, the second ring staggered 1s behind the first.
          let raw = ((t + Double(i)).truncatingRemainder(dividingBy: 2)) / 2
          let eased = 1 - pow(1 - raw, 2)  // ease-out
          Circle()
            .strokeBorder(active.color(0.5), lineWidth: max(1, size * 0.012))
            .padding(size * 0.06)
            .scaleEffect(0.7 + 0.8 * eased)
            .opacity(0.6 * (1 - eased))
        }
      }
    }
  }

  /// The orb proper. Scales up out of nothing as the feather drops in.
  private var sphere: some View {
    Circle()
      .fill(
        RadialGradient(
          gradient: QuillDesign.orbGradient(active),
          center: UnitPoint(x: 0.36, y: 0.30),
          startRadius: 0,
          endRadius: gradientRadius
        )
      )
      // CSS blur radius is roughly twice SwiftUI's.
      .shadow(color: active.color(0.6), radius: glowRadius / 2)
      .shadow(color: active.color(0.5), radius: glowRadius * 0.4 / 2)
      .scaleEffect(isLive ? 1 : 0.35)
      .opacity(isLive ? 1 : 0)
      .keyframeAnimator(initialValue: 1.0, trigger: popTrigger) { view, scale in
        view.scaleEffect(scale)
      } keyframes: { _ in
        // Resolve pop: 1 → 1.12 → 1 over .5s.
        CubicKeyframe(1.12, duration: 0.225)
        CubicKeyframe(1.0, duration: 0.275)
      }
      .animation(morph, value: isLive)
      .animation(.easeInOut(duration: 0.3), value: active)
  }

  /// Four bars over the sphere, riding the mic level.
  private var meter: some View {
    let barWidth = max(2, size * 0.05)
    let barHeight = size * 0.4
    let gap = size * 0.035

    return TimelineView(.animation) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: gap) {
        ForEach(0..<4, id: \.self) { i in
          Capsule()
            .fill(.white)
            .frame(width: barWidth, height: barHeight)
            .scaleEffect(y: barScale(index: i, t: t), anchor: .center)
        }
      }
      .frame(height: barHeight)
    }
    .transition(.opacity)
  }

  /// Bars idle at a low floor and swell with the level, phase-offset from
  /// each other so they read as a waveform rather than a level meter.
  private func barScale(index: Int, t: TimeInterval) -> Double {
    guard !reduceMotion else { return 0.28 + displayedLevel * 0.7 }
    let wave = 0.5 + 0.5 * sin(t * 13.2 + Double(index) * 0.95)
    return 0.28 + displayedLevel * (0.4 + 0.9 * wave)
  }

  /// The brand mark at rest — the same asset as the wordmark. Drops and
  /// shrinks into the orb on capture (the "ink-drop").
  private var feather: some View {
    Image("Feather")
      .resizable()
      .renderingMode(.template)
      .aspectRatio(contentMode: .fit)
      .foregroundStyle(glyphTint.color())
      .frame(width: size * 0.5, height: size * 0.5)
      .rotationEffect(.degrees(isLive ? -12 : 0))
      .scaleEffect(isLive ? 0.42 : 1)
      .offset(y: isLive ? size * 0.08 : 0)
      .opacity(isLive ? 0 : 1)
      .animation(morph, value: isLive)
  }

  /// The ink-drop spring — an overshoot on the way in. Reduce Motion gets
  /// a plain crossfade instead.
  private var morph: Animation {
    reduceMotion
      ? .easeInOut(duration: 0.2)
      : .spring(response: 0.4, dampingFraction: 0.62)
  }
}

#Preview("Phases") {
  VStack(spacing: 32) {
    HStack(spacing: 24) {
      QuillOrb(palette: QuillDesign.ModePalette.auto, phase: .idle, size: 92)
      QuillOrb(palette: QuillDesign.ModePalette.dictate, phase: .listening, size: 92, level: 0.7)
      QuillOrb(palette: QuillDesign.ModePalette.act, phase: .transcribing, size: 92)
      QuillOrb(palette: QuillDesign.ModePalette.edit, phase: .result, size: 92)
    }
    HStack(spacing: 24) {
      ForEach(
        [
          QuillDesign.ModePalette.auto, QuillDesign.ModePalette.dictate,
          QuillDesign.ModePalette.edit, QuillDesign.ModePalette.act,
        ], id: \.H
      ) { p in
        QuillOrb(palette: p, phase: .idle, size: 60)
      }
    }
  }
  .padding(40)
}
