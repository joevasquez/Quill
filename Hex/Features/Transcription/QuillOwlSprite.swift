//
//  QuillOwlSprite.swift
//  Hex
//
//  Swift port of `quill-owl-sprite.js` from the "Quill — Owl avatar view
//  mode" design handoff. The artwork *is* this file: every pixel of the
//  48×48 owl is generated here, there are no image assets. Ported
//  literally, per the handoff — the constants encode the drawing, so
//  "cleanups" to the arithmetic visibly break pixel alignment.
//
//  Rendering strategy: the three static layers (body, head, quill) are
//  rasterized once into CGImages and cached per accent colour; only the
//  small dynamic parts (ink, pupils, eyelids, sparkles, progress bar,
//  monocle glint) are filled per frame. That is pixel-identical to the
//  JS `blit` — a blit is just a pixel copy — at a fraction of the cost
//  for an always-on 60 fps overlay.
//

import CoreGraphics
import HexCore
import SwiftUI

// MARK: - Mode

/// What the owl is *doing*. Distinct from `TranscriptionIndicatorView.Mode`
/// (which is what Quill is *for* — Auto/Dictate/Edit/Action).
enum OwlSpriteMode: Equatable {
  case ready
  case writing
  case working
}

// MARK: - Sprite

enum QuillOwlSprite {
  static let spriteSize = 48

  // MARK: Geometry constants (from the handoff)

  private static let eyeLX = 14.0
  private static let eyeRX = 33.0
  private static let eyeY = 25.0
  private static let eyeR = 5.5

  private static let paperX0 = 13
  private static let paperX1 = 34
  private static let paperY0 = 38

  private static let inkX = 16
  private static let inkRows = [41, 43, 45]
  private static let inkLengths = [13, 13, 8]

  private static let quillTip = (x: 0, y: 8)

  // MARK: Timings

  private static let lineDuration = 1.15
  private static let pauseDuration = 0.7
  private static let writeCycle = Double(inkRows.count) * lineDuration + pauseDuration  // 4.15
  private static let workCycle = 2.4
  private static let readyCycle = 3.6

  private static let tau = Double.pi * 2

  /// That state's loop length in seconds.
  static func cycle(_ mode: OwlSpriteMode) -> Double {
    switch mode {
    case .writing: return writeCycle
    case .working: return workCycle * 2
    case .ready: return readyCycle
    }
  }

  // MARK: - Grid primitives
  //
  // A grid is rows of single-character palette keys; "." is transparent.

  private typealias Grid = [[Character]]

  /// JavaScript `Math.round` semantics — half rounds toward +∞. Swift's
  /// `rounded()` rounds half *away from zero*, which differs for negative
  /// halves (e.g. the quill rotation, which swings negative).
  private static func jsRound(_ v: Double) -> Int { Int(floor(v + 0.5)) }

  private static func makeGrid(_ w: Int, _ h: Int) -> Grid {
    Array(repeating: Array(repeating: Character("."), count: w), count: h)
  }

  private static func put(_ g: inout Grid, _ x: Double, _ y: Double, _ c: Character) {
    let xi = jsRound(x), yi = jsRound(y)
    guard yi >= 0, yi < g.count, xi >= 0, xi < g[yi].count else { return }
    g[yi][xi] = c
  }

  /// Filled ellipse. `only` restricts painting to cells already holding one
  /// of the given keys (the JS "paint into the existing silhouette" trick).
  private static func fillEll(
    _ g: inout Grid, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double,
    _ c: Character, only: [Character]? = nil
  ) {
    for y in Int(floor(cy - ry))...Int(ceil(cy + ry)) {
      for x in Int(floor(cx - rx))...Int(ceil(cx + rx)) {
        let dx = (Double(x) - cx) / rx
        let dy = (Double(y) - cy) / ry
        if dx * dx + dy * dy > 1 { continue }
        if let only {
          guard y >= 0, y < g.count, x >= 0, x < g[y].count, only.contains(g[y][x]) else { continue }
        }
        put(&g, Double(x), Double(y), c)
      }
    }
  }

  private static func fillBox(_ g: inout Grid, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Character) {
    for y in y0...y1 {
      for x in x0...x1 { put(&g, Double(x), Double(y), c) }
    }
  }

  private static func ringEll(_ g: inout Grid, _ cx: Double, _ cy: Double, _ r0: Double, _ r1: Double, _ c: Character) {
    for y in Int(floor(cy - r1))...Int(ceil(cy + r1)) {
      for x in Int(floor(cx - r1))...Int(ceil(cx + r1)) {
        let d = hypot(Double(x) - cx, Double(y) - cy)
        if d <= r1, d >= r0 { put(&g, Double(x), Double(y), c) }
      }
    }
  }

  /// One-pixel outline around every filled cell, in `c`.
  private static func outline(_ g: inout Grid, _ c: Character) {
    let src = g
    for y in 0..<src.count {
      for x in 0..<src[y].count {
        guard src[y][x] == "." else { continue }
        var touching = false
        if x > 0, src[y][x - 1] != "." { touching = true }
        if x + 1 < src[y].count, src[y][x + 1] != "." { touching = true }
        if y > 0, x < src[y - 1].count, src[y - 1][x] != "." { touching = true }
        if y + 1 < src.count, x < src[y + 1].count, src[y + 1][x] != "." { touching = true }
        if touching { g[y][x] = c }
      }
    }
  }

  // MARK: - Layers

  private static let bodyGrid: Grid = {
    var g = makeGrid(spriteSize, spriteSize)
    fillEll(&g, 23.5, 47, 18, 14, "f")
    fillEll(&g, 8, 45, 5.5, 10, "d", only: ["f"])
    fillEll(&g, 39, 45, 5.5, 10, "d", only: ["f"])
    put(&g, 17, 36, "d"); put(&g, 30, 36, "d"); put(&g, 23.5, 35, "d")
    fillBox(&g, paperX0, paperY0, paperX1, 47, "W")
    fillBox(&g, paperX0 + 1, paperY0 + 1, paperX1 - 1, 47, "w")
    outline(&g, "k")
    return g
  }()

  private static let headGrid: Grid = {
    var g = makeGrid(spriteSize, spriteSize)
    fillEll(&g, 9, 18, 3.6, 5.4, "f")           // ear tufts
    fillEll(&g, 38, 18, 3.6, 5.4, "f")
    fillEll(&g, 23.5, 26, 17, 11.5, "f")        // head
    fillEll(&g, 23.5, 27, 14, 9.5, "F", only: ["f"])
    fillEll(&g, eyeLX, eyeY, eyeR, eyeR, "e")   // eye whites
    fillEll(&g, eyeRX, eyeY, eyeR, eyeR, "e")
    fillBox(&g, 21, 27, 26, 28, "y")            // beak
    fillBox(&g, 22, 29, 25, 29, "y")
    fillBox(&g, 23, 30, 24, 31, "o")
    fillEll(&g, 10.5, 31.5, 3, 1.8, "c", only: ["F", "f"])  // blush
    fillEll(&g, 36.5, 31.5, 3, 1.8, "c", only: ["F", "f"])
    ringEll(&g, eyeRX, eyeY, 6.3, 7.4, "g")     // monocle
    for (x, y) in [(38.0, 31.0), (38.0, 32.0), (37.0, 33.0), (37.0, 34.0)] {
      put(&g, x, y, "g")                        // monocle chain
    }
    fillBox(&g, 16, 3, 31, 13, "h")             // top hat
    fillBox(&g, 16, 3, 31, 4, "H")
    fillBox(&g, 16, 8, 31, 10, "b")             // hat band (accent)
    fillEll(&g, 23.5, 13.5, 14, 2.7, "h")       // brim
    fillEll(&g, 23.5, 12.2, 14, 0.9, "H")
    outline(&g, "k")
    return g
  }()

  private static let quillGrid: Grid = {
    var g = makeGrid(16, 9)
    for i in 0...30 {
      let s = Double(i) / 30
      put(&g, 1 + s * 6, 6 - s * 3, "Z")
      put(&g, 1 + s * 6, 7 - s * 3, "Z")
    }
    fillEll(&g, 11, 2.6, 4.8, 2.6, "Q")
    fillEll(&g, 11.8, 3.3, 3.9, 1.6, "q", only: ["Q"])
    for i in 0...24 {
      let s = Double(i) / 24
      put(&g, 7 + s * 8, 4 - s * 2.4, "Z")
    }
    put(&g, 0, 8, "n"); put(&g, 1, 8, "n"); put(&g, 0, 7, "n"); put(&g, 1, 7, "n")
    outline(&g, "k")
    return g
  }()

  // MARK: - Palette

  /// The handoff ships three feather tones; Quill uses Warm buff (the
  /// default) — there's no UI to pick another.
  private enum Tone {
    static let base = "#c99a63"
    static let belly = "#f3dcb4"
    static let shadow = "#9c7345"
  }

  /// Colours the dynamic (per-frame) drawing needs, as SwiftUI colours.
  struct DynamicColors {
    let ink = Color(hex: "#5b4a72")!
    let paperEdge = Color(hex: "#d8d0bd")!       // pal.W
    let progressTrack = Color(hex: "#c8bfa8")!
    let bellyF = Color(hex: Tone.belly)!         // pal.F — closed eyelid
    let shadowD = Color(hex: Tone.shadow)!       // pal.d — lid crease
    let pupil = Color(hex: "#2b2337")!
    let pupilHighlight = Color(hex: "#fffdf6")!
    let pupilLowlight = Color(hex: "#6d5e86")!
    let gold = Color(hex: "#ffd97a")!            // pal.g — sparkles
    let sparkCore = Color(hex: "#fffdf5")!
    let accent: Color
  }

  private static func hexColor(_ hex: String) -> CGColor {
    var h = hex
    if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt32(h, radix: 16) ?? 0
    return CGColor(
      srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
      green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255,
      alpha: 1
    )
  }

  /// The sprite's colour table, keyed by grid character.
  private static func palette(accent: CGColor) -> [Character: CGColor] {
    [
      "k": hexColor("#241d2c"),                 // outline
      "h": hexColor("#3a3350"),                 // hat body
      "H": hexColor("#544a6e"),                 // hat highlight
      "b": accent,                              // hat band
      "e": hexColor("#fffaf0"),                 // eye white
      "y": hexColor("#f0a83c"),                 // beak
      "o": hexColor("#c0741f"),                 // beak shadow
      "g": hexColor("#ffd97a"),                 // monocle gold
      "c": hexColor("#e5a08c"),                 // blush
      "w": hexColor("#f8f3e6"),                 // paper
      "W": hexColor("#d8d0bd"),                 // paper edge
      "Q": hexColor("#fdfaf2"),                 // feather vane light
      "q": hexColor("#d4c7ab"),                 // feather vane shade
      "Z": hexColor("#7d6a4e"),                 // rachis
      "n": hexColor("#2b2320"),                 // nib
      "f": hexColor(Tone.base),
      "F": hexColor(Tone.belly),
      "d": hexColor(Tone.shadow),
    ]
  }

  // MARK: - Rasterization

  struct Layers {
    let body: Image
    let head: Image
    let quill: Image
    /// Quill layer size in sprite pixels (16 × 9) — the other two are 48².
    static let quillSize = (w: 16, h: 9)
  }

  private static func rasterize(_ g: Grid, palette: [Character: CGColor], scale: Int) -> CGImage? {
    let rows = g.count
    let cols = g.first?.count ?? 0
    guard rows > 0, cols > 0 else { return nil }
    guard let ctx = CGContext(
      data: nil,
      width: cols * scale,
      height: rows * scale,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setShouldAntialias(false)
    // CGBitmapContext user space is y-up; the grid is y-down. Flip the row
    // index rather than the CTM so the resulting image is upright.
    for y in 0..<rows {
      for x in 0..<cols {
        guard let color = palette[g[y][x]] else { continue }  // "." has no entry
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: x * scale, y: (rows - 1 - y) * scale, width: scale, height: scale))
      }
    }
    return ctx.makeImage()
  }

  /// Rasterizes the three static layers for `accent`. `scale` is canvas
  /// pixels per sprite pixel and must be a whole number or the art shimmers.
  /// Callers should hold onto the result — this walks 2 × 48² + 16 × 9 cells,
  /// so it belongs in a `@State`, not in a per-frame draw.
  static func makeLayers(accent: OKLCH, scale: Int) -> Layers? {
    let rgb = accent.sRGB
    let accentCG = CGColor(
      srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1
    )
    let pal = palette(accent: accentCG)
    guard let body = rasterize(bodyGrid, palette: pal, scale: scale),
          let head = rasterize(headGrid, palette: pal, scale: scale),
          let quill = rasterize(quillGrid, palette: pal, scale: scale)
    else { return nil }
    return Layers(
      body: Image(decorative: body, scale: 1).interpolation(.none),
      head: Image(decorative: head, scale: 1).interpolation(.none),
      quill: Image(decorative: quill, scale: 1).interpolation(.none)
    )
  }

  // MARK: - Per-frame drawing

  /// Draws one frame at the context origin.
  ///
  /// - Parameters:
  ///   - unit: points per sprite pixel (the canvas is 48 × `unit` square).
  ///   - t: elapsed **seconds** on one monotonic clock. Never reset it on a
  ///     mode change — each state loops on its own period, so a shared clock
  ///     keeps the motion continuous through the cut.
  static func draw(
    in context: GraphicsContext,
    unit: CGFloat,
    t: Double,
    mode: OwlSpriteMode,
    layers: Layers,
    colors: DynamicColors
  ) {
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
      guard w > 0, h > 0 else { return }
      context.fill(
        Path(CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit,
                    width: CGFloat(w) * unit, height: CGFloat(h) * unit)),
        with: .color(color)
      )
    }

    func layer(_ image: Image, _ ox: Double, _ oy: Double, _ w: Int, _ h: Int) {
      context.draw(image, in: CGRect(
        x: CGFloat(ox) * unit, y: CGFloat(oy) * unit,
        width: CGFloat(w) * unit, height: CGFloat(h) * unit
      ))
    }

    /// Pixel-stepped filled circle (matches the JS scanline `disc`).
    func disc(_ cx: Double, _ cy: Double, _ radius: Double, _ color: Color) {
      var y = Int(floor(cy - radius))
      let yEnd = Int(ceil(cy + radius))
      while y <= yEnd {
        let h = radius * radius - (Double(y) - cy) * (Double(y) - cy)
        if h >= 0 {
          let hw = sqrt(h)
          let x0 = jsRound(cx - hw), x1 = jsRound(cx + hw)
          rect(Double(x0), Double(y), Double(x1 - x0 + 1), 1, color)
        }
        y += 1
      }
    }

    func sparkle(_ cx: Double, _ cy: Double, big: Bool) {
      let x = Double(jsRound(cx)), y = Double(jsRound(cy))
      rect(x, y - 1, 1, 3, colors.gold)
      rect(x - 1, y, 3, 1, colors.gold)
      if big {
        rect(x, y - 2, 1, 1, colors.gold)
        rect(x, y + 2, 1, 1, colors.gold)
        rect(x - 2, y, 1, 1, colors.gold)
        rect(x + 2, y, 1, 1, colors.gold)
      }
      rect(x, y, 1, 1, colors.sparkCore)
    }

    let cyc = cycle(mode)

    // --- blink ---
    let bp = t.truncatingRemainder(dividingBy: cyc) / cyc
    let bw = 0.16 / cyc
    var blink = bp < bw ? sin((bp / bw) * .pi) : 0
    if mode == .ready {
      let bp2 = bp - 0.22                       // the second beat of the double blink
      if bp2 > 0, bp2 < bw { blink = max(blink, sin((bp2 / bw) * .pi)) }
    }

    var gy = 0.0, hx = 0.0, hy = 0.0, lx = 0.0, ly = 0.0, squint = 0.0
    var inkFull = 0, inkPartial = -1, inkP = 0.0, progress = -1.0
    var tip = (x: 28.0, y: 43.0)
    var quillRot = 0.0
    var sparkAngle: Double?

    switch mode {
    case .ready:
      let w = t * tau / readyCycle
      gy = Double(jsRound(sin(w) * 0.9))
      hy = gy + Double(jsRound(sin(w - 0.55) * 0.9))
      hx = Double(jsRound(sin(w * 2) * 1.3))
      lx = max(-1.8, min(1.8, hx * 1.1))
      tip = (28 + hx * 0.5, 43 + gy)
      quillRot = sin(w * 2 + 1) * 0.7

    case .writing:
      let ct = t.truncatingRemainder(dividingBy: writeCycle)
      var li = Int(floor(ct / lineDuration))
      var lp = (ct - Double(li) * lineDuration) / lineDuration
      let paused = li >= inkRows.count
      if paused { li = inkRows.count - 1; lp = 1 }
      inkFull = li; inkPartial = li; inkP = lp
      squint = 0.26
      ly = 1.7; lx = -0.6
      hy = 1 + Double(jsRound(sin(ct * 9) * 0.5))
      gy = Double(jsRound(sin(ct * 9 + 1) * 0.4))
      if paused {
        // Between lines: look up proudly, then drop back.
        let pp = (ct - Double(inkRows.count) * lineDuration) / pauseDuration
        tip = (28, 43 - sin(pp * .pi) * 3)
        ly = 1.2 - sin(pp * .pi) * 2.6
        squint = 0.26 - sin(pp * .pi) * 0.26
        hy = 1 - Double(jsRound(sin(pp * .pi) * 1.4))
      } else {
        tip = (Double(inkX) + lp * (Double(inkLengths[li]) - 0.4),
               Double(inkRows[li]) + (sin(t * 32) > 0 ? 0 : -1))
        quillRot = sin(t * 32) * 0.5
      }

    case .working:
      let ct = t.truncatingRemainder(dividingBy: workCycle)
      let w = t * tau / workCycle
      gy = Double(jsRound(sin(w * 2) * 0.7))
      hy = gy - 1 + Double(jsRound(sin(w * 2 - 0.6) * 0.7))
      hx = Double(jsRound(sin(w) * 1.2))
      lx = sin(w) * 1.6
      ly = -1.5
      inkFull = 2
      progress = ct / workCycle
      tip = (27 + cos(w * 3) * 1.6, 43 + gy + sin(w * 3) * 1.2)
      quillRot = sin(w * 3) * 1.2
      sparkAngle = w
    }

    // --- body + paper ---
    layer(layers.body, 0, gy, spriteSize, spriteSize)
    for i in 0..<inkRows.count {
      var n = 0
      if i < inkFull { n = inkLengths[i] }
      else if i == inkPartial { n = jsRound(inkP * Double(inkLengths[i])) }
      if n > 0 { rect(Double(inkX), Double(inkRows[i]) + gy, Double(n), 1, colors.ink) }
    }
    if progress >= 0 {
      rect(Double(inkX - 1), 44 + gy, 17, 3, colors.paperEdge)
      rect(Double(inkX), 45 + gy, 15, 1, colors.progressTrack)
      rect(Double(inkX), 45 + gy, Double(max(1, jsRound(progress * 15))), 1, colors.accent)
    }

    // --- sparkles passing behind the hat ---
    if let a0 = sparkAngle {
      for i in 0..<3 {
        let a = a0 + Double(i) * tau / 3
        if sin(a) > 0 { continue }
        sparkle(23.5 + cos(a) * 16, 8 + sin(a) * 3.5 + gy, big: false)
      }
    }

    // --- head ---
    layer(layers.head, hx, hy, spriteSize, spriteSize)

    // --- pupils + eyelids ---
    for ex in [eyeLX, eyeRX] {
      let cx = ex + hx + lx, cy = eyeY + hy + ly
      disc(cx, cy, 3.7, colors.pupil)
      disc(cx - 1.3, cy - 1.4, 1.5, colors.pupilHighlight)
      rect(Double(jsRound(cx + 1.6)), Double(jsRound(cy + 1.6)), 1, 1, colors.pupilLowlight)

      let amt = min(1, blink + squint)
      if amt > 0.02 {
        let top = eyeY - eyeR + hy, bot = eyeY + eyeR + hy
        let lidY = top - 1 + amt * (bot - top + 2)
        var y = floor(top) - 1
        while y < lidY {
          let h = eyeR * eyeR - (y - eyeY - hy) * (y - eyeY - hy)
          let hw = h > 0 ? sqrt(h) : 0
          rect(Double(jsRound(ex + hx - hw)), y, Double(jsRound(hw * 2) + 1), 1, colors.bellyF)
          y += 1
        }
        let ly2 = Double(jsRound(lidY))
        let h2 = eyeR * eyeR - (ly2 - eyeY - hy) * (ly2 - eyeY - hy)
        let hw2 = h2 > 0 ? sqrt(h2) : 0
        rect(Double(jsRound(ex + hx - hw2)), ly2, Double(jsRound(hw2 * 2) + 1), 1, colors.shadowD)
      }
    }

    // --- monocle glint ---
    if mode != .ready {
      let gp = t.truncatingRemainder(dividingBy: 2.6) / 2.6
      if gp < 0.3 {
        let s = gp / 0.3
        let gx = eyeRX + hx - 4 + s * 9
        let gyy = eyeY + hy + 4 - s * 9
        if hypot(gx - eyeRX - hx, gyy - eyeY - hy) < eyeR + 1.5 {
          rect(Double(jsRound(gx)), Double(jsRound(gyy)), 1, 2, .white)
          rect(Double(jsRound(gx) + 1), Double(jsRound(gyy) - 1), 1, 2, .white.opacity(0.5))
        }
      }
    }

    // --- quill ---
    let qx = Double(jsRound(tip.x) - quillTip.x)
    let qy = Double(jsRound(tip.y) - quillTip.y + jsRound(quillRot))
    layer(layers.quill, qx, qy, Layers.quillSize.w, Layers.quillSize.h)
    if mode == .writing, inkPartial >= 0, inkP < 1 {
      rect(Double(jsRound(tip.x)), Double(inkRows[inkPartial]) + gy, 1, 1, colors.ink)
    }

    // --- sparkles passing in front of the hat ---
    if let a0 = sparkAngle {
      for i in 0..<3 {
        let a = a0 + Double(i) * tau / 3
        if sin(a) <= 0 { continue }
        sparkle(23.5 + cos(a) * 16, 8 + sin(a) * 3.5 + gy, big: true)
      }
    }
  }
}
