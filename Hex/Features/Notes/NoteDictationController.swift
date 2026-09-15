//
//  NoteDictationController.swift
//  Quill (macOS)
//
//  Drives the "dictate into this note" mic button in the Notes editor.
//  A deliberately small, self-contained pipeline — record → transcribe →
//  optional AI cleanup → insert — that bypasses TranscriptionFeature
//  (whose pipeline ends in a paste into another app). One instance per
//  editor; state is published for the toolbar UI.
//
//  Caveat: shares RecordingClient with the global hotkey pipeline. If the
//  user holds the record hotkey while a note dictation is running the two
//  would fight over the recorder — the HUD flow wins; we just surface an
//  error. Rare enough not to interlock in v1.
//

import Dependencies
import Foundation
import HexCore
import os
import Sharing
import WhisperKit

private let noteDictationLogger = HexLog.transcription

@MainActor
final class NoteDictationController: ObservableObject {
  @Published var isRecording = false
  @Published var isProcessing = false
  @Published var startTime: Date?
  @Published var errorMessage: String?
  @Published var liveTranscript = ""

  private var recoveryID: UUID?
  private var checkpointTask: Task<Void, Never>?
  private var recognitionTask: Task<Void, Never>?

  /// Starts or stops a note dictation. On stop, the (optionally cleaned)
  /// transcript is delivered to `insert` on the main actor.
  func toggle(
    cleanup: Bool,
    onPartial: @escaping (String) -> Void = { _ in },
    insert: @escaping (String) -> Void
  ) {
    if isRecording {
      stop(cleanup: cleanup, insert: insert)
    } else {
      start(onPartial: onPartial)
    }
  }

  private func start(onPartial: @escaping (String) -> Void) {
    guard !isRecording, !isProcessing else { return }
    errorMessage = nil
    Task {
      @Dependency(\.recording) var recording
      @Dependency(\.soundEffects) var soundEffect
      @Dependency(\.speechRecognition) var speechRecognition
      guard await recording.requestMicrophoneAccess() else {
        errorMessage = "Microphone access needed"
        return
      }
      let id = UUID()
      let started = Date()
      recoveryID = id
      liveTranscript = ""
      await MacRecordingRecoveryStore.shared.begin(id: id, startedAt: started)
      await recording.startRecording()
      soundEffect.play(.startRecording)
      isRecording = true
      startTime = started

      recognitionTask = Task { @MainActor in
        let stream = await speechRecognition.startRecognition(nil)
        for await partial in stream where !Task.isCancelled {
          liveTranscript = partial
          onPartial(partial)
        }
      }
      checkpointTask = Task { @MainActor in
        var delay: Duration = .seconds(3)
        while !Task.isCancelled {
          try? await Task.sleep(for: delay)
          guard !Task.isCancelled, let recoveryID, let startTime else { continue }
          let destination = MacRecordingRecoveryStore.shared.audioURL(for: recoveryID)
          guard await recording.checkpointCurrentRecording(destination) else { continue }
          MacRecordingRecoveryStore.shared.recordCheckpoint(
            id: recoveryID,
            expectedDuration: Date().timeIntervalSince(startTime),
            liveTranscript: liveTranscript
          )
          delay = .seconds(15)
        }
      }
    }
  }

  private func stop(cleanup: Bool, insert: @escaping (String) -> Void) {
    guard isRecording else { return }
    let startedAt = startTime
    let partialAtStop = liveTranscript
    let activeRecoveryID = recoveryID
    isRecording = false
    startTime = nil
    isProcessing = true
    checkpointTask?.cancel()
    checkpointTask = nil
    recognitionTask?.cancel()
    recognitionTask = nil
    Task {
      @Dependency(\.recording) var recording
      @Dependency(\.transcription) var transcription
      @Dependency(\.soundEffects) var soundEffect
      @Dependency(\.aiProcessing) var aiProcessing
      @Dependency(\.speechRecognition) var speechRecognition
      @Shared(.hexSettings) var hexSettings: HexSettings

      defer { isProcessing = false }
      await speechRecognition.stopRecognition()
      let capturedURL = await recording.stopRecording()
      soundEffect.play(.stopRecording)

      do {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let audioURL: URL
        if let activeRecoveryID {
          audioURL = try await MacRecordingRecoveryStore.shared.secureFinalAudio(
            id: activeRecoveryID,
            sourceURL: capturedURL,
            expectedDuration: elapsed,
            liveTranscript: partialAtStop
          )
        } else {
          audioURL = capturedURL
        }
        let options = DecodingOptions(
          language: hexSettings.outputLanguage,
          detectLanguage: hexSettings.outputLanguage == nil,
          chunkingStrategy: .vad
        )
        var text = try await transcription.transcribe(audioURL, hexSettings.selectedModel, options) { _ in }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
          if let activeRecoveryID {
            await MacRecordingRecoveryStore.shared.markNeedsRecovery(
              id: activeRecoveryID,
              reason: "No speech could be recovered automatically. The audio was kept."
            )
          }
          errorMessage = "No speech detected"
          return
        }

        if cleanup {
          // .notes mode structures the dictation into clean bullet-point
          // prose. AIProcessingClient returns the raw text unchanged when
          // no API key / Pro is configured, so this never blocks insert.
          do {
            text = try await aiProcessing.process(text, .notes, hexSettings.aiProvider, nil, nil, false)
          } catch {
            noteDictationLogger.warning("Note dictation cleanup failed; inserting raw transcript: \(error.localizedDescription, privacy: .public)")
          }
        }

        insert(text)
        soundEffect.play(.pasteTranscript)
        if let activeRecoveryID {
          await MacRecordingRecoveryStore.shared.complete(id: activeRecoveryID, deleteAudio: true)
        }
        recoveryID = nil
        liveTranscript = ""
      } catch {
        noteDictationLogger.error("Note dictation failed: \(error.localizedDescription, privacy: .public)")
        if let activeRecoveryID {
          await MacRecordingRecoveryStore.shared.markNeedsRecovery(
            id: activeRecoveryID,
            reason: error.localizedDescription
          )
        }
        errorMessage = "Transcription failed — recording saved for recovery"
      }
    }
  }
}
