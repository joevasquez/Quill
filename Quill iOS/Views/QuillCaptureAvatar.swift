//
//  QuillCaptureAvatar.swift
//  Quill iOS
//
//  The one place that answers "orb or owl?". Both capture surfaces (the
//  capture sheet's hero and the home trigger button) render through this so
//  the setting can't be honoured in one and forgotten in the other.
//
//  It takes the orb's vocabulary — palette + phase + level — because that's
//  what the callers already speak, and maps it onto the owl's three states.
//

import HexCore
import SwiftUI

struct QuillCaptureAvatar: View {
  /// Slot this avatar is filling. Each style has its own correct size for a
  /// given slot: the orb's are tuned by the design tokens, the owl's have to
  /// land on a whole number of points per sprite pixel (see QuillOwlAvatar).
  enum Slot {
    /// The capture sheet's hero.
    case focal
    /// The home screen's record button.
    case trigger
    /// The note composer's inline record button — a 48 pt ring. The owl's
    /// smallest legible size is also 48 pt (one point per sprite pixel), so
    /// it would fill the ring edge to edge with no margin. `owlSize` is nil
    /// here and this slot always draws the orb, whatever the setting says.
    case inlineTrigger

    var orbSize: CGFloat {
      switch self {
      case .focal:         QuillDesign.OrbSize.focal
      case .trigger:       QuillDesign.OrbSize.trigger
      case .inlineTrigger: QuillDesign.OrbSize.composer - 2
      }
    }

    var owlSize: CGFloat? {
      switch self {
      case .focal:         QuillOwlAvatar.Size.focal
      case .trigger:       QuillOwlAvatar.Size.trigger
      case .inlineTrigger: nil
      }
    }
  }

  var palette: OKLCH
  var phase: QuillOrb.Phase = .idle
  var slot: Slot = .focal
  var level: Double = 0
  var glow: Double = 1

  @AppStorage(QuillIOSSettingsKey.captureAvatar)
  private var avatarStyleRaw = QuillIOSSettingsKey.defaultCaptureAvatarValue

  private var style: QuillCaptureAvatarStyle {
    QuillCaptureAvatarStyle(rawValue: avatarStyleRaw) ?? .orb
  }

  var body: some View {
    if style == .owl, let owlSize = slot.owlSize {
      QuillOwlAvatar(mode: Self.owlMode(for: phase), accent: owlAccent, size: owlSize)
    } else {
      QuillOrb(palette: palette, phase: phase, size: slot.orbSize, level: level, glow: glow)
    }
  }

  /// The owl has no "resolved green" state of its own — it goes back to
  /// waiting — so completion is carried by the accent instead, matching how
  /// the orb signals it.
  private var owlAccent: OKLCH {
    phase == .result ? QuillDesign.ModePalette.resolved : palette
  }

  /// Capture phase → what the owl is doing. `.result` maps to `.ready`: the
  /// work is finished, so the owl puts the quill down.
  private static func owlMode(for phase: QuillOrb.Phase) -> OwlSpriteMode {
    switch phase {
    case .idle:         .ready
    case .listening:    .writing
    case .transcribing: .working
    case .result:       .ready
    }
  }

  /// Whether `slot` draws the owl for this setting. Buttons use it to pick
  /// their chip shape, so a slot that falls back to the orb (the note
  /// composer) keeps its circle.
  ///
  /// Pure on purpose: callers must pass a value they read through
  /// `@AppStorage`, or their chrome won't redraw when the setting flips and
  /// you get a squared owl inside a circular chip.
  static func showsOwl(styleRaw: String, in slot: Slot) -> Bool {
    QuillCaptureAvatarStyle(rawValue: styleRaw) == .owl && slot.owlSize != nil
  }
}

/// The shape a capture button wears.
///
/// The orb is a sphere and wants a circle. The owl is a 48 px sprite with a
/// flat base and square shoulders — in a circle it reads as cropped — so owl
/// mode squares the button off. The keyboard button beside it uses the same
/// shape so the pair stays a set rather than a circle next to a squircle.
///
/// `InsettableShape` because these buttons draw a `strokeBorder` ring.
struct QuillCaptureChipShape: InsettableShape {
  var isSquared: Bool
  /// Corner radius as a fraction of the button's side — a squircle tracing
  /// its own size rather than a fixed step off the `Radius` scale. Slightly
  /// softer than an app icon's ~0.224.
  var cornerFraction: CGFloat = 0.28
  /// Private, so the synthesized memberwise init is private too — hence the
  /// explicit one below.
  private var insetAmount: CGFloat = 0

  init(isSquared: Bool, cornerFraction: CGFloat = 0.28) {
    self.isSquared = isSquared
    self.cornerFraction = cornerFraction
  }

  func path(in rect: CGRect) -> Path {
    let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
    guard isSquared else { return Circle().path(in: r) }
    return RoundedRectangle(
      cornerRadius: min(r.width, r.height) * cornerFraction,
      style: .continuous
    ).path(in: r)
  }

  func inset(by amount: CGFloat) -> Self {
    var copy = self
    copy.insetAmount += amount
    return copy
  }
}
