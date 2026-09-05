//
//  RecordingRecoveryView.swift
//  Quill (iOS)
//
//  A neutral recovery inbox for interrupted captures of any kind.
//

import HexCore
import SwiftUI

struct RecordingRecoveryView: View {
  @ObservedObject var store: RecordingRecoveryStore
  var onRecover: (RecoveryRecording) async throws -> UUID?
  var onKeepDraft: (RecoveryRecording) -> UUID?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  @State private var processingID: UUID?
  @State private var errorMessage: String?
  @State private var pendingDelete: RecoveryRecording?

  var body: some View {
    NavigationStack {
      Group {
        if store.recordings.isEmpty {
          ContentUnavailableView(
            "Nothing to Recover",
            systemImage: "checkmark.circle",
            description: Text("Interrupted recordings will appear here until their words are safely saved.")
          )
        } else {
          List(store.recordings) { recording in
            recoveryCard(recording)
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
        }
      }
      .background(theme.page.ignoresSafeArea())
      .navigationTitle("Recording Recovery")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
    .alert("Couldn't Recover Recording", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
    .confirmationDialog(
      "Delete this recording?",
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Recording", role: .destructive) {
        if let pendingDelete { store.discard(id: pendingDelete.id) }
        pendingDelete = nil
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      Text("This removes both the saved audio and its partial transcript.")
    }
  }

  private func recoveryCard(_ recording: RecoveryRecording) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.headline)
          Text(durationLabel(recording))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "waveform.badge.exclamationmark")
          .foregroundStyle(.orange)
          .font(.title3)
      }

      if !recording.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(recording.liveTranscript)
          .font(.subheadline)
          .foregroundStyle(theme.text2)
          .lineLimit(4)
      } else {
        Text("Audio was saved. Recover it to rebuild the transcription.")
          .font(.subheadline)
          .foregroundStyle(theme.text3)
      }

      if let reason = recording.failureReason, !reason.isEmpty {
        Label(reason, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        Button {
          recover(recording)
        } label: {
          if processingID == recording.id {
            ProgressView().controlSize(.small)
          } else {
            Label("Recover", systemImage: "arrow.clockwise")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(processingID != nil)

        if !recording.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Button("Keep Partial") {
            _ = onKeepDraft(recording)
          }
          .buttonStyle(.bordered)
          .disabled(processingID != nil)
        }

        Spacer()

        Button(role: .destructive) { pendingDelete = recording } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(processingID != nil)
        .accessibilityLabel("Delete recording")
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(theme.card)
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .strokeBorder(theme.hair, lineWidth: 0.5)
        )
    )
  }

  private func recover(_ recording: RecoveryRecording) {
    processingID = recording.id
    store.markProcessing(id: recording.id)
    Task {
      do {
        _ = try await onRecover(recording)
      } catch {
        store.markNeedsRecovery(id: recording.id, reason: error.localizedDescription)
        errorMessage = error.localizedDescription
      }
      processingID = nil
    }
  }

  private func durationLabel(_ recording: RecoveryRecording) -> String {
    let seconds = max(recording.capturedDuration, recording.expectedDuration)
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: seconds) ?? "Saved recording"
  }
}
