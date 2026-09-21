//
//  NoteTextView.swift
//  HexCore (cross-platform)
//
//  Renders a chunk of note body text with light markdown awareness:
//  `- ` and `* ` become visual bullets with a real `•` glyph,
//  `**Heading**` / `## Heading` render as bold headings, and inline
//  markdown (bold, italic, code, links) is rendered via
//  `AttributedString(markdown:)`. SwiftUI's built-in `Text(markdown:)`
//  doesn't do block-level lists, so we walk line-by-line and stack
//  the pieces vertically — otherwise Notes-mode output shows up as
//  literal hyphens instead of proper bullets.
//
//  Lives in HexCore so iOS notes and the macOS synced-notes viewer
//  render identically.
//

import SwiftUI

public struct SpeakerPillDescriptor: Equatable, Sendable {
  public let transcriptionID: UUID
  public let speakerID: String
  public let title: String
  public let colorIndex: Int

  public init(transcriptionID: UUID, speakerID: String, title: String, colorIndex: Int) {
    self.transcriptionID = transcriptionID
    self.speakerID = speakerID
    self.title = title
    self.colorIndex = colorIndex
  }
}

public struct NoteTextView: View {
  public let text: String
  public var font: Font = .body
  public var textColor: Color = .primary
  public var bulletColor: Color = .primary
  public var headingColor: Color? = nil
  /// Speaker labels keyed by their zero-based line index. Reading surfaces can
  /// opt into interactive pills while exports and older clients keep rendering
  /// the same portable plain text.
  public var speakerPills: [Int: SpeakerPillDescriptor] = [:]
  public var onTapSpeakerPill: ((SpeakerPillDescriptor) -> Void)? = nil
  /// When set, `- [ ]` / `- [x]` lines render as tappable checkboxes and
  /// a tap calls back with the line index (into `text.components(
  /// separatedBy: "\n")`) so the owner can flip the marker in storage —
  /// see `MarkdownCheckbox.toggleLine`. When nil, checkboxes render as
  /// static glyphs (macOS read-only viewer).
  public var onToggleCheckbox: ((Int) -> Void)? = nil

  public init(
    text: String,
    font: Font = .body,
    textColor: Color = .primary,
    bulletColor: Color = .primary,
    headingColor: Color? = nil,
    speakerPills: [Int: SpeakerPillDescriptor] = [:],
    onTapSpeakerPill: ((SpeakerPillDescriptor) -> Void)? = nil,
    onToggleCheckbox: ((Int) -> Void)? = nil
  ) {
    self.text = text
    self.font = font
    self.textColor = textColor
    self.bulletColor = bulletColor
    self.headingColor = headingColor
    self.speakerPills = speakerPills
    self.onTapSpeakerPill = onTapSpeakerPill
    self.onToggleCheckbox = onToggleCheckbox
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        render(line: line, index: index)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var lines: [String] {
    text.components(separatedBy: "\n")
  }

  @ViewBuilder
  private func render(line: String, index: Int) -> some View {
    let leadingSpaces = line.prefix { $0 == " " }.count
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if let speaker = speakerPills[index] {
      let tint = speakerColor(speaker.colorIndex)
      Button {
        onTapSpeakerPill?(speaker)
      } label: {
        HStack(spacing: 5) {
          Text(speaker.title)
          Image(systemName: "pencil")
            .font(.system(size: 9, weight: .bold))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 1))
      }
      .buttonStyle(.plain)
      .disabled(onTapSpeakerPill == nil)
      .accessibilityLabel("Rename \(speaker.title)")
    } else if trimmed.isEmpty {
      Color.clear.frame(height: 6)
    } else if let (checked, content) = matchCheckbox(trimmed) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Button {
          onToggleCheckbox?(index)
        } label: {
          Image(systemName: checked ? "checkmark.square.fill" : "square")
            .font(font)
            .foregroundStyle(checked ? bulletColor : textColor.opacity(0.55))
        }
        .buttonStyle(.plain)
        .disabled(onToggleCheckbox == nil)
        Text(inline(content))
          .font(font)
          .strikethrough(checked, color: textColor.opacity(0.5))
          .foregroundStyle(checked ? textColor.opacity(0.5) : textColor)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(leadingSpaces) * 6)
    } else if let heading = matchHeading(trimmed) {
      Text(inline(heading))
        .font(font.weight(.bold))
        .foregroundStyle(headingColor ?? textColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    } else if let bullet = matchBullet(trimmed) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("•")
          .font(font)
          .foregroundStyle(bulletColor)
        Text(inline(bullet))
          .font(font)
          .foregroundStyle(textColor)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(leadingSpaces) * 6)
    } else {
      Text(inline(trimmed))
        .font(font)
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func speakerColor(_ index: Int) -> Color {
    let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]
    return palette[index.modulo(palette.count)]
  }

  private func matchBullet(_ s: String) -> String? {
    if s.hasPrefix("- ") { return String(s.dropFirst(2)) }
    if s.hasPrefix("* ") { return String(s.dropFirst(2)) }
    if s.hasPrefix("• ") { return String(s.dropFirst(2)) }
    return nil
  }

  private func matchCheckbox(_ s: String) -> (checked: Bool, content: String)? {
    if s.hasPrefix("- [ ] ") { return (false, String(s.dropFirst(6))) }
    if s.hasPrefix("- [x] ") || s.hasPrefix("- [X] ") { return (true, String(s.dropFirst(6))) }
    return nil
  }

  private func matchHeading(_ s: String) -> String? {
    if s.hasPrefix("**"), s.hasSuffix("**"), s.count > 4 {
      return String(s.dropFirst(2).dropLast(2))
    }
    if s.hasPrefix("### ") { return String(s.dropFirst(4)) }
    if s.hasPrefix("## ") { return String(s.dropFirst(3)) }
    if s.hasPrefix("# ") { return String(s.dropFirst(2)) }
    return nil
  }

  private func inline(_ s: String) -> AttributedString {
    (try? AttributedString(
      markdown: s,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(s)
  }
}

private extension Int {
  func modulo(_ divisor: Int) -> Int {
    guard divisor > 0 else { return 0 }
    let remainder = self % divisor
    return remainder >= 0 ? remainder : remainder + divisor
  }
}
