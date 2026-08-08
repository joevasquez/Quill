//
//  QuillOwlAvatar.swift
//  Quill iOS
//
//  The owl from the macOS "Owl avatar view mode", rendered on iOS. The
//  sprite itself lives in HexCore (`QuillOwlSprite`) and is shared verbatim
//  — this file is only the iOS chrome around it, the counterpart to
//  `OwlView`'s `avatarCard` on the Mac (whose card, drag handle, and mode
//  pill are all AppKit-bound and don't come along).
//
//  Sizing rule: pass a `size` that is a whole multiple of the 48 px sprite.
//  The static layers are rasterized crisply, but the ~60 dynamic rects are
//  filled per frame at `unit` points each — a fractional unit lands them off
//  the pixel grid and the ink, pupils, and sparkles shimmer against the
//  layers behind them. `Size` holds the two that fit iOS's orb slots.
//

import HexCore
import SwiftUI

struct QuillOwlAvatar: View {
  /// Sizes that keep one sprite pixel on a whole number of points. Chosen to
  /// sit in the slots the orb already occupies (focal 92, trigger 46).
  enum Size {
    /// 2 pt per sprite pixel — the capture sheet's hero.
    static let focal: CGFloat = 96
    /// 1 pt per sprite pixel — the home trigger button.
    static let trigger: CGFloat = 48
  }

  /// Canvas pixels per sprite pixel in the rasterized layers. 3 matches the
  /// Mac and covers both 2× and 3× iPhone displays.
  private static let spriteScale = 3

  var mode: OwlSpriteMode
  /// Drives the owl's accent — hat band, progress bar, caret.
  var accent: OKLCH
  var size: CGFloat = Size.focal

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The three static layers, rasterized once per accent. Rebuilding these
  /// walks 2 × 48² + 16 × 9 cells, so they must not be made per frame.
  @State private var layers: QuillOwlSprite.Layers?
  /// One monotonic clock, started at mount and never reset on a mode change:
  /// each state loops on its own period, so a shared clock keeps the motion
  /// continuous through the cut. (Same rule as the Mac — see OwlView.)
  @State private var mountedAt = Date()

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let elapsed = context.date.timeIntervalSince(mountedAt)
      let sprite = layers
      let colors = QuillOwlSprite.DynamicColors(accent: accent.color())
      Canvas { gfx, canvasSize in
        guard let sprite else { return }
        QuillOwlSprite.draw(
          in: gfx,
          unit: canvasSize.width / CGFloat(QuillOwlSprite.spriteSize),
          t: elapsed,
          mode: mode,
          layers: sprite,
          colors: colors
        )
      }
      .frame(width: size, height: size)
    }
    .onAppear { rebuildLayers() }
    .onChange(of: accent) { _, _ in rebuildLayers() }
    .accessibilityElement()
    .accessibilityLabel("Quill owl")
    .accessibilityValue(stateDescription)
  }

  private func rebuildLayers() {
    layers = QuillOwlSprite.makeLayers(accent: accent, scale: Self.spriteScale)
  }

  private var stateDescription: String {
    switch mode {
    case .ready:   "waiting"
    case .writing: "listening"
    case .working: "thinking"
    }
  }
}

#Preview("Owl states") {
  VStack(spacing: 20) {
    QuillOwlAvatar(mode: .ready, accent: QuillDesign.ModePalette.auto)
    QuillOwlAvatar(mode: .writing, accent: QuillDesign.ModePalette.dictate)
    QuillOwlAvatar(mode: .working, accent: QuillDesign.ModePalette.act)
    QuillOwlAvatar(mode: .ready, accent: QuillDesign.ModePalette.auto, size: QuillOwlAvatar.Size.trigger)
  }
  .padding(40)
}
