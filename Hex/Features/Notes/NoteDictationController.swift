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

  /// Starts or stops a note dictation. On stop, the (optionally cleaned)
  /// transcript is delivered to `insert` on the main actor.
  func toggle(cleanup: Bool, insert: @escaping (String) -> Void) {
    if isRecording {
      stop(cleanup: cleanup, insert: insert)
    } else {
      start()
    }
  }

  private func start() {
    guard !isRecording, !isProcessing else { return }
    errorMessage = nil
    Task {
      @Dependency(\.recording) var recording
      @Dependency(\.soundEffects) var soundEffect
      guard await recording.requestMicrophoneAccess() else {
        errorMessage = "Microphone access needed"
        return
      }
      await recording.startRecording()
      soundEffect.play(.startRecording)
      isRecording = true
      startTime = Date()
    }
  }

  private func stop(cleanup: Bool, insert: @escaping (String) -> Void) {
    guard isRecording else { return }
    isRecording = false
    startTime = nil
    isProcessing = true
    Task {
      @Dependency(\.recording) var recording
      @Dependency(\.transcription) var transcription
      @Dependency(\.soundEffects) var soundEffect
      @Dependency(\.aiProcessing) var aiProcessing
      @Shared(.hexSettings) var hexSettings: HexSettings

      defer { isProcessing = false }
      let audioURL = await recording.stopRecording()
      soundEffect.play(.stopRecording)

      do {
        let options = DecodingOptions(
          language: hexSettings.outputLanguage,
          detectLanguage: hexSettings.outputLanguage == nil,
          chunkingStrategy: .vad
        )
        var text = try await transcription.transcribe(audioURL, hexSettings.selectedModel, options) { _ in }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

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
      } catch {
        noteDictationLogger.error("Note dictation failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = "Transcription failed"
      }
      try? FileManager.default.removeItem(at: audioURL)
    }
  }
}
