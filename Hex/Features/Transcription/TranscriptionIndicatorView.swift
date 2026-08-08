//
//  TranscriptionIndicatorView.swift
//  Hex
//
//  Always-visible floating HUD pill. Shows the current mode
//  (Dictate / Edit / Action), a live waveform during recording,
//  and an elapsed timer. Click to cycle modes; drag to reposition.
//

import HexCore
import Inject
import Pow
import SwiftUI

// MARK: - Data Types

struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject

  // MARK: Status — what the pipeline is doing right now

  enum Status: Equatable {
    case idle
    case recording
    case transcribing
    case aiProcessing
  }

  // MARK: Mode — user-selected dictation kind

  enum Mode: String, CaseIterable, Equatable {
    case auto = "Auto"
    case dictate = "Dictate"
    case edit = "Edit"
    case action = "Action"

    var icon: String {
      switch self {
      case .auto:    return "sparkles"
      case .dictate: return "waveform"
      case .edit:    return "pencil"
      // Outline `bolt` (not `bolt.fill`) so the four mode glyphs share one
      // light stroke weight — a consistent set.
      case .action:  return "bolt"
      }
    }

    var accentColor: Color {
      switch self {
      case .auto:    return .gray
      case .dictate: return .blue
      case .edit:    return .orange
      case .action:  return .purple
      }
    }

    var next: Mode {
      let all = Mode.allCases
      let idx = all.firstIndex(of: self)!
      return all[(idx + 1) % all.count]
    }
  }

  // MARK: Inputs

  var status: Status
  var mode: Mode
  var meter: Meter
  var recordingStartTime: Date?
  /// Pre-formatted hotkey hint, e.g. "Hold ⌥ Space to dictate".
  var hotkeyHint: String
  /// Shown when the user tries to record in Edit mode without a
  /// selection — e.g. "Highlight text first".
  var editMessage: String?
  /// Non-nil after an inline edit lands — drives the ✓/✗ pill.
  var pendingEditResult: TranscriptionFeature.PendingEditResult?
  /// Live partial transcript from SFSpeechRecognizer. Rendered in a
  /// fixed-height card below the pill while recording.
  var partialTranscript: String = ""
  /// Connected & authenticated integrations, shown as toggleable icon
  /// buttons under the pill in Action mode. Empty means no row renders.
  var actionIntegrations: [Integration.Identifier] = []
  /// User's hard-locked Action integration, if any. The locked button
  /// shows full tint + a white ring.
  var lockedActionIntegration: Integration.Identifier?
  /// When mode is .auto, the detected sub-mode (dictate/edit/action).
  var autoDetectedMode: Mode = .dictate
  /// Non-nil for a few seconds after an Auto run lands — drives the
  /// "wrong mode?" strip that re-runs the same transcript elsewhere.
  var rerouteOffer: TranscriptionFeature.RerouteOffer?
  /// Formatted cycle-mode hotkey, shown on the first re-route chip.
  var cycleHotkeyHint: String?
  var isPinnedToTop: Bool = false
  var onCycleMode: () -> Void
  var onEditAccept: () -> Void
  var onEditUndo: () -> Void
  var onToggleActionIntegration: (Integration.Identifier) -> Void = { _ in }
  var onReroute: (Mode) -> Void = { _ in }

  // MARK: Body

  var body: some View {
    VStack(spacing: 6) {
      pill
        .onTapGesture { onCycleMode() }
        .compositingGroup()
        .shadow(color: .black.opacity(isPinnedToTop ? 0 : 0.35), radius: 8, y: 4)
        .shadow(color: shadowGlow.opacity(isPinnedToTop ? 0 : 0.3), radius: 12)

      // Action mode: row of toggleable integration buttons. Sits between
      // the pill and the live transcript card so the user can pick a
      // target before they start dictating.
      if mode == .action, !actionIntegrations.isEmpty {
        actionIntegrationRow
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      // Live transcript while recording — fixed-height card under the pill.
      if status == .recording, !partialTranscript.isEmpty {
        LiveTranscriptCard(text: partialTranscript)
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      // "Highlight text first" banner
      if let msg = editMessage {
        Text(msg)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.white.opacity(0.9))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            Capsule().fill(.red.opacity(0.7))
          )
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      // Reject / Accept buttons after inline edit
      if pendingEditResult != nil {
        editAcceptancePill
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      // "Wrong mode?" strip after an Auto run
      if let rerouteOffer {
        RerouteOfferCard(
          appliedMode: rerouteOffer.appliedMode,
          alternatives: rerouteOffer.alternatives,
          shortcutHint: cycleHotkeyHint,
          onReroute: onReroute
        )
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.snappy(duration: 0.3), value: status)
    .animation(.snappy(duration: 0.25), value: mode)
    .animation(.snappy(duration: 0.25), value: editMessage != nil)
    .animation(.snappy(duration: 0.25), value: pendingEditResult != nil)
    .animation(.snappy(duration: 0.25), value: partialTranscript.isEmpty)
    .animation(.snappy(duration: 0.25), value: lockedActionIntegration)
    .animation(.snappy(duration: 0.25), value: rerouteOffer)
    .enableInjection()
  }

  // MARK: - Action mode integration picker

  /// Horizontal row of integration chips. Only shown in Action mode when
  /// at least one integration is connected. Tapping toggles the lock; the
  /// locked one wins over whatever the LLM picks. Each chip carries a
  /// `fn + N` shortcut badge so the user can toggle without a click.
  private var actionIntegrationRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(Array(actionIntegrations.prefix(9).enumerated()), id: \.offset) { offset, id in
          IntegrationToggleButton(
            identifier: id,
            isLocked: lockedActionIntegration == id,
            shortcutNumber: offset + 1,
            onTap: { onToggleActionIntegration(id) }
          )
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .fill(.black.opacity(0.25))
        )
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    )
  }

  // MARK: - Pill Content

  @ViewBuilder
  private var pill: some View {
    HStack(spacing: 12) {
      if status == .idle, pendingEditResult != nil {
        // Show "Edit applied" while the accept/undo pill is up
        HStack(spacing: 6) {
          Image(systemName: "pencil")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.green)
          Text("Edit applied")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
        }
      } else {
        modeChip
        statusContent
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(pillBackground)
  }

  @ViewBuilder
  private var statusContent: some View {
    switch status {
    case .idle:        idleHint
    case .recording:   recordingContent
    case .transcribing: processingLabel("Transcribing...")
    case .aiProcessing: processingLabel("Enhancing...")
    }
  }

  // MARK: Reject / Accept buttons

  private var editAcceptancePill: some View {
    HStack(spacing: 2) {
      Button {
        onEditUndo()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
          Text("Reject")
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .fill(.white.opacity(0.08))
        )
      }
      .buttonStyle(.plain)

      Button {
        onEditAccept()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
          Text("Keep")
            .font(.system(size: 11, weight: .semibold))
          RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
            .fill(.white.opacity(0.25))
            .frame(width: 14, height: 14)
            .overlay(
              Image(systemName: "return")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
            )
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
            .fill(.green)
        )
      }
      .buttonStyle(.plain)
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(.black.opacity(0.7))
    )
  }

  // MARK: Mode chip — always visible on the left

  /// The display mode for the chip: Auto shows the detected sub-mode
  /// icon/color when live; otherwise shows the sparkles icon.
  private var displayMode: Mode {
    mode == .auto && status != .idle ? autoDetectedMode : mode
  }

  private var modeChip: some View {
    HStack(spacing: 5) {
      Image(systemName: displayMode.icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(displayMode.accentColor)
        .contentTransition(.symbolEffect(.replace))

      if mode == .auto {
        HStack(spacing: 3) {
          Text("Auto")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
          if status != .idle {
            Text("·")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.white.opacity(0.4))
            Text(autoDetectedMode.rawValue)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(autoDetectedMode.accentColor)
          }
        }
        .contentTransition(.numericText())
      } else {
        Text(mode.rawValue)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .contentTransition(.numericText())
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(.white.opacity(0.08))
    )
  }

  // MARK: Idle — hotkey hint + status dot

  private var idleHint: some View {
    HStack(spacing: 12) {
      Text(hotkeyHint)
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(.white.opacity(0.45))

      Circle()
        .fill(.white.opacity(0.35))
        .frame(width: 8, height: 8)
    }
  }

  // MARK: Recording — red dot + waveform + timer

  private var recordingContent: some View {
    HStack(spacing: 10) {
      // Pulsing red dot
      Circle()
        .fill(.red)
        .frame(width: 8, height: 8)
        .shadow(color: .red.opacity(0.6), radius: 4)
        .modifier(PulseModifier())

      WaveformView(power: meter.averagePower)

      if let startTime = recordingStartTime {
        RecordingTimerView(startTime: startTime)
      }
    }
  }

  // MARK: Processing — label with shimmer

  @State private var shimmerTick = 0

  private func processingLabel(_ text: String) -> some View {
    HStack(spacing: 6) {
      ProgressView()
        .controlSize(.mini)
        .scaleEffect(0.8)

      Text(text)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.8))
    }
    .changeEffect(.shine(angle: .degrees(0), duration: 0.8), value: shimmerTick)
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(0.5))
        shimmerTick += 1
      }
    }
  }

  // MARK: - Visual Helpers

  @ViewBuilder
  private var pillBackground: some View {
    if isPinnedToTop {
      let shape = UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 14,
        topTrailingRadius: 0
      )
      shape
        .fill(.ultraThinMaterial)
        .overlay(shape.fill(backgroundTint))
        .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 1))
    } else {
      Capsule()
        .fill(.ultraThinMaterial)
        .overlay(Capsule().fill(backgroundTint))
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }
  }

  private var backgroundTint: Color {
    switch status {
    case .idle:         return .black.opacity(0.3)
    case .recording:    return .red.opacity(0.15 + meter.averagePower * 0.15)
    case .transcribing: return .blue.opacity(0.12)
    case .aiProcessing: return .purple.opacity(0.12)
    }
  }

  private var shadowGlow: Color {
    switch status {
    case .idle:         return displayMode.accentColor
    case .recording:    return .red
    case .transcribing: return .blue
    case .aiProcessing: return .purple
    }
  }

}

// MARK: - Waveform View

/// Five bars that react to audio power, tallest in the center.
/// Flattens to a resting state during silence.
private struct WaveformView: View {
  var power: Double

  private let barCount = 5
  private let barWidth: CGFloat = 3
  private let spacing: CGFloat = 2
  private let minHeight: CGFloat = 4
  private let maxHeight: CGFloat = 28

  var body: some View {
    HStack(spacing: spacing) {
      ForEach(0..<barCount, id: \.self) { index in
        RoundedRectangle(cornerRadius: barWidth / 2)
          .fill(.white.opacity(0.9))
          .frame(width: barWidth, height: heightFor(index))
      }
    }
    .animation(.interpolatingSpring(stiffness: 280, damping: 14), value: power)
  }

  private func heightFor(_ index: Int) -> CGFloat {
    // Center bars respond more to audio level.
    let center = Double(barCount - 1) / 2.0
    let dist = abs(Double(index) - center) / center
    let scale = 1.0 - dist * 0.4

    let clamped = min(1.0, power * 2.5)
    let h = minHeight + (maxHeight - minHeight) * clamped * scale
    return max(minHeight, h)
  }
}

// MARK: - Recording Timer

/// Elapsed timer that ticks once per second.
private struct RecordingTimerView: View {
  var startTime: Date

  var body: some View {
    TimelineView(.periodic(from: startTime, by: 1.0)) { context in
      let elapsed = max(0, context.date.timeIntervalSince(startTime))
      let mins = Int(elapsed) / 60
      let secs = Int(elapsed) % 60
      Text(String(format: "%d:%02d", mins, secs))
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.7))
    }
  }
}

// MARK: - Pulse Modifier

/// Loops opacity between 1.0 and 0.3 for a recording-dot pulse.
private struct PulseModifier: ViewModifier {
  @State private var on = true

  func body(content: Content) -> some View {
    content
      .opacity(on ? 1.0 : 0.3)
      .onAppear {
        QuillMotion.run(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
          on = false
        }
      }
  }
}

// MARK: - Live transcript card

/// Card under the HUD that shows the live partial transcript from
/// `SFSpeechRecognizer`. Width is fixed (520pt). Height grows with the
/// content from one line up to four; beyond that the head truncates so
/// the most recent words are always visible (`.truncationMode(.head)`).
/// `reservesSpace: false` lets the card shrink back when the user pauses.
struct LiveTranscriptCard: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 13, weight: .regular))
      .foregroundStyle(.white.opacity(0.92))
      .multilineTextAlignment(.leading)
      .lineLimit(4, reservesSpace: false)
      .truncationMode(.head)
      .frame(width: 520, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
              .fill(.black.opacity(0.35))
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
          .strokeBorder(.white.opacity(0.18), lineWidth: 1)
      )
      .compositingGroup()
      .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
      .animation(.easeOut(duration: 0.18), value: text)
  }
}

// MARK: - Auto-mode re-route card

/// Shown for a few seconds after an Auto-mode run lands, offering to re-run
/// the same transcript through a different branch.
///
/// The point is that the transcript still exists — a misclassification should
/// cost one keystroke, not another take. Deliberately a quiet strip rather
/// than a modal: it appears after the fact, so being ignorable is the feature.
/// Shared by every HUD display mode.
struct RerouteOfferCard: View {
  let appliedMode: TranscriptionIndicatorView.Mode
  let alternatives: [TranscriptionIndicatorView.Mode]
  /// Formatted cycle-mode hotkey (e.g. "⌥⇧M"), shown on the first
  /// alternative so the keystroke is learnable. Nil when unassigned.
  var shortcutHint: String?
  let onReroute: (TranscriptionIndicatorView.Mode) -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text(appliedMode.pastTenseLabel)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.55))

      Text("Wrong?")
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(.white.opacity(0.45))

      ForEach(Array(alternatives.enumerated()), id: \.element) { index, mode in
        Button { onReroute(mode) } label: {
          HStack(spacing: 4) {
            Image(systemName: mode.icon)
              .font(.system(size: 9, weight: .bold))
            Text(mode.rawValue)
              .font(.system(size: 11, weight: .semibold))
            // Only the first chip carries the hotkey: it's where a tap of
            // the cycle key lands, and repeating it on every chip would
            // read as "any of these".
            if index == 0, let shortcutHint {
              Text(shortcutHint)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                  RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
                    .fill(.white.opacity(0.15))
                )
            }
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .fill(mode.orbPalette.color().opacity(0.28))
          )
          .overlay(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .strokeBorder(mode.orbPalette.color().opacity(0.5), lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Re-run as \(mode.rawValue)")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(.ultraThinMaterial)
        .overlay(Capsule().fill(.black.opacity(0.35)))
    )
    .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    .compositingGroup()
    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
  }
}

extension TranscriptionIndicatorView.Mode {
  /// What just happened, for the re-route card's lead-in.
  var pastTenseLabel: String {
    switch self {
    case .dictate: "Dictated"
    case .edit:    "Edited"
    case .action:  "Sent to agent"
    case .auto:    "Done"
    }
  }
}

// MARK: - Integration toggle button

/// Labeled chip rendered in the action-mode picker row under the HUD:
/// `[icon] Name [fn+N]`. Locked state inverts to a tinted fill so the
/// active routing target reads at a glance. The shortcut badge mirrors
/// the `fn + N` global hotkey so users learn the keystroke without a
/// tooltip.
struct IntegrationToggleButton: View {
  let identifier: Integration.Identifier
  let isLocked: Bool
  let shortcutNumber: Int
  let onTap: () -> Void

  private var integration: Integration? {
    Integration.all.first { $0.identifier == identifier }
  }

  /// Compact name for the chip — drop the "Apple" prefix so "Apple
  /// Reminders" → "Reminders", but keep "Google" prefixes (e.g.
  /// "Google Cal") since we need to distinguish Google Calendar from
  /// Apple Calendar. Gmail is already short enough on its own.
  private var shortName: String {
    let name = integration?.name ?? identifier.rawValue
    if name.hasPrefix("Apple ") { return String(name.dropFirst("Apple ".count)) }
    if identifier == .googleCalendar { return "G Cal" }
    return name
  }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 6) {
        Image(systemName: integration?.systemImage ?? "questionmark.circle")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(isLocked ? .white : tintColor)
          .frame(width: 14, height: 14)

        Text(shortName)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white.opacity(isLocked ? 1.0 : 0.85))
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)

        Text("fn\(shortcutNumber)")
          .font(.system(size: 9, weight: .semibold).monospacedDigit())
          .foregroundStyle(.white.opacity(isLocked ? 0.85 : 0.45))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
              .fill(.white.opacity(isLocked ? 0.22 : 0.10))
          )
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .fill(isLocked ? tintColor : Color.white.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
          .strokeBorder(
            isLocked ? Color.white.opacity(0.55) : Color.white.opacity(0.10),
            lineWidth: isLocked ? 1.0 : 0.5
          )
      )
    }
    .buttonStyle(.plain)
    .help("\(integration?.name ?? identifier.rawValue) — fn+\(shortcutNumber)")
    .accessibilityLabel("\(integration?.name ?? identifier.rawValue) — \(isLocked ? "locked" : "unlocked"). Shortcut: function key plus \(shortcutNumber).")
  }

  private var tintColor: Color {
    Color(hex: integration?.tintHex ?? "") ?? .purple
  }
}

// MARK: - Preview

#Preview("HUD States") {
  VStack(spacing: 20) {
    TranscriptionIndicatorView(
      status: .idle, mode: .dictate,
      meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold ⌥ Space to dictate",
      onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
    )
    TranscriptionIndicatorView(
      status: .idle, mode: .edit,
      meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold ⌥ Space to edit",
      editMessage: "Highlight text first",
      onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
    )
    TranscriptionIndicatorView(
      status: .recording, mode: .dictate,
      meter: .init(averagePower: 0.5, peakPower: 0.7),
      recordingStartTime: Date().addingTimeInterval(-5),
      hotkeyHint: "Hold ⌥ Space to dictate",
      onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
    )
    TranscriptionIndicatorView(
      status: .idle, mode: .edit,
      meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold ⌥ Space to edit",
      pendingEditResult: .init(original: "old", edited: "new", sourceAppBundleID: nil),
      onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
    )
    TranscriptionIndicatorView(
      status: .aiProcessing, mode: .edit,
      meter: .init(averagePower: 0, peakPower: 0),
      hotkeyHint: "Hold ⌥ Space to edit",
      onCycleMode: {}, onEditAccept: {}, onEditUndo: {}
    )
  }
  .padding(40)
  .background(.black)
}
