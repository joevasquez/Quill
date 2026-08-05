//
//  QuillHeaderBar.swift
//  Quill (iOS)
//
//  Reusable purple header used at the top of every Quill iOS screen.
//  Carries the Quill wordmark + a serif feather mark on the left and a
//  trio of circular icon buttons on the right (notes list / new note /
//  settings). Extracted from ContentView so future screens (empty home,
//  recording state, action detected) can drop it in without copy-paste.
//
//  All button actions are passed in as closures so the host owns the
//  navigation state — this view stays pure presentation.
//

import SwiftUI
import HexCore

struct QuillHeaderBar: View {
  let onTapList: () -> Void
  let onTapNewNote: () -> Void
  let onTapSettings: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      logoMark

      // Wordmark + feather both dropped 25% from prior sizes (34→26pt
      // serif, 34→26pt feather frame). Trims the brand band so the
      // header doesn't dominate the screen.
      Text("Quill")
        .quillFont(26, weight: .heavy, design: .rounded)
        .foregroundStyle(.white)
        .kerning(0.5)
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)

      Spacer()

      headerButton(
        systemName: "list.bullet",
        accessibilityLabel: "All notes",
        action: onTapList
      )
      headerButton(
        systemName: "square.and.pencil",
        accessibilityLabel: "Start new note",
        action: onTapNewNote
      )
      headerButton(
        systemName: "gearshape",
        accessibilityLabel: "Settings",
        action: onTapSettings
      )
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(headerBackground)
    .shadow(color: .purple.opacity(0.18), radius: 10, y: 6)
  }

  /// Purple background with rounded BOTTOM corners only — top edges
  /// extend full-bleed under the safe area so the status bar shares
  /// the band's color. `UnevenRoundedRectangle` (iOS 16+) handles the
  /// asymmetric radii without a custom Path.
  ///
  /// The gradient is a vertical purple wash with a subtle highlight
  /// at the top edge — softer than the prior 3-color diagonal and
  /// closer to the screenshot reference.
  private var headerBackground: some View {
    UnevenRoundedRectangle(
      topLeadingRadius: 0,
      bottomLeadingRadius: 24,
      bottomTrailingRadius: 24,
      topTrailingRadius: 0,
      style: .continuous
    )
    .fill(
      LinearGradient(
        colors: [
          Color(red: 0.45, green: 0.26, blue: 0.78),  // top — brighter
          Color(red: 0.36, green: 0.18, blue: 0.66),  // bottom — deeper
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .overlay(alignment: .top) {
      // Faint inner highlight at the very top of the gradient — adds
      // depth without turning into a full second band.
      LinearGradient(
        colors: [Color.white.opacity(0.10), .clear],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 24)
      .allowsHitTesting(false)
    }
    .ignoresSafeArea(edges: .top)
  }

  private var logoMark: some View {
    Image("Feather")
      .resizable()
      .renderingMode(.template)
      .aspectRatio(contentMode: .fit)
      .foregroundStyle(.white)
      .frame(width: 26, height: 26)
      .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
  }

  private func headerButton(
    systemName: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      UISelectionFeedbackGenerator().selectionChanged()
      action()
    } label: {
      // Glyph dropped 25% from the prior `title3` (~20pt) to 15pt so
      // the icon reads as restrained meta inside the round button.
      // Frame stays at 36pt to keep the tap target generous (HIG floor
      // is 44pt; the surrounding hit area on a Button extends a bit
      // further than the visible Circle).
      Image(systemName: systemName)
        .quillFont(12, weight: .semibold)
        .foregroundStyle(.white)
        .frame(width: 36, height: 36)
        .background(Circle().fill(Color.white.opacity(0.18)))
        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }
}
