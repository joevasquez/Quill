//
//  OKLCH.swift
//  HexCore
//
//  The Quill design system expresses every mode color as one hue plus a
//  chroma/lightness pair, and derives tints, borders and gradient stops
//  from it formulaically (idle = same hue at C 0.07; the orb's far
//  gradient stop = L − 0.28). SwiftUI has no OKLCH initializer, so we
//  convert here and let the design tokens read the way the spec writes
//  them.
//
//  Conversion path: OKLCH → OKLab → LMS → linear sRGB → gamma-encoded
//  sRGB, per Björn Ottosson's Oklab definition.
//

import SwiftUI

/// A color in the OKLCH space: perceptual lightness, chroma, and hue angle.
public struct OKLCH: Equatable, Sendable {
  /// Perceptual lightness, 0...1.
  public var L: Double
  /// Chroma. 0 is grey; the design tokens sit around 0.07...0.19.
  public var C: Double
  /// Hue angle in degrees, 0..<360.
  public var H: Double

  public init(_ L: Double, _ C: Double, _ H: Double) {
    self.L = L
    self.C = C
    self.H = H
  }

  /// The same hue and lightness, desaturated to the design system's idle
  /// chroma. Used for the at-rest orb disc and feather glyph.
  public var idle: OKLCH { OKLCH(L, 0.07, H) }

  /// A copy with chroma scaled by `factor`, holding hue and lightness.
  /// Scaling the mode's own chroma (rather than substituting a flat value)
  /// keeps each mode at its intended intensity when quietened at rest.
  public func chromaScaled(_ factor: Double) -> OKLCH {
    OKLCH(L, C * factor, H)
  }

  /// A copy with lightness clamped to at most `ceiling` — the spec's
  /// `oklch(min(L, dark ? 0.82 : 0.46) C H)` pattern for active text on a
  /// tinted background.
  public func lightnessCapped(at ceiling: Double) -> OKLCH {
    OKLCH(Swift.min(L, ceiling), C, H)
  }

  /// A copy darkened by `amount`, floored at 0.18 — the orb gradient's
  /// outer stop.
  public func darkened(by amount: Double) -> OKLCH {
    OKLCH(Swift.max(0.18, L - amount), C, H)
  }

  /// Gamma-encoded sRGB components, each clamped to the display gamut.
  ///
  /// Out-of-gamut OKLCH values clip per-channel rather than reducing
  /// chroma. Every hue in the Quill palette is in gamut at its specified
  /// chroma, so clipping never fires for the shipping tokens — it exists
  /// so a hand-tuned value can't produce a NaN.
  public var sRGB: (red: Double, green: Double, blue: Double) {
    let hRad = H * .pi / 180
    let a = C * cos(hRad)
    let b = C * sin(hRad)

    // OKLab → LMS (cube roots)
    let l_ = L + 0.3963377774 * a + 0.2158037573 * b
    let m_ = L - 0.1055613458 * a - 0.0638541728 * b
    let s_ = L - 0.0894841775 * a - 1.2914855480 * b

    let l = l_ * l_ * l_
    let m = m_ * m_ * m_
    let s = s_ * s_ * s_

    // LMS → linear sRGB
    let rLin = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let gLin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let bLin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

    return (gammaEncode(rLin), gammaEncode(gLin), gammaEncode(bLin))
  }

  /// A SwiftUI color, optionally at partial opacity.
  public func color(_ alpha: Double = 1) -> Color {
    let (r, g, b) = sRGB
    return Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
  }

  /// Reads an sRGB hex string into OKLCH — the inverse of `sRGB`.
  ///
  /// Third-party brands ship hex, but the design system reasons in hue, so
  /// this is how a brand colour joins the palette (e.g. an MCP server's
  /// directory tint becoming its destination chip's hue).
  public init?(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }

    let r = linearize(Double((v >> 16) & 0xFF) / 255)
    let g = linearize(Double((v >> 8) & 0xFF) / 255)
    let b = linearize(Double(v & 0xFF) / 255)

    // linear sRGB → LMS
    let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    let sCone = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

    let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(sCone)

    // LMS → OKLab
    let lightness = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    let aAxis = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    let bAxis = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_

    var hue = atan2(bAxis, aAxis) * 180 / .pi
    if hue < 0 { hue += 360 }

    self.init(lightness, sqrt(aAxis * aAxis + bAxis * bAxis), hue)
  }

  /// The representation of `target` nearest to `current` on the hue circle,
  /// so an animation between the two sweeps the short way round.
  ///
  /// The result may fall outside 0..<360 — that's intended, and harmless:
  /// hue is read back through `cos`/`sin`, which are periodic. Interpolating
  /// the raw numbers instead would drag a violet→amber transition backwards
  /// through teal and green, flashing two other modes' colors on the way.
  public static func nearestEquivalentHue(to target: Double, from current: Double) -> Double {
    let delta = (target - current).truncatingRemainder(dividingBy: 360)
    let shortest: Double
    if delta > 180 {
      shortest = delta - 360
    } else if delta < -180 {
      shortest = delta + 360
    } else {
      shortest = delta
    }
    return current + shortest
  }
}

private func linearize(_ encoded: Double) -> Double {
  encoded <= 0.04045
    ? encoded / 12.92
    : pow((encoded + 0.055) / 1.055, 2.4)
}

private func gammaEncode(_ linear: Double) -> Double {
  let v = linear <= 0.0031308
    ? 12.92 * linear
    : 1.055 * pow(Swift.max(0, linear), 1.0 / 2.4) - 0.055
  return Swift.min(1, Swift.max(0, v))
}
