#if os(macOS)
import AppKit
import Dependencies
import HexCore
import Sharing
import SwiftUI
import WhisperKit

struct RecordingRecoverySectionView: View {
  @ObservedObject private var recovery = MacRecordingRecoveryStore.shared
  @State private var showingRecovery = false

  var body: some View {
    Section {
      Button {
        showingRecovery = true
      } label: {
        HStack {
          Label("Recording Recovery", systemImage: "waveform.badge.exclamationmark")
          Spacer()
          if !recovery.recordings.isEmpty {
            Text("\(recovery.recordings.count)")
              .font(.caption.bold())
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(Color.orange.opacity(0.18), in: Capsule())
          }
          Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .buttonStyle(.plain)
    } header: {
      Text("Safety")
    } footer: {
      Text(recovery.recordings.isEmpty
        ? "Interrupted recordings are kept here until their words are safely saved."
        : "\(recovery.recordings.count) recording\(recovery.recordings.count == 1 ? " is" : "s are") waiting for recovery.")
        .settingsCaption()
    }
    .sheet(isPresented: $showingRecovery) {
      MacRecordingRecoveryView(store: recovery)
    }
  }
}

private struct MacRecordingRecoveryView: View {
  @ObservedObject var store: MacRecordingRecoveryStore
  @Environment(\.dismiss) private var dismiss
  @State private var processingID: UUID?
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Recording Recovery").font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(20)
      Divider()

      if store.recordings.isEmpty {
        ContentUnavailableView(
          "Nothing to Recover",
          systemImage: "checkmark.circle",
          description: Text("Interrupted recordings will stay here until their words are safely saved.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(store.recordings) { recording in recoveryCard(recording) }
          }
          .padding(20)
        }
      }
    }
    .frame(width: 620, height: 520)
    .alert("Couldn't Recover Recording", isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
  }

  private func recoveryCard(_ recording: MacRecoveryRecording) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
          Text(durationLabel(recording)).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "waveform.badge.exclamationmark").foregroundStyle(.orange)
      }
      if !recording.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(recording.liveTranscript).font(.callout).lineLimit(4)
      } else {
        Text("Audio was saved. Recover it to rebuild the transcription.")
          .font(.callout).foregroundStyle(.secondary)
      }
      if let reason = recording.failureReason, !reason.isEmpty {
        Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button {
          recover(recording)
        } label: {
          if processingID == recording.id { ProgressView().controlSize(.small) }
          else { Label("Recover to Note", systemImage: "arrow.clockwise") }
        }
        .buttonStyle(.borderedProminent)
        .disabled(processingID != nil)

        if !recording.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Button("Keep Partial") { keepPartial(recording) }.disabled(processingID != nil)
        }
        Button("Show Audio") {
          NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: recording.id)])
        }
        Spacer()
        Button(role: .destructive) { store.discard(id: recording.id) } label: {
          Image(systemName: "trash")
        }
        .accessibilityLabel("Delete recording")
      }
    }
    .padding(16)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: QuillDesign.Radius.card))
  }

  private func recover(_ item: MacRecoveryRecording) {
    processingID = item.id
    Task {
      do {
        @Dependency(\.transcription) var transcription
        @Shared(.hexSettings) var settings: HexSettings
        let options = DecodingOptions(
          language: settings.outputLanguage,
          detectLanguage: settings.outputLanguage == nil,
          chunkingStrategy: .vad
        )
        let raw = try await transcription.transcribe(
          store.audioURL(for: item.id), settings.selectedModel, options
        ) { _ in }
        let text = WhisperOutputCleaner.clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MacRecordingRecoveryError.audioUnavailable }
        let noteID = MacCloudSync.shared.createNote(body: text)
        NoteSelectionState.shared.selectedNoteID = noteID
        store.complete(id: item.id, deleteAudio: true)
      } catch {
        store.markNeedsRecovery(id: item.id, reason: error.localizedDescription)
        errorMessage = error.localizedDescription
      }
      processingID = nil
    }
  }

  private func keepPartial(_ item: MacRecoveryRecording) {
    let text = item.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let noteID = MacCloudSync.shared.createNote(body: text)
    NoteSelectionState.shared.selectedNoteID = noteID
    store.complete(id: item.id, deleteAudio: true)
  }

  private func durationLabel(_ item: MacRecoveryRecording) -> String {
    let seconds = max(item.expectedDuration, item.capturedDuration)
    let minutes = Int(seconds) / 60
    let remainder = Int(seconds) % 60
    return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
  }
}
#endif
