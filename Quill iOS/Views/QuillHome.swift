//
//  QuillHome.swift
//  Quill (iOS)
//
//  The Orb Hero launcher. Home is no longer a note canvas — it's the place
//  you start a capture from. Dictating here creates a new note and opens
//  it; appending to an existing note happens in that note's composer.
//
//  Layout (design handoff §6): headline, mode rail + its sub-row, a
//  centred keyboard/trigger pair, and a swipeable Recent rail.
//

import HexCore
import SwiftUI

/// Wordmark left, round buttons right, sitting on the page background.
///
/// Replaces the purple gradient band: the design language is flat and
/// material-first, so a saturated header block is the one piece of
/// elevation the spec explicitly doesn't want.
struct QuillTopBar: View {
  var onTapList: () -> Void
  var onTapNewNote: () -> Void
  var onTapSettings: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  var body: some View {
    HStack(spacing: 10) {
      Image("Feather")
        .resizable()
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(QuillDesign.brand.color())
        .frame(width: 24, height: 24)

      Text("Quill")
        .font(.system(size: 24, weight: .bold))
        .tracking(-0.5)
        .foregroundStyle(theme.text)

      Spacer()

      button("list.bullet", "Notes", onTapList)
      button("square.and.pencil", "New note", onTapNewNote)
      button("gearshape", "Settings", onTapSettings)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(theme.text2)
        .frame(width: 40, height: 40)
        .background(
          Circle()
            .fill(theme.chip)
            .overlay(Circle().strokeBorder(theme.hair, lineWidth: 0.5))
        )
        .contentShape(Circle())
    }
    .buttonStyle(QuillPressStyle())
    .accessibilityLabel(label)
  }
}

struct QuillHome: View {
  @Binding var mode: QuillMode
  @Binding var format: AIProcessingMode
  /// Destinations excluded from routing for this capture.
  @Binding var mutedDestinations: Set<String>

  var notes: [Note]
  var destinations: [QuillActDestination]
  var hiddenFormats: Set<AIProcessingMode>

  var onTapTrigger: () -> Void
  var onHoldTrigger: () -> Void
  var onReleaseTrigger: () -> Void
  var onTapKeyboard: () -> Void
  var onOpenNote: (Note) -> Void
  var onAddFormat: () -> Void
  var onAddDestination: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 12)

      VStack(spacing: 18) {
        Text("Ready when you are.")
          .font(.system(size: 28, weight: .semibold))
          .tracking(-0.5)
          .foregroundStyle(theme.text)
          .frame(maxWidth: .infinity)
          .multilineTextAlignment(.center)

        VStack(spacing: 10) {
          QuillModeRail(mode: $mode, order: QuillMode.homeOrder)
          subRow
        }

        triggerPair
      }
      .padding(.horizontal, 18)

      Spacer(minLength: 12)

      if !notes.isEmpty {
        recentRail
      }
    }
  }

  // MARK: - Mode sub-row

  @ViewBuilder
  private var subRow: some View {
    switch mode {
    case .dictate:
      QuillFormatChips(format: $format, hidden: hiddenFormats, onAddCustom: onAddFormat)
    case .act:
      QuillActChips(
        destinations: destinations,
        disabled: $mutedDestinations,
        onAdd: onAddDestination
      )
    case .auto, .edit:
      // Auto has nothing to configure — that's the point. Edit never
      // appears on home.
      EmptyView()
    }
  }

  // MARK: - Trigger

  private var triggerPair: some View {
    VStack(spacing: 8) {
      HStack(spacing: 16) {
        // The keyboard opens a TYPED command for the agent — meaningful in
        // Auto and Act, but not Dictate (dictation is pure voice-to-note,
        // there's nothing to type a command about).
        if mode != .dictate {
          keyboardButton
        }
        QuillTriggerButton(
          mode: mode,
          onTap: onTapTrigger,
          onHold: onHoldTrigger,
          onRelease: onReleaseTrigger
        )
      }

      // The handoff sold tap as "hands-free" (a capture that ends itself).
      // It doesn't — tap starts and tap stops — so the caption says what
      // actually happens.
      Text("Tap to start · hold to talk")
        .font(.system(size: 12))
        .foregroundStyle(theme.text3)
    }
  }

  private var keyboardButton: some View {
    Button(action: onTapKeyboard) {
      Image(systemName: "keyboard")
        .font(.system(size: 24, weight: .regular))
        .foregroundStyle(theme.text2)
        .frame(width: QuillDesign.OrbSize.triggerRing, height: QuillDesign.OrbSize.triggerRing)
        .background(
          Circle()
            .fill(theme.chip)
            .overlay(Circle().strokeBorder(theme.hair, lineWidth: 1))
        )
        .contentShape(Circle())
    }
    .buttonStyle(QuillPressStyle())
    .accessibilityLabel("Type instead")
  }

  // MARK: - Recent

  private var recentRail: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recent")
        .font(.system(size: 13, weight: .semibold))
        .tracking(0.3)
        .textCase(.uppercase)
        .foregroundStyle(theme.text3)
        .padding(.horizontal, 20)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(notes.prefix(3)) { note in
            QuillNoteCard(note: note) { onOpenNote(note) }
              // ~80% of the screen so the next card peeks, cueing the swipe.
              .containerRelativeFrame(.horizontal, count: 5, span: 4, spacing: 12)
              .scrollTransition(.interactive, axis: .horizontal) { view, phase in
                view.opacity(phase.isIdentity ? 1 : 0.75)
              }
          }
        }
        .scrollTargetLayout()
        .padding(.horizontal, 16)
      }
      .scrollTargetBehavior(.viewAligned)
    }
    .padding(.bottom, 30)
  }
}

// MARK: - Trigger button

/// Tap starts a capture; press-and-hold is push-to-talk, resolving on
/// release. The ring adopts the mode hue while held.
struct QuillTriggerButton: View {
  var mode: QuillMode
  var onTap: () -> Void
  var onHold: () -> Void
  var onRelease: () -> Void

  var size: CGFloat = QuillDesign.OrbSize.triggerRing
  var orbSize: CGFloat = QuillDesign.OrbSize.trigger

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var theme: QuillTheme { .of(colorScheme) }

  @State private var isHolding = false
  @State private var holdTask: Task<Void, Never>?

  /// Past this, a press is push-to-talk rather than a tap.
  private static let holdThreshold: Duration = .milliseconds(280)

  var body: some View {
    QuillOrb(palette: mode.palette, phase: .idle, size: orbSize)
      .frame(width: size, height: size)
      .background(
        Circle()
          .fill(theme.chip)
          .overlay(
            Circle().strokeBorder(
              isHolding ? mode.palette.color(0.7) : theme.hair,
              lineWidth: 1.5
            )
          )
      )
      .scaleEffect(isHolding ? 1.1 : 1)
      .animation(
        reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.6),
        value: isHolding
      )
      .contentShape(Circle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in beginPress() }
          .onEnded { _ in endPress() }
      )
      .accessibilityLabel("Start capture")
      .accessibilityHint("Tap to start, or hold to talk and release when done")
      .accessibilityAddTraits(.isButton)
  }

  private func beginPress() {
    guard holdTask == nil, !isHolding else { return }
    holdTask = Task {
      try? await Task.sleep(for: Self.holdThreshold)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        isHolding = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onHold()
      }
    }
  }

  private func endPress() {
    holdTask?.cancel()
    holdTask = nil
    if isHolding {
      isHolding = false
      onRelease()
    } else {
      onTap()
    }
  }
}

// MARK: - Note card

/// A note at a glance — used by the Recent rail.
struct QuillNoteCard: View {
  var note: Note
  var onOpen: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: 8) {
        Text(note.displayTitle)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(theme.text)
          .lineLimit(1)

        Text(NoteContent.stripPhotos(from: note.body))
          .font(.system(size: 14))
          .foregroundStyle(theme.text2)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)

        QuillNoteMeta(note: note)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(theme.card)
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
              .strokeBorder(theme.hair, lineWidth: 0.5)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(QuillPressStyle())
  }
}

/// location · date · word count
struct QuillNoteMeta: View {
  var note: Note
  var size: CGFloat = 12.5

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  var body: some View {
    HStack(spacing: 6) {
      if let place = note.location?.placeName {
        Text(place)
        Text("·")
      }
      Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
      Text("·")
      Text("\(note.wordCount) words")
    }
    .font(.system(size: size))
    .foregroundStyle(theme.text3)
    .lineLimit(1)
  }
}

// MARK: - Press feedback

/// The one press treatment: a quick squeeze, per the handoff's .92 / .12–.18s.
struct QuillPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
  }
}
