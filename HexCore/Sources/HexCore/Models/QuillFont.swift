//
//  QuillFont.swift
//  HexCore
//
//  Dynamic-Type-aware system fonts at exact design sizes.
//
//  `Font.system(size:)` is fixed — it ignores the user's text-size setting
//  entirely. The usual fix is to move everything onto semantic styles
//  (.body, .caption…), but Quill's type ramp uses in-between sizes
//  deliberately (10.5, 12.5, 13.5), and snapping them all to the nearest
//  semantic style would redraw the app.
//
//  `@ScaledMetric` gives us both: the exact point size at the default text
//  size, scaled by the same curve as the semantic style it's anchored to.
//  Anchoring matters — small text should scale on the caption curve, not the
//  body one, or a 9pt badge grows faster than the 13pt label beside it.
//

import SwiftUI

/// Applies a system font whose point size scales with Dynamic Type.
public struct ScaledSystemFont: ViewModifier {
  @ScaledMetric private var size: CGFloat
  private let weight: Font.Weight
  private let design: Font.Design

  public init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
    _size = ScaledMetric(wrappedValue: size, relativeTo: style)
    self.weight = weight
    self.design = design
  }

  public func body(content: Content) -> some View {
    content.font(.system(size: size, weight: weight, design: design))
  }
}

public extension Font.TextStyle {
  /// The semantic style whose scaling curve best fits `size`. Used as the
  /// anchor for `ScaledSystemFont`, not as the font itself.
  static func quillScalingAnchor(for size: CGFloat) -> Font.TextStyle {
    switch size {
    case ..<11.5: .caption2
    case ..<12.5: .caption
    case ..<14: .footnote
    case ..<15.5: .subheadline
    case ..<16.5: .callout
    case ..<18.5: .body
    case ..<21: .title3
    case ..<25: .title2
    case ..<31: .title
    default: .largeTitle
    }
  }
}

public extension View {
  /// A system font at an exact size that still honours Dynamic Type.
  ///
  /// Drop-in for `.font(.system(size:weight:design:))` — same arguments, same
  /// rendering at the default text size, but it grows and shrinks with the
  /// user's setting. Prefer a semantic style (`.font(.headline)`) for new
  /// body copy; use this where a specific size is part of the design.
  func quillFont(
    _ size: CGFloat,
    weight: Font.Weight = .regular,
    design: Font.Design = .default
  ) -> some View {
    modifier(
      ScaledSystemFont(
        size: size,
        weight: weight,
        design: design,
        relativeTo: .quillScalingAnchor(for: size)
      )
    )
  }
}
