//
//  QuillDesign.swift
//  HexCore
//
//  Shared design tokens so both apps speak the same visual language.
//  The mode hues are the macOS orb palette (OrbView) — the iOS app maps
//  its accents onto them (action = teal, not orange) so the platforms
//  read as siblings. Keep hue values in sync with `OrbHue` in
//  Hex/Features/Transcription/OrbView.swift.
//

import SwiftUI

public enum QuillDesign {
  // MARK: - Mode hues (degrees, matching the macOS orb)

  public enum Hue {
    public static let auto: Double = 220     // steel blue
    public static let dictate: Double = 248  // blue-violet (brand adjacent)
    public static let edit: Double = 305     // violet
    public static let action: Double = 188   // teal
    public static let success: Double = 150  // green
  }

  // MARK: - Semantic colors

  /// Accent for anything Action-mode: the bolt, action FAB, sheet
  /// headers, MCP status. Matches the Mac orb's Action teal.
  public static let actionAccent = Color(hue: Hue.action / 360.0, saturation: 0.62, brightness: 0.72)
  /// Softer action tint for fills/badges.
  public static let actionTint = Color(hue: Hue.action / 360.0, saturation: 0.45, brightness: 0.85)
  /// Success states (completion checks, resolved flashes).
  public static let success = Color(hue: Hue.success / 360.0, saturation: 0.6, brightness: 0.75)
  /// Dictation/brand accent — the Quill purple family.
  public static let dictateAccent = Color(hue: Hue.dictate / 360.0, saturation: 0.55, brightness: 0.85)
  /// Neutral tile for MCP steps (matches the macOS step tile).
  public static let mcpTile = Color(hue: 0.62, saturation: 0.25, brightness: 0.55)

  // MARK: - Card metrics

  public static let cardCornerRadius: CGFloat = 10
  public static let sheetCornerRadius: CGFloat = 12
}

/// The one card treatment used by sheets, queue rows, settings tiles —
/// replaces the hand-rolled rounded-rect styles that had drifted apart.
public struct QuillCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  var cornerRadius: CGFloat

  public init(cornerRadius: CGFloat = QuillDesign.cardCornerRadius) {
    self.cornerRadius = cornerRadius
  }

  public func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 0.5)
      )
  }
}

public extension View {
  /// Standard Quill card chrome (frosted fill + hairline border).
  func quillCard(cornerRadius: CGFloat = QuillDesign.cardCornerRadius) -> some View {
    modifier(QuillCardModifier(cornerRadius: cornerRadius))
  }
}
