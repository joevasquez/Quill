//
//  QuillRecordingLiveActivity.swift
//  QuillWidget
//
//  Lock Screen and Dynamic Island controls for an active recording.
//

import ActivityKit
import AppIntents
import HexCore
import SwiftUI
import WidgetKit

struct QuillRecordingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: QuillRecordingActivityAttributes.self) { context in
      lockScreen(context)
        .activityBackgroundTint(Color.black.opacity(0.88))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label("Quill", systemImage: "waveform")
            .font(.headline)
        }
        DynamicIslandExpandedRegion(.trailing) {
          recordingTimer(context.state)
            .font(.headline.monospacedDigit())
        }
        DynamicIslandExpandedRegion(.bottom) {
          controls(context.state)
        }
      } compactLeading: {
        Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
          .foregroundStyle(.purple)
      } compactTrailing: {
        recordingTimer(context.state)
          .font(.caption2.monospacedDigit())
          .frame(maxWidth: 48)
      } minimal: {
        Image(systemName: "waveform")
          .foregroundStyle(.purple)
      }
      .keylineTint(.purple)
    }
  }

  private func lockScreen(_ context: ActivityViewContext<QuillRecordingActivityAttributes>) -> some View {
    VStack(spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Label("Quill is recording", systemImage: "waveform")
            .font(.headline)
          Text(context.state.isPaused ? "Paused" : context.state.modeLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        recordingTimer(context.state)
          .font(.title3.bold().monospacedDigit())
      }
      controls(context.state)
    }
    .padding(16)
  }

  private func controls(_ state: QuillRecordingActivityAttributes.ContentState) -> some View {
    HStack(spacing: 10) {
      Button(intent: QuillToggleRecordingPauseIntent()) {
        Label(state.isPaused ? "Resume" : "Pause", systemImage: state.isPaused ? "play.fill" : "pause.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .tint(.white.opacity(0.16))

      Button(intent: QuillStopRecordingIntent()) {
        Label("Stop & Save", systemImage: "stop.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
    }
  }

  @ViewBuilder
  private func recordingTimer(_ state: QuillRecordingActivityAttributes.ContentState) -> some View {
    if state.isPaused {
      Text(Self.duration(state.elapsedSeconds))
    } else {
      Text(timerInterval: state.referenceDate...Date.distantFuture, countsDown: false)
    }
  }

  private static func duration(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration.rounded()))
    if total >= 3_600 {
      return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
