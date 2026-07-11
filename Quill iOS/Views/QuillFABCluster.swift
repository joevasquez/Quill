//
//  QuillFABCluster.swift
//  Quill (iOS)
//
//  Single + button at the bottom of the home screen that fans up into
//  two vertically-stacked FABs (dictate, photo) when tapped. The mode
//  dropdown floats up alongside the dictate button on its leading edge.
//
//  One-button capture: the mic FAB is the only voice entry point. A tap
//  starts a dictation (Auto routing hands command-sounding transcripts
//  to the agent — see `quill.autoActionRouting`); a LONG-PRESS forces an
//  Action recording for when you want the agent explicitly. The old
//  separate bolt FAB is gone.
//
//  Recording state: the + button flips to a red stop button — single
//  tap to stop, routed to whichever mode started the recording.
//

import HexCore
import SwiftUI

struct QuillFABCluster: View {
  @ObservedObject var vm: RecordingViewModel
  @Binding var modeSelectionRaw: String
  let customModes: [CustomAIMode]
  let visibleBuiltInModes: [AIProcessingMode]
  let hasAPIKey: Bool
  let onTapCamera: () -> Void
  let onTapAction: () -> Void
  let onTapMic: () -> Void
  let onTapType: () -> Void
  let onRequestSettings: () -> Void

  @State private var expanded = false

  /// Visible diameter of each round FAB.
  private let fabSize: CGFloat = 60
  /// Outer slot — gives shadows + glows room without spilling into
  /// neighbours. ~20pt buffer past `fabSize` is the working minimum.
  private let fabSlot: CGFloat = 76
  /// + button diameter — matches `fabSize` for visual symmetry.
  private let plusSize: CGFloat = 60

  // MARK: - Recording-state booleans

  private var isAnyRecording: Bool {
    vm.phase == .recording
  }

  /// Action mode is in its post-recording parse phase — surfaced on the
  /// + button as a teal spinner so "we heard you and we're thinking" is
  /// visible without a dedicated bolt FAB.
  private var isActionParsing: Bool {
    vm.phase == .actionParsing
  }

  // MARK: - Body

  var body: some View {
    VStack(alignment: .trailing, spacing: 14) {
      if expanded {
        // Top: mode dropdown to the LEFT of the dictate button.
        // The dropdown is system-Menu-backed so its popup floats above
        // all of this — no clipping concerns from the cluster.
        HStack(spacing: 12) {
          QuillModeDropdown(
            selectionRaw: $modeSelectionRaw,
            customModes: customModes,
            visibleBuiltInModes: visibleBuiltInModes,
            hasAPIKey: hasAPIKey,
            onRequestAPIKeySetup: onRequestSettings
          )
          dictateFAB
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))

        photoFAB
          .transition(.move(edge: .bottom).combined(with: .opacity))

        typeFAB
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      plusButton
    }
    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: expanded)
  }

  // MARK: - Trigger button (+ when idle, stop when recording)

  /// Tapped when the user wants to either expand the cluster or stop
  /// the in-flight recording. Branches on `isAnyRecording`:
  /// - idle → toggle the expanded stack
  /// - recording → fire the matching stop (dictate or action) directly,
  ///   no expand step. Single tap to stop.
  private var plusButton: some View {
    Button {
      UISelectionFeedbackGenerator().selectionChanged()
      if isAnyRecording {
        // Route to whichever toggle started the recording so the right
        // VM method handles the stop.
        if vm.isActionRecording {
          onTapAction()
        } else {
          onTapMic()
        }
        expanded = false
      } else if !isActionParsing {
        expanded.toggle()
      }
    } label: {
      ZStack {
        // Filled circle — purple when idle, red when recording, teal
        // while the agent is parsing. The color IS the state indicator.
        Circle()
          .fill(
            LinearGradient(
              colors: plusColors,
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: plusSize, height: plusSize)
          .shadow(color: plusColors[0].opacity(0.4), radius: 8, y: 4)

        if isActionParsing {
          ProgressView()
            .tint(.white)
            .controlSize(.regular)
        } else {
          Image(systemName: isAnyRecording ? "stop.fill" : "plus")
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white)
            // Rotation only applies to the +. Stop glyph never rotates;
            // expanding has no meaning while recording.
            .rotationEffect(.degrees(expanded && !isAnyRecording ? 45 : 0))
        }
      }
      .frame(width: fabSlot, height: fabSlot)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(plusAccessibilityLabel)
  }

  private var plusColors: [Color] {
    if isAnyRecording { return [Color.red, Color.red.opacity(0.82)] }
    if isActionParsing { return [QuillDesign.actionAccent, QuillDesign.actionAccent.opacity(0.82)] }
    return [Color.purple, Color.purple.opacity(0.82)]
  }

  private var plusAccessibilityLabel: String {
    if isAnyRecording { return "Stop recording" }
    if isActionParsing { return "Working on your action" }
    return expanded ? "Hide actions" : "Show actions"
  }

  // MARK: - Dictate (tap) / Action (long-press)

  private var dictateFAB: some View {
    let recording = isAnyRecording
    let tint: Color = recording ? .red : .purple

    return Button {
      if recording {
        // Stop whichever mode started (defensive — the stack usually
        // collapses at record-start, but keep the tap meaningful).
        vm.isActionRecording ? onTapAction() : onTapMic()
      } else {
        onTapMic()
      }
      // Collapse after tap — the recording state is apparent from the
      // + button turning red.
      expanded = false
    } label: {
      fabBubble(
        glyph: recording ? "stop.fill" : "mic.fill",
        tint: tint,
        glyphSize: 22
      )
    }
    .buttonStyle(.plain)
    .simultaneousGesture(
      // Long-press = force Action mode (the agent), bypassing Auto
      // routing. Tap still dictates.
      LongPressGesture(minimumDuration: 0.45).onEnded { _ in
        guard !recording, !isActionParsing else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onTapAction()
        expanded = false
      }
    )
    .accessibilityLabel(recording ? "Stop recording" : "Start dictating (hold for an action)")
  }

  // MARK: - Photo

  private var photoFAB: some View {
    Button {
      onTapCamera()
      expanded = false
    } label: {
      fabBubble(glyph: "camera.fill", tint: .purple, glyphSize: 22)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add photo")
  }

  // MARK: - Type a command

  private var typeFAB: some View {
    Button {
      onTapType()
      expanded = false
    } label: {
      fabBubble(glyph: "keyboard", tint: QuillDesign.actionAccent, glyphSize: 20)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Type a command")
  }

  // MARK: - Shared bubble

  /// The visual circle used by every FAB except + (which has its own
  /// recording-indicator extras). Centralized so tint changes only
  /// touch one place.
  private func fabBubble(glyph: String, tint: Color, glyphSize: CGFloat) -> some View {
    ZStack {
      Circle()
        .fill(
          LinearGradient(
            colors: [tint, tint.opacity(0.82)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: fabSize, height: fabSize)
        .shadow(color: tint.opacity(0.35), radius: 8, y: 4)

      Image(systemName: glyph)
        .font(.system(size: glyphSize, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(width: fabSlot, height: fabSlot)
  }
}
