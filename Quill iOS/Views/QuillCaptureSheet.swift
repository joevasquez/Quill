//
//  QuillCaptureSheet.swift
//  Quill (iOS)
//
//  The capture surface — iOS's answer to the Mac's Corner Bloom. Slides up
//  over a scrim carrying the focal orb and whatever the active mode needs.
//  Note-producing modes render their live transcript directly in the note;
//  Edit and Act keep it here because they do not write a note while listening.
//
//  It's the recording UI in full: since home became a launcher, there's no
//  canvas behind it to show progress. Tapping the orb stops and processes;
//  the × discards.
//

import HexCore
import SwiftUI

struct QuillCaptureSheet: View {
  var mode: QuillMode
  var format: AIProcessingMode
  var phase: QuillOrb.Phase
  /// The live partial from the recognizer.
  var transcript: String
  var level: Double
  var statusText: String
  var resultText: String?

  /// Act only: the destination we think this is heading for, and the
  /// destinations the user can correct to.
  var routing: RoutingPreview?

  /// True while audio is actively being captured (drives the Pause/Stop
  /// control row — hidden once we're transcribing/parsing, which can't be
  /// paused or stopped).
  var isRecording: Bool = false
  var isPaused: Bool = false

  var onStop: () -> Void
  var onTogglePause: () -> Void = {}
  var onCancel: () -> Void
  var onPickDestination: (QuillActDestination) -> Void

  struct RoutingPreview {
    var target: QuillActDestination?
    var options: [QuillActDestination]
    /// True once the user has picked, which stops the live intuition.
    var isLocked: Bool
  }

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var theme: QuillTheme { .of(colorScheme) }

  private var isResult: Bool { phase == .result }

  /// Resolved green on completion, else the mode's colour.
  private var accent: OKLCH {
    isResult ? QuillDesign.ModePalette.resolved : mode.palette
  }

  private var badgeText: String {
    switch mode {
    case .auto: "Auto"
    case .edit: "Edit"
    case .act: "Act"
    case .dictate: "Dictate · \(format.iosDisplayName)"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      grabber
      header
      orb
      body_
      if mode == .act, !isResult, let routing {
        routingSection(routing)
          .padding(.top, 16)
      }
      if isRecording {
        controls
          .padding(.top, 18)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 18)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.sheet, style: .continuous)
        .fill(theme.glass)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.sheet, style: .continuous)
            .fill(.ultraThinMaterial)
        )
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.sheet, style: .continuous)
            .strokeBorder(theme.glassBorder, lineWidth: 0.5)
        )
    )
    .padding(.horizontal, 10)
    .padding(.bottom, 24)
  }

  // MARK: - Chrome

  private var grabber: some View {
    Capsule()
      .fill(theme.hair)
      .frame(width: 40, height: 5)
      .padding(.bottom, 12)
  }

  private var header: some View {
    HStack(spacing: 0) {
      HStack(spacing: 7) {
        Circle()
          .fill(accent.color())
          .frame(width: 7, height: 7)
        Text(badgeText)
          .quillFont(13, weight: .bold)
      }
      .foregroundStyle(accent.lightnessCapped(at: theme.isDark ? 0.82 : 0.5).color())
      .padding(.horizontal, 11)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .fill(accent.color(0.14))
      )

      Spacer(minLength: 8)

      Text(statusText)
        .quillFont(11.5, design: .monospaced)
        .tracking(0.3)
        .foregroundStyle(theme.text3)

      Button(action: onCancel) {
        Image(systemName: "xmark")
          .quillFont(12, weight: .semibold)
          .foregroundStyle(theme.text2)
          .frame(width: 26, height: 26)
          .background(Circle().fill(theme.chip))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .padding(.leading, 12)
      .accessibilityLabel("Discard capture")
    }
    .padding(.bottom, 14)
  }

  private var orb: some View {
    QuillCaptureAvatar(
      palette: mode.palette,
      // A paused capture reads as calm: drop the listening motion back to
      // the idle sphere so "paused" is legible at a glance.
      phase: isPaused ? .idle : phase,
      slot: .focal,
      level: isPaused ? 0 : level,
      glow: 1.1
    )
    .accessibilityLabel(orbAccessibilityLabel)
    .padding(.top, 4)
    .padding(.bottom, 16)
  }

  private var orbAccessibilityLabel: String {
    if isResult { return "Capture complete" }
    if isPaused { return "Paused" }
    return isRecording ? "Recording" : "Processing"
  }

  // MARK: - Recording controls

  /// Explicit Pause + Stop — the orb no longer doubles as a hidden stop
  /// button, since "tap the orb to stop" wasn't discoverable.
  private var controls: some View {
    HStack(spacing: 14) {
      Button(action: onTogglePause) {
        VStack(spacing: 5) {
          Image(systemName: isPaused ? "play.fill" : "pause.fill")
            .quillFont(20, weight: .semibold)
            .foregroundStyle(theme.text)
            .frame(width: 58, height: 58)
            .background(Circle().fill(theme.chip))
            .overlay(Circle().strokeBorder(theme.hair, lineWidth: 1))
          Text(isPaused ? "Resume" : "Pause")
            .quillFont(12, weight: .medium)
            .foregroundStyle(theme.text2)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")

      Button(action: onStop) {
        VStack(spacing: 5) {
          Image(systemName: "stop.fill")
            .quillFont(22, weight: .semibold)
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(Circle().fill(accent.color()))
          Text("Stop")
            .quillFont(12, weight: .semibold)
            .foregroundStyle(accent.lightnessCapped(at: theme.isDark ? 0.82 : 0.5).color())
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Stop and process")
    }
  }

  // MARK: - Transcript / result

  @ViewBuilder
  private var body_: some View {
    if isResult, let resultText {
      HStack(spacing: 9) {
        Image(systemName: "checkmark")
          .quillFont(12, weight: .bold)
          .foregroundStyle(.white)
          .frame(width: 24, height: 24)
          .background(Circle().fill(QuillDesign.ModePalette.resolved.color()))
        Text(resultText)
          .quillFont(16, weight: .semibold)
          .foregroundStyle(theme.text)
      }
      .frame(minHeight: 26)
      .transition(.opacity)
    } else if mode == .edit || mode == .act {
      transcriptView
    }
  }

  /// Words fade in as the recognizer produces them. The prototype faked
  /// this with a canned script on a timer; here the pacing is simply
  /// whenever a word actually arrives.
  private var transcriptView: some View {
    let words = transcript.split(separator: " ").map(String.init)
    return Group {
      if words.isEmpty {
        // Once Stop is pressed we're no longer listening — say so, rather
        // than leaving "Listening…" up through the transcription pass.
        Text(isRecording ? "Listening…" : "Transcribing…")
          .quillFont(18)
          .foregroundStyle(theme.text3)
      } else {
        QuillWrap(spacing: 5) {
          ForEach(Array(words.enumerated()), id: \.offset) { _, word in
            Text(word)
              .quillFont(18)
              .foregroundStyle(theme.text)
              .transition(.opacity)
          }
        }
        .animation(reduceMotion ? nil : .easeIn(duration: 0.22), value: words.count)
      }
    }
    .frame(minHeight: 50, alignment: .top)
    .frame(maxWidth: .infinity, alignment: words.isEmpty ? .center : .leading)
    .padding(.horizontal, 6)
  }

  // MARK: - Act routing

  /// Where we think this is going, and a one-tap way to say otherwise.
  ///
  /// Deliberately no confidence percentage: the prototype's number was a
  /// keyword-hit count dressed as model confidence, shown before the parse
  /// that actually decides.
  private func routingSection(_ routing: RoutingPreview) -> some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: routing.target?.systemImage ?? "sparkles")
          .quillFont(18)
          .foregroundStyle(routing.target?.palette.color() ?? theme.text3)
          .frame(width: 22)

        VStack(alignment: .leading, spacing: 1) {
          Text(routing.target?.name ?? "Listening for a destination…")
            .quillFont(15.5, weight: .semibold)
            .foregroundStyle(theme.text)
          Text(routingSubtitle(routing))
            .quillFont(12)
            .foregroundStyle(theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 11)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
          .fill(routing.target != nil ? accent.color(0.12) : theme.card)
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
              .strokeBorder(routing.target != nil ? accent.color(0.5) : theme.hair, lineWidth: 1)
          )
      )

      if !routing.options.isEmpty {
        QuillWrap(spacing: 6) {
          ForEach(routing.options) { d in
            destinationChip(d, isOn: routing.target?.id == d.id)
          }
        }
      }
    }
  }

  private func routingSubtitle(_ routing: RoutingPreview) -> String {
    guard routing.target != nil else { return "Quill will route automatically" }
    return routing.isLocked ? "You picked this" : "Routing here — tap below to change"
  }

  private func destinationChip(_ d: QuillActDestination, isOn: Bool) -> some View {
    Button {
      onPickDestination(d)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: d.systemImage)
          .quillFont(13)
          .foregroundStyle(d.palette.color())
        Text(d.name)
          .quillFont(13.5, weight: isOn ? .semibold : .medium)
          .foregroundStyle(isOn ? theme.text : theme.text2)
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .fill(isOn ? accent.color(0.12) : theme.card)
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .strokeBorder(isOn ? accent.color(0.5) : theme.hair, lineWidth: 1)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Presentation

extension View {
  /// Presents the capture sheet over a modal scrim. The scrim deliberately
  /// consumes taps without dismissing: ending or discarding an active audio
  /// capture must always be an explicit choice.
  func quillCaptureSheet(
    isPresented: Bool,
    reduceMotion: Bool,
    @ViewBuilder sheet: () -> QuillCaptureSheet
  ) -> some View {
    ZStack(alignment: .bottom) {
      self

      if isPresented {
        Color.black.opacity(0.4)
          .ignoresSafeArea()
          .transition(.opacity)
          .contentShape(Rectangle())
          .onTapGesture {}

        sheet()
          .transition(
            reduceMotion
              ? .opacity
              : .move(edge: .bottom).combined(with: .opacity)
          )
      }
    }
    .animation(
      reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.82),
      value: isPresented
    )
  }
}
