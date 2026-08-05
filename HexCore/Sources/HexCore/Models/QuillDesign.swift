//
//  QuillDesign.swift
//  HexCore
//
//  Shared design tokens so both apps speak the same visual language.
//
//  Mode is expressed as one hue; state is expressed as motion. Every mode
//  color derives from a single OKLCH triple — tints, borders, and the orb's
//  gradient stops are all formulas over it (see `OKLCH`), so the palette
//  stays coherent without a table of hand-picked hex values.
//
//  NOTE: these hue numbers are OKLCH hue angles, NOT the HSB hues this file
//  used before. The two spaces disagree sharply at the same number — HSB 248
//  is blue-violet, OKLCH 248 is sky blue — so always render through
//  `OKLCH.color(_:)` and never pass a hue here to
//  `Color(hue:saturation:brightness:)`.
//

import SwiftUI

public enum QuillDesign {
  // MARK: - Mode hues (OKLCH hue angles, degrees)

  public enum Hue {
    public static let auto: Double = 292     // violet — also the brand hue
    public static let dictate: Double = 248  // blue
    public static let edit: Double = 70      // amber
    public static let action: Double = 188   // teal
    public static let success: Double = 150  // green
  }

  // MARK: - Mode palette

  /// The full-strength color for each mode. `.idle` on any of these gives
  /// the desaturated at-rest variant used by the resting orb and glyph.
  public enum ModePalette {
    public static let auto = OKLCH(0.72, 0.15, Hue.auto)
    public static let dictate = OKLCH(0.74, 0.16, Hue.dictate)
    public static let edit = OKLCH(0.80, 0.15, Hue.edit)
    public static let act = OKLCH(0.78, 0.13, Hue.action)
    public static let resolved = OKLCH(0.80, 0.15, Hue.success)
  }

  /// Brand accent — wordmark, links, compose affordances. Shares the Auto
  /// hue: the default mode wears the brand color.
  public static let brand = OKLCH(0.6, 0.19, Hue.auto)

  /// Accent color for an Act destination, keyed by its own hue.
  public static func destination(hue: Double) -> OKLCH {
    OKLCH(0.72, 0.16, hue)
  }

  // MARK: - Derived treatments

  /// Gradient stops for the orb sphere: a white specular highlight, the
  /// mode color, then a darkened rim.
  public static func orbGradient(_ c: OKLCH) -> Gradient {
    Gradient(stops: [
      .init(color: .white, location: 0.02),
      .init(color: c.color(), location: 0.52),
      .init(color: c.darkened(by: 0.28).color(), location: 1.0),
    ])
  }

  /// Readable text on a tinted chip of the same hue.
  public static func onTint(_ c: OKLCH, dark: Bool) -> Color {
    c.lightnessCapped(at: dark ? 0.82 : 0.46).color()
  }

  // MARK: - Semantic colors

  /// Accent for anything Action-mode: the bolt, action FAB, sheet headers,
  /// MCP status.
  public static let actionAccent = ModePalette.act.color()
  /// Success states (completion checks, resolved flashes).
  public static let success = ModePalette.resolved.color()
  /// Neutral tile for MCP steps that have no brand of their own.
  public static let mcpTile = Color(hue: 0.62, saturation: 0.25, brightness: 0.55)

  // MARK: - Geometry

  /// The one corner-radius scale.
  ///
  /// Five steps, deliberately placed at the values the codebase already used
  /// most (4/8/12/16), so consolidating moved the majority of surfaces by 2pt
  /// or less rather than redrawing the app. Glass and material shapes both
  /// take a radius, so a single scale is what keeps a chip inside a card
  /// inside a sheet reading as nested rather than as three unrelated shapes.
  ///
  /// Use the semantic aliases at call sites — `Radius.card`, not `Radius.md`.
  /// The step names exist so the scale can be reasoned about as a scale.
  public enum Radius {
    /// Badges, micro tiles, keycaps.
    public static let xs: CGFloat = 4
    /// Chips, small controls, icon tiles.
    public static let sm: CGFloat = 8
    /// Rows, fields, buttons, standard cards.
    public static let md: CGFloat = 12
    /// Panels and prominent cards.
    public static let lg: CGFloat = 16
    /// Sheets and full-width containers.
    public static let xl: CGFloat = 24

    // Semantic aliases — what call sites should say.
    public static let badge = xs
    public static let chip = sm
    public static let tile = sm
    public static let control = md
    public static let card = md
    public static let panel = lg
    public static let group = lg
    public static let sheet = xl
  }

  public enum OrbSize {
    public static let onboarding: CGFloat = 150
    public static let focal: CGFloat = 92
    public static let trigger: CGFloat = 46
    public static let triggerRing: CGFloat = 62
    public static let composer: CGFloat = 46
  }

  // MARK: - Card metrics (existing surfaces — see `quillCard`)
  //
  // These predate `Radius` and disagreed with it (a card was 10 here and 20
  // there). They now forward to the scale so there is exactly one answer to
  // "what radius is a card?".

  public static let cardCornerRadius = Radius.card
  public static let sheetCornerRadius = Radius.panel
}

// MARK: - Theme

/// The flat, material-first theme. Elevation is translucency + hairline
/// borders + a faint inner stroke — never a drop shadow.
public struct QuillTheme: Sendable {
  public var isDark: Bool

  public var page: Color
  public var pageGradient: [Color]
  public var card: Color
  public var cardSolid: Color
  public var text: Color
  public var text2: Color
  public var text3: Color
  public var hair: Color
  public var field: Color
  public var fieldRing: Color
  public var glass: Color
  public var glassBorder: Color
  public var chip: Color

  /// The two halves of the inner stroke: a bright top edge (light theme
  /// only) and an all-round hairline.
  public var innerStrokeTop: Color
  public var innerStrokeRing: Color

  public static let light = QuillTheme(
    isDark: false,
    page: Color(hex: "#F2F1F7") ?? .white,
    pageGradient: [Color(hex: "#F7F6FB") ?? .white, Color(hex: "#EEEDF4") ?? .white],
    card: .white,
    cardSolid: .white,
    text: Color(hex: "#0F0F14") ?? .black,
    text2: Color(.sRGB, red: 60/255, green: 60/255, blue: 67/255, opacity: 0.62),
    text3: Color(.sRGB, red: 60/255, green: 60/255, blue: 67/255, opacity: 0.34),
    hair: Color(.sRGB, red: 60/255, green: 60/255, blue: 67/255, opacity: 0.12),
    field: .white,
    fieldRing: Color(.sRGB, red: 60/255, green: 60/255, blue: 67/255, opacity: 0.10),
    glass: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.82),
    glassBorder: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.9),
    chip: Color(.sRGB, red: 120/255, green: 120/255, blue: 128/255, opacity: 0.12),
    innerStrokeTop: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.9),
    innerStrokeRing: Color(.sRGB, red: 60/255, green: 60/255, blue: 67/255, opacity: 0.07)
  )

  public static let dark = QuillTheme(
    isDark: true,
    page: Color(hex: "#0C0D10") ?? .black,
    pageGradient: [
      Color(hex: "#1B1C23") ?? .black,
      Color(hex: "#101117") ?? .black,
      Color(hex: "#0A0B0E") ?? .black,
    ],
    card: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.05),
    cardSolid: Color(hex: "#181920") ?? .black,
    text: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.94),
    text2: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.58),
    text3: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.34),
    hair: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.10),
    field: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.07),
    fieldRing: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.13),
    glass: Color(.sRGB, red: 28/255, green: 29/255, blue: 36/255, opacity: 0.72),
    glassBorder: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.12),
    chip: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.09),
    innerStrokeTop: .clear,
    innerStrokeRing: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.06)
  )

  public static func of(_ scheme: ColorScheme) -> QuillTheme {
    scheme == .dark ? .dark : .light
  }
}

public extension EnvironmentValues {
  /// The active Quill theme. Set once at the app root from `colorScheme`.
  var quillTheme: QuillTheme {
    get { self[QuillThemeKey.self] }
    set { self[QuillThemeKey.self] = newValue }
  }
}

private struct QuillThemeKey: EnvironmentKey {
  static let defaultValue = QuillTheme.light
}

// MARK: - Card chrome

/// The one card treatment used by sheets, queue rows, settings tiles —
/// replaces the hand-rolled rounded-rect styles that had drifted apart.
public struct QuillCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  /// Quill's elevation is translucency, so this setting has to be honoured
  /// here or it has no effect anywhere: a 5%-alpha fill over a busy page is
  /// exactly the low-contrast surface the user turned it on to avoid.
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var cornerRadius: CGFloat

  public init(cornerRadius: CGFloat = QuillDesign.cardCornerRadius) {
    self.cornerRadius = cornerRadius
  }

  private var theme: QuillTheme { .of(colorScheme) }

  public func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(reduceTransparency ? AnyShapeStyle(theme.cardSolid) : AnyShapeStyle(theme.card))
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            // A hairline that survives an opaque fill needs more contrast
            // than one floating over a blur.
            reduceTransparency
              ? (colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.22))
              : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)),
            lineWidth: reduceTransparency ? 1 : 0.5
          )
      )
  }
}

public extension View {
  /// Standard Quill card chrome (frosted fill + hairline border).
  func quillCard(cornerRadius: CGFloat = QuillDesign.cardCornerRadius) -> some View {
    modifier(QuillCardModifier(cornerRadius: cornerRadius))
  }
}
