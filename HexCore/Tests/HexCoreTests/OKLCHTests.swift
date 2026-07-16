import XCTest
@testable import HexCore

final class OKLCHTests: XCTestCase {
  /// Rounds a channel to an 8-bit value so expectations read as sRGB.
  private func rgb255(_ c: OKLCH) -> (Int, Int, Int) {
    let (r, g, b) = c.sRGB
    return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
  }

  private func assertRGB(
    _ c: OKLCH, _ expected: (Int, Int, Int), tolerance: Int = 1,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
  ) {
    let got = rgb255(c)
    let ok = abs(got.0 - expected.0) <= tolerance
      && abs(got.1 - expected.1) <= tolerance
      && abs(got.2 - expected.2) <= tolerance
    XCTAssertTrue(
      ok,
      "\(message) expected ~rgb\(expected), got rgb\(got)",
      file: file, line: line
    )
  }

  // MARK: - Conversion correctness

  func testConvertsSRGBPrimaries() {
    // Reference OKLCH coordinates of the sRGB primaries and extremes.
    assertRGB(OKLCH(1, 0, 0), (255, 255, 255), "white")
    assertRGB(OKLCH(0, 0, 0), (0, 0, 0), "black")
    assertRGB(OKLCH(0.628, 0.2577, 29.23), (255, 0, 0), "red")
    assertRGB(OKLCH(0.8664, 0.2947, 142.5), (0, 255, 0), "green")
    assertRGB(OKLCH(0.452, 0.3132, 264.05), (0, 0, 255), "blue")
  }

  func testChromaZeroIsNeutralAtEveryHue() {
    // Grey must stay grey regardless of hue angle.
    for hue in stride(from: 0.0, to: 360.0, by: 45) {
      let (r, g, b) = rgb255(OKLCH(0.5, 0, hue))
      XCTAssertEqual(r, g, "hue \(hue) drifted off-neutral")
      XCTAssertEqual(g, b, "hue \(hue) drifted off-neutral")
    }
  }

  func testOutOfGamutClampsRatherThanOverflowing() {
    // Absurd chroma must not produce NaN or out-of-range channels.
    let (r, g, b) = OKLCH(0.5, 5.0, 30).sRGB
    for channel in [r, g, b] {
      XCTAssertFalse(channel.isNaN)
      XCTAssertGreaterThanOrEqual(channel, 0)
      XCTAssertLessThanOrEqual(channel, 1)
    }
  }

  // MARK: - Derivations

  func testIdleDesaturatesButHoldsHueAndLightness() {
    let active = QuillDesign.ModePalette.auto
    let idle = active.idle
    XCTAssertEqual(idle.C, 0.07, accuracy: 0.0001)
    XCTAssertEqual(idle.H, active.H)
    XCTAssertEqual(idle.L, active.L)
  }

  func testDarkenedFloorsAtEighteenPercent() {
    XCTAssertEqual(OKLCH(0.72, 0.15, 292).darkened(by: 0.28).L, 0.44, accuracy: 0.0001)
    // A dark starting point clamps instead of going negative.
    XCTAssertEqual(OKLCH(0.20, 0.15, 292).darkened(by: 0.28).L, 0.18, accuracy: 0.0001)
  }

  func testLightnessCappedOnlyLowers() {
    XCTAssertEqual(OKLCH(0.8, 0.15, 70).lightnessCapped(at: 0.46).L, 0.46, accuracy: 0.0001)
    XCTAssertEqual(OKLCH(0.3, 0.15, 70).lightnessCapped(at: 0.46).L, 0.30, accuracy: 0.0001)
  }

  // MARK: - The shipping palette

  /// Guards the palette against a silent color-space regression: these are
  /// OKLCH hues, and feeding them to HSB instead would land somewhere else
  /// entirely (HSB 248 is blue-violet; OKLCH 248 is sky blue).
  func testModePaletteRendersTheSpecifiedColors() {
    assertRGB(QuillDesign.ModePalette.auto, (167, 145, 250), "auto violet")
    assertRGB(QuillDesign.ModePalette.dictate, (74, 177, 255), "dictate blue")
    assertRGB(QuillDesign.ModePalette.edit, (250, 171, 63), "edit amber")
    assertRGB(QuillDesign.ModePalette.act, (37, 210, 199), "act teal")
    assertRGB(QuillDesign.ModePalette.resolved, (110, 216, 137), "resolved green")
    assertRGB(QuillDesign.brand, (134, 99, 230), "brand violet")
  }

  func testBrandSharesTheAutoHue() {
    XCTAssertEqual(QuillDesign.brand.H, QuillDesign.ModePalette.auto.H)
  }

  // MARK: - Hex round-trip

  func testHexInitInvertsTheForwardConversion() {
    // Every mode colour must survive hex → OKLCH → hex unchanged.
    for palette in [
      QuillDesign.ModePalette.auto, QuillDesign.ModePalette.dictate,
      QuillDesign.ModePalette.edit, QuillDesign.ModePalette.act,
      QuillDesign.ModePalette.resolved, QuillDesign.brand,
    ] {
      let (r, g, b) = palette.sRGB
      let hex = String(
        format: "#%02X%02X%02X",
        Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())
      )
      guard let round = OKLCH(hex: hex) else {
        return XCTFail("failed to parse \(hex)")
      }
      assertRGB(round, rgb255(palette), "round-trip of \(hex)")
    }
  }

  func testHexInitParsesKnownColors() {
    guard let red = OKLCH(hex: "#FF0000") else { return XCTFail("parse failed") }
    XCTAssertEqual(red.L, 0.628, accuracy: 0.002)
    XCTAssertEqual(red.C, 0.2577, accuracy: 0.002)
    XCTAssertEqual(red.H, 29.23, accuracy: 0.3)

    // Greys land at zero chroma; hue is meaningless but must not be NaN.
    guard let grey = OKLCH(hex: "#808080") else { return XCTFail("parse failed") }
    XCTAssertEqual(grey.C, 0, accuracy: 0.001)
    XCTAssertFalse(grey.H.isNaN)
  }

  func testHexInitToleratesMissingHashAndRejectsGarbage() {
    XCTAssertNotNil(OKLCH(hex: "FF0000"))
    XCTAssertNotNil(OKLCH(hex: "  #ff0000 "))
    XCTAssertNil(OKLCH(hex: "#FFF"))
    XCTAssertNil(OKLCH(hex: "nonsense"))
    XCTAssertNil(OKLCH(hex: ""))
  }

  // MARK: - Hue interpolation

  func testNearestEquivalentHueTakesTheShortWayRound() {
    // Auto (292) → Edit (70): the short way is +138° through 0°, not −222°
    // back through Act's teal and Resolved's green.
    XCTAssertEqual(OKLCH.nearestEquivalentHue(to: 70, from: 292), 430, accuracy: 0.0001)
    // And the reverse.
    XCTAssertEqual(OKLCH.nearestEquivalentHue(to: 292, from: 70), -68, accuracy: 0.0001)
    // A short delta is left alone.
    XCTAssertEqual(OKLCH.nearestEquivalentHue(to: 248, from: 292), 248, accuracy: 0.0001)
  }

  func testNearestEquivalentHueIsAngularlyEquivalentToTheTarget() {
    // Whatever representative we pick must render as the target hue.
    for (target, current) in [(70.0, 292.0), (292.0, 70.0), (188.0, 150.0), (150.0, 350.0)] {
      let equivalent = OKLCH.nearestEquivalentHue(to: target, from: current)
      let a = OKLCH(0.7, 0.15, equivalent).sRGB
      let b = OKLCH(0.7, 0.15, target).sRGB
      XCTAssertEqual(a.red, b.red, accuracy: 0.0001)
      XCTAssertEqual(a.green, b.green, accuracy: 0.0001)
      XCTAssertEqual(a.blue, b.blue, accuracy: 0.0001)
    }
  }

  func testNearestEquivalentHueNeverTravelsMoreThanHalfTheCircle() {
    for target in stride(from: 0.0, to: 360.0, by: 17) {
      for current in stride(from: 0.0, to: 360.0, by: 23) {
        let travel = abs(OKLCH.nearestEquivalentHue(to: target, from: current) - current)
        XCTAssertLessThanOrEqual(travel, 180.0001, "\(current)→\(target) took the long way")
      }
    }
  }

  func testModeHuesAreDistinguishable() {
    // Mode is the signal, so no two modes may sit within 30° of each other.
    let hues = [
      QuillDesign.Hue.auto, QuillDesign.Hue.dictate,
      QuillDesign.Hue.edit, QuillDesign.Hue.action, QuillDesign.Hue.success,
    ]
    for (i, a) in hues.enumerated() {
      for b in hues[(i + 1)...] {
        let raw = abs(a - b)
        let separation = min(raw, 360 - raw)
        XCTAssertGreaterThan(separation, 30, "hues \(a) and \(b) are too close to tell apart")
      }
    }
  }
}
