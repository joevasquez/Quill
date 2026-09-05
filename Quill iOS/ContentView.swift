//
//  ContentView.swift
//  Quill (iOS)
//
//  Main screen: record → transcribe → optional AI clean-up → share.
//

import AVFoundation
import Combine
import HexCore
import os
import SwiftUI
import UIKit
import WhisperKit

/// A dictation that Auto left as a note, still re-runnable as an action.
///
/// Holds what's needed to take it back out of the note: the exact text that
/// was appended, and whether this capture is what created the note (in which
/// case retracting should take the empty shell with it).
struct NoteRerouteOffer: Equatable {
  let transcript: String
  let noteID: UUID
  let appendedText: String
  let createdNote: Bool
}

/// Connects one note-producing audio capture to its provisional paragraph.
/// The ID is independent from RecordingViewModel's private session token and
/// prevents delayed recognizer callbacks from touching a later recording.
private struct ActiveNoteCapture: Equatable {
  let sessionID: UUID
  let noteID: UUID
  let createdNote: Bool
  let navigateOnFinalize: Bool
}

/// How long a note capture stays re-routable. Matches the macOS HUD window.
let noteRerouteWindowSeconds: Double = 10

@MainActor
final class RecordingViewModel: ObservableObject {
  enum Phase: Equatable {
    case idle
    case requestingPermission
    case recording
    case transcribing
    case aiProcessing
    case actionParsing
    case done
    case error(String)
  }

  @Published var phase: Phase = .idle
  @Published var rawTranscript: String = ""
  @Published var processedTranscript: String = ""
  @Published var livePartial: String = ""
  @Published var meterLevel: Float = 0
  @Published var elapsedSeconds: TimeInterval = 0
  /// True while the recording is paused (engine suspended, file kept open).
  /// Only meaningful during `.recording`.
  @Published var isPaused = false
  /// Set when an AI post-processing call failed and we fell back to
  /// the raw transcript. Cleared on the next successful run.
  @Published var aiErrorMessage: String?
  /// Set when an Action recording finishes parsing — one or more
  /// intents; ContentView presents the confirmation sheet in response.
  @Published var parsedMultiIntents: [ActionIntent]?
  /// True when Auto routing (not the user) classified this recording as
  /// an action — drives the sheet's "Save to note instead" escape hatch.
  var wasAutoRouted: Bool = false
  /// Set when a dictation was appended to a voice-targeted note ("add
  /// milk to my groceries note") instead of the active note. ContentView
  /// shows a confirmation pill and skips the default append.
  @Published var noteTargetBanner: String?
  /// Set for a few seconds after an Auto capture lands in a note, so a
  /// command the classifier read as dictation can be re-run through the
  /// agent without saying it again. The counterpart to the confirmation
  /// sheet's "Save to note instead", which covers the other direction.
  @Published var noteRerouteOffer: NoteRerouteOffer?
  private var noteRerouteExpiry: Task<Void, Never>?
  /// Set when the transcript matched a saved routine's trigger phrase —
  /// `parsedMultiIntents` then carries the routine's stored steps and the
  /// multi sheet honors `matchedRoutine.autoRun`.
  @Published var matchedRoutine: Routine?
  /// Set when the transcript was a routine-authoring request ("new
  /// routine: when I say ship it, …") and the LLM produced a draft.
  /// ContentView presents the save-routine sheet in response.
  @Published var routineDraft: RoutineDraft?
  /// True when the current recording was started via the Action FAB.
  var isActionRecording: Bool = false
  /// True while an Edit-mode revision is in flight against the model.
  @Published var isEditingNote: Bool = false
  /// Why the last note edit didn't land. Separate from `aiErrorMessage`
  /// because that one is rendered by the home screen's status pill, which
  /// is invisible from the pushed note detail where edits are triggered.
  @Published var noteEditError: String?
  /// True while the WhisperKit model is loading (first launch, or
  /// after the user changes models in Settings). Surfaced in the
  /// status area so the user knows why the first transcription is
  /// slower than subsequent ones — otherwise it looks like AI
  /// processing is hanging.
  @Published var isPreparingModel: Bool = false

  /// Where the agent may route the next action: the destinations left
  /// enabled on the Act chip row, plus anything pinned with an `@` mention
  /// in a typed command. ContentView keeps `routable` in sync; the typed
  /// path sets `pinned` at submit time.
  ///
  /// Before this existed the chip toggles were computed and then dropped on
  /// the floor — muting an app changed the row's look and nothing else.
  var actTargeting: ActTargeting = .unrestricted

  private var recorder = IOSRecordingClient.shared
  private var whisperKit: WhisperKit?
  private var timerTask: Task<Void, Never>?
  private var transcriptionTask: Task<Void, Never>?
  private var recordingSessionID = UUID()
  private var recordingStartedAt: Date?
  private var recordingPausedAt: Date?
  private var accumulatedPauseDuration: TimeInterval = 0
  private var lastRecordingHealthCheckSecond = -1
  private var lastRecoveryCheckpointSecond = -1
  private var currentRecoveryID: UUID?
  private var currentRecordingURL: URL?
  private let recoveryStore = RecordingRecoveryStore.shared
  private let liveActivity = IOSRecordingLiveActivityController.shared
  private var cancellables: Set<AnyCancellable> = []

  /// Prepare (download if needed + load) the Whisper model for
  /// `modelName` ahead of any recording. Doing this on app launch
  /// means the first real transcription doesn't block on a 1–2
  /// minute WhisperKit init. Safe to call multiple times — it's a
  /// no-op when the requested model is already loaded.
  func prewarmModel(_ modelName: String) async {
    // Already loaded and matching? Nothing to do.
    if whisperKit != nil, whisperKit?.modelFolder?.lastPathComponent == modelName {
      return
    }
    isPreparingModel = true
    defer { isPreparingModel = false }
    do {
      whisperKit = try await WhisperKit(
        WhisperKitConfig(model: modelName, download: true)
      )
      print("RecordingViewModel: prewarmed Whisper model \(modelName)")
    } catch {
      // Non-fatal: if pre-warm fails (offline, corrupt cache, etc.)
      // the normal transcription path will retry on first record.
      print("RecordingViewModel: prewarm failed for \(modelName): \(error.localizedDescription)")
    }
  }

  init() {
    // Mirror the recorder's published live partial onto our own @Published so
    // SwiftUI views observing the VM get live updates during recording.
    recorder.$livePartialTranscript
      .receive(on: RunLoop.main)
      .sink { [weak self] text in
        self?.livePartial = text
      }
      .store(in: &cancellables)

    recorder.$fatalCaptureError
      .compactMap { $0 }
      .receive(on: RunLoop.main)
      .sink { [weak self] message in
        guard let self, self.phase == .recording else { return }
        self.timerTask?.cancel()
        _ = self.recorder.stopRecording()
        self.checkpointRecovery()
        self.markCurrentRecoveryNeedsAttention(reason: message)
        Task { await self.liveActivity.end(elapsed: self.elapsedSeconds) }
        self.phase = .error("Recording stopped because audio could not be saved. Your live transcript was kept. \(message)")
      }
      .store(in: &cancellables)

    recorder.$isSystemInterrupted
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] interrupted in
        guard let self, self.phase == .recording else { return }
        if interrupted {
          if self.recordingPausedAt == nil { self.recordingPausedAt = Date() }
          self.isPaused = true
          self.meterLevel = 0
          self.checkpointRecovery()
          Task { await self.liveActivity.update(isPaused: true, elapsed: self.elapsedSeconds) }
        } else if !self.recorder.isManuallyPaused {
          if let recordingPausedAt = self.recordingPausedAt {
            self.accumulatedPauseDuration += Date().timeIntervalSince(recordingPausedAt)
          }
          self.recordingPausedAt = nil
          self.isPaused = false
          Task { await self.liveActivity.update(isPaused: false, elapsed: self.elapsedSeconds) }
        }
      }
      .store(in: &cancellables)
  }

  var displayedText: String {
    processedTranscript.isEmpty ? rawTranscript : processedTranscript
  }

  var hasResult: Bool {
    !rawTranscript.isEmpty
  }

  func toggleRecording(
    model: String,
    mode: AIProcessingMode,
    provider: AIProvider,
    voiceCommandsEnabled: Bool,
    customSystemPrompt: String? = nil,
    captureMode: QuillMode = .auto
  ) async {
    switch phase {
    case .idle, .done, .error:
      isActionRecording = false
      wasAutoRouted = false
      await startRecording(model: model, mode: mode, provider: provider, captureMode: captureMode)
    case .recording:
      if isActionRecording {
        await stopAndParseAction(model: model, provider: provider)
      } else {
        await stopAndProcess(
          model: model,
          mode: mode,
          provider: provider,
          voiceCommandsEnabled: voiceCommandsEnabled,
          customSystemPrompt: customSystemPrompt,
          captureMode: captureMode
        )
      }
    default:
      break
    }
  }

  /// Throw the take away — the capture sheet's ×. Stops the recorder and
  /// drops the audio without transcribing it.
  func discardRecording() {
    guard phase == .recording else { return }
    timerTask?.cancel()
    transcriptionTask?.cancel()
    // Invalidating the session id makes any in-flight transcription
    // callback a no-op if one is somehow already running.
    recordingSessionID = UUID()
    _ = recorder.stopRecording()
    if let currentRecoveryID { recoveryStore.discard(id: currentRecoveryID) }
    clearCurrentRecovery()
    Task { await liveActivity.end(elapsed: elapsedSeconds) }
    rawTranscript = ""
    processedTranscript = ""
    livePartial = ""
    isActionRecording = false
    wasAutoRouted = false
    isPaused = false
    phase = .idle
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  /// Pause or resume the in-progress recording. No-op unless we're
  /// actively recording. If the engine fails to resume, we leave it
  /// paused rather than silently losing audio.
  func togglePause() {
    guard phase == .recording else { return }
    if isPaused {
      if recorder.resume() {
        if let recordingPausedAt {
          accumulatedPauseDuration += Date().timeIntervalSince(recordingPausedAt)
        }
        recordingPausedAt = nil
        isPaused = false
        Task { await liveActivity.update(isPaused: false, elapsed: elapsedSeconds) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
      }
    } else {
      recorder.pause()
      recordingPausedAt = Date()
      isPaused = true
      meterLevel = 0
      checkpointRecovery()
      Task { await liveActivity.update(isPaused: true, elapsed: elapsedSeconds) }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
  }

  func toggleActionRecording(
    model: String,
    provider: AIProvider
  ) async {
    switch phase {
    case .idle, .done, .error:
      isActionRecording = true
      wasAutoRouted = false
      parsedMultiIntents = nil
      matchedRoutine = nil
      routineDraft = nil
      await startRecording(model: model, mode: .off, provider: provider, captureMode: .act)
    case .recording:
      await stopAndParseAction(model: model, provider: provider)
    default:
      break
    }
  }

  private func startRecording(
    model: String,
    mode: AIProcessingMode,
    provider: AIProvider,
    captureMode: QuillMode
  ) async {
    phase = .requestingPermission
    let granted = await recorder.requestPermission()
    guard granted else {
      phase = .error("Microphone permission required. Enable it in Settings > Quill.")
      return
    }

    // Speech recognition permission is best-effort; failure just disables the
    // live preview (Whisper-based final transcript still works).
    _ = await recorder.requestSpeechPermission()

    transcriptionTask?.cancel()
    recordingSessionID = UUID()
    rawTranscript = ""
    processedTranscript = ""
    livePartial = ""
    elapsedSeconds = 0
    isPaused = false
    recordingPausedAt = nil
    accumulatedPauseDuration = 0
    lastRecordingHealthCheckSecond = -1
    lastRecoveryCheckpointSecond = -1
    aiErrorMessage = nil

    do {
      let url = try recorder.startRecording()
      recordingStartedAt = Date()
      currentRecordingURL = url
      currentRecoveryID = recoveryStore.begin(audioURL: url, startedAt: recordingStartedAt ?? Date())
      phase = .recording
      await liveActivity.start(modeLabel: captureMode.label, startedAt: recordingStartedAt ?? Date())
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()

      // Meter + elapsed timer
      timerTask?.cancel()
      timerTask = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          if !self.isPaused {
            self.meterLevel = self.recorder.averagePower
            self.elapsedSeconds = self.activeRecordingDuration()
            let wholeSecond = Int(self.elapsedSeconds)
            if wholeSecond != self.lastRecordingHealthCheckSecond {
              self.lastRecordingHealthCheckSecond = wholeSecond
              _ = self.recorder.recoverIfNeeded()
              if wholeSecond == 0 || wholeSecond - self.lastRecoveryCheckpointSecond >= 5 {
                self.lastRecoveryCheckpointSecond = wholeSecond
                self.checkpointRecovery()
              }
            }
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    } catch {
      phase = .error("Couldn't start recording: \(error.localizedDescription)")
    }
  }

  private func stopAndProcess(
    model: String,
    mode: AIProcessingMode,
    provider: AIProvider,
    voiceCommandsEnabled: Bool,
    customSystemPrompt: String? = nil,
    captureMode: QuillMode = .auto
  ) async {
    timerTask?.cancel()
    let expectedDuration = activeRecordingDuration()
    let url = recorder.stopRecording()
    elapsedSeconds = expectedDuration
    checkpointRecovery()
    if let currentRecoveryID { recoveryStore.markProcessing(id: currentRecoveryID) }
    await liveActivity.end(elapsed: expectedDuration)
    phase = .transcribing
    UIImpactFeedbackGenerator(style: .light).impactOccurred()

    guard let url else {
      markCurrentRecoveryNeedsAttention(reason: "Recording file was not produced.")
      phase = .error("Recording file was not produced")
      return
    }

    let sessionID = recordingSessionID
    transcriptionTask?.cancel()
    transcriptionTask = Task {
      do {
        if whisperKit == nil || whisperKit?.modelFolder?.lastPathComponent != model {
          whisperKit = try await WhisperKit(
            WhisperKitConfig(model: model, download: true)
          )
        }

        let capturedDuration = recorder.recordedDuration(at: url) ?? 0
        HexLog.recording.info(
          "iOS recording stopped elapsed=\(expectedDuration, privacy: .public)s captured=\(capturedDuration, privacy: .public)s"
        )
        let decodeOptions: DecodingOptions? = switch IOSLongRecordingPolicy.transcriptionStrategy(
          for: capturedDuration
        ) {
        case .continuous:
          nil
        case .voiceActivityChunks:
          DecodingOptions(concurrentWorkerCount: 1, chunkingStrategy: .vad)
        }
        let results = try await whisperKit!.transcribe(
          audioPath: url.path,
          decodeOptions: decodeOptions
        )
        let rawText = results.map(\.text).joined(separator: " ")
        let cleaned = WhisperOutputCleaner.clean(rawText)
        let text = voiceCommandsEnabled
          ? VoiceCommandSubstituter.substitute(in: cleaned)
          : cleaned
        if text != cleaned {
          print("RecordingViewModel: applied voice-command substitutions")
        }

        guard sessionID == recordingSessionID else { return }

        rawTranscript = text

        if text.isEmpty {
          markCurrentRecoveryNeedsAttention(reason: "No speech was detected in the captured audio.")
          phase = .error("No speech detected. Try again.")
          return
        }

        guard IOSLongRecordingPolicy.audit(
          elapsedDuration: expectedDuration,
          capturedDuration: capturedDuration
        ) == .complete else {
          markCurrentRecoveryNeedsAttention(reason: "The saved audio ended earlier than the recording timer.")
          phase = .error(
            "The microphone stopped early after \(Self.formatDuration(capturedDuration)) of a \(Self.formatDuration(expectedDuration)) recording. Quill kept the captured audio and recovered transcript instead of silently calling it complete."
          )
          return
        }

        // Voice-targeted note append — "add milk to my groceries note"
        // goes into the NAMED note, not the active one. Checked before
        // Auto routing because it's more specific than the action
        // keywords ("add to" would otherwise wake the agent). Only fires
        // when a note actually matches; otherwise falls through.
        if !isActionRecording,
           let target = NoteTargetMatcher.match(text),
           let note = NotesStore.shared.sortedNotes.first(where: {
             $0.displayTitle.localizedCaseInsensitiveContains(target.noteName)
           }) {
          NotesStore.shared.appendToNote(id: note.id, text: target.content)
          noteTargetBanner = "Added to \u{201C}\(note.displayTitle)\u{201D}"
          Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.noteTargetBanner = nil
          }
          // Mark handled so the default active-note append is skipped.
          isActionRecording = true
          completeCurrentRecovery()
          phase = .done
          UINotificationFeedbackGenerator().notificationOccurred(.success)
          return
        }

        // Auto routing: when the dictation sounds like a command ("remind
        // me…", "add to todoist…"), hand it to the agent pipeline instead
        // of appending to the note. Apple Reminders/Calendar need no
        // setup, so action capability is always present on iOS — the
        // classifier's keywords decide.
        //
        // Only Auto routes. Picking Dictate explicitly is the user saying
        // "this is a note" — a command-shaped sentence stays a note.
        // Act never reaches here (it starts as an action recording).
        let autoRouting = UserDefaults.standard.object(forKey: QuillIOSSettingsKey.autoActionRouting) as? Bool
          ?? QuillIOSSettingsKey.defaultAutoActionRouting
        if autoRouting, captureMode == .auto, !isActionRecording,
           AutoModeClassifier.resolve(
             transcript: text,
             hasSelection: false,
             hasIntegrations: true
           ) == .action {
          // Flip the routing flags so downstream handlers (note append,
          // sheet presentation) treat this result as an action — and so
          // the sheet offers "Save to note instead" as the undo path.
          isActionRecording = true
          wasAutoRouted = true
          await routeActionTranscript(text, provider: provider, sessionID: sessionID)
          if case .error(let message) = phase {
            markCurrentRecoveryNeedsAttention(reason: message)
          } else {
            completeCurrentRecovery()
          }
          return
        }

        let shouldRunAI = mode != .off || customSystemPrompt != nil
        if shouldRunAI {
          phase = .aiProcessing
          do {
            let processed = try await TextAIClient.process(
              text: text,
              mode: mode,
              provider: provider,
              customSystemPrompt: customSystemPrompt
            )
            guard sessionID == recordingSessionID else { return }
            processedTranscript = processed
          } catch {
            guard sessionID == recordingSessionID else { return }
            processedTranscript = ""
            aiErrorMessage = "AI \(mode.displayName) failed — \(error.localizedDescription)"
            HexLog.aiProcessing.error("TextAIClient failed: \(error.localizedDescription, privacy: .public)")
          }
        } else {
          aiErrorMessage = nil
        }

        guard sessionID == recordingSessionID else { return }
        phase = .done
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      } catch {
        guard sessionID == recordingSessionID else { return }
        markCurrentRecoveryNeedsAttention(reason: error.localizedDescription)
        phase = .error("Transcription failed: \(error.localizedDescription)")
      }
    }
    await transcriptionTask?.value
  }

  private func stopAndParseAction(
    model: String,
    provider: AIProvider
  ) async {
    timerTask?.cancel()
    let expectedDuration = activeRecordingDuration()
    let url = recorder.stopRecording()
    elapsedSeconds = expectedDuration
    checkpointRecovery()
    if let currentRecoveryID { recoveryStore.markProcessing(id: currentRecoveryID) }
    await liveActivity.end(elapsed: expectedDuration)
    phase = .transcribing
    UIImpactFeedbackGenerator(style: .light).impactOccurred()

    guard let url else {
      markCurrentRecoveryNeedsAttention(reason: "Recording file was not produced.")
      phase = .error("Recording file was not produced")
      return
    }

    let sessionID = recordingSessionID
    transcriptionTask?.cancel()
    transcriptionTask = Task {
      do {
        if whisperKit == nil || whisperKit?.modelFolder?.lastPathComponent != model {
          whisperKit = try await WhisperKit(
            WhisperKitConfig(model: model, download: true)
          )
        }

        let capturedDuration = recorder.recordedDuration(at: url) ?? 0
        HexLog.recording.info(
          "iOS action recording stopped elapsed=\(expectedDuration, privacy: .public)s captured=\(capturedDuration, privacy: .public)s"
        )
        let decodeOptions: DecodingOptions? = switch IOSLongRecordingPolicy.transcriptionStrategy(
          for: capturedDuration
        ) {
        case .continuous:
          nil
        case .voiceActivityChunks:
          DecodingOptions(concurrentWorkerCount: 1, chunkingStrategy: .vad)
        }
        let results = try await whisperKit!.transcribe(
          audioPath: url.path,
          decodeOptions: decodeOptions
        )
        let rawText = results.map(\.text).joined(separator: " ")
        let cleaned = WhisperOutputCleaner.clean(rawText)

        guard sessionID == recordingSessionID else { return }
        rawTranscript = cleaned

        if cleaned.isEmpty {
          markCurrentRecoveryNeedsAttention(reason: "No speech was detected in the captured audio.")
          phase = .error("No speech detected. Try again.")
          return
        }

        guard IOSLongRecordingPolicy.audit(
          elapsedDuration: expectedDuration,
          capturedDuration: capturedDuration
        ) == .complete else {
          markCurrentRecoveryNeedsAttention(reason: "The saved audio ended earlier than the recording timer.")
          phase = .error(
            "The microphone stopped early after \(Self.formatDuration(capturedDuration)) of a \(Self.formatDuration(expectedDuration)) recording. Quill kept the captured audio and recovered transcript instead of silently calling it complete."
          )
          return
        }

        await routeActionTranscript(cleaned, provider: provider, sessionID: sessionID)
        if case .error(let message) = phase {
          markCurrentRecoveryNeedsAttention(reason: message)
        } else {
          completeCurrentRecovery()
        }
      } catch {
        guard sessionID == recordingSessionID else { return }
        markCurrentRecoveryNeedsAttention(reason: error.localizedDescription)
        phase = .error("Action parsing failed: \(error.localizedDescription)")
      }
    }
    await transcriptionTask?.value
  }

  private func activeRecordingDuration(at date: Date = Date()) -> TimeInterval {
    guard let recordingStartedAt else { return 0 }
    let currentPause = recordingPausedAt.map { date.timeIntervalSince($0) } ?? 0
    return max(0, date.timeIntervalSince(recordingStartedAt) - accumulatedPauseDuration - currentPause)
  }

  private static func formatDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration.rounded()))
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
  }

  /// Links this audio file to the note that is receiving its live words.
  func associateCurrentRecovery(with noteID: UUID) {
    guard let currentRecoveryID else { return }
    recoveryStore.associate(id: currentRecoveryID, noteID: noteID)
    checkpointRecovery()
  }

  /// Remove preserved audio only after the result has landed somewhere
  /// durable (a note or a successfully parsed action).
  func completeCurrentRecovery() {
    guard let currentRecoveryID else { return }
    recoveryStore.complete(id: currentRecoveryID, deleteAudio: true)
    clearCurrentRecovery()
  }

  func checkpointCurrentRecovery() {
    checkpointRecovery()
  }

  /// Re-run local transcription against audio retained after an interruption.
  /// This intentionally accepts partial output: recovery should salvage as much
  /// as possible, not reject a file for ending early a second time.
  func recoverRecording(
    _ recording: RecoveryRecording,
    model: String,
    voiceCommandsEnabled: Bool
  ) async throws -> String {
    let audioURL = recording.audioURL(in: recoveryStore.directory)
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      let live = recording.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !live.isEmpty else {
        throw NSError(domain: "QuillRecovery", code: 1, userInfo: [
          NSLocalizedDescriptionKey: "The audio file is missing and there is no live transcript to keep."
        ])
      }
      return live
    }

    if whisperKit == nil || whisperKit?.modelFolder?.lastPathComponent != model {
      whisperKit = try await WhisperKit(WhisperKitConfig(model: model, download: true))
    }
    let duration = recorder.recordedDuration(at: audioURL) ?? recording.capturedDuration
    let options: DecodingOptions? = IOSLongRecordingPolicy.transcriptionStrategy(for: duration) == .voiceActivityChunks
      ? DecodingOptions(concurrentWorkerCount: 1, chunkingStrategy: .vad)
      : nil
    let results = try await whisperKit!.transcribe(audioPath: audioURL.path, decodeOptions: options)
    let cleaned = WhisperOutputCleaner.clean(results.map(\.text).joined(separator: " "))
    let recovered = voiceCommandsEnabled ? VoiceCommandSubstituter.substitute(in: cleaned) : cleaned
    guard !recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      let live = recording.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !live.isEmpty else {
        throw NSError(domain: "QuillRecovery", code: 2, userInfo: [
          NSLocalizedDescriptionKey: "No speech could be recovered from this recording."
        ])
      }
      return live
    }
    return recovered
  }

  private func checkpointRecovery() {
    guard let currentRecoveryID else { return }
    let captured = currentRecordingURL.flatMap { recorder.recordedDuration(at: $0) } ?? elapsedSeconds
    recoveryStore.checkpoint(
      id: currentRecoveryID,
      expectedDuration: activeRecordingDuration(),
      capturedDuration: captured,
      liveTranscript: livePartial
    )
  }

  private func markCurrentRecoveryNeedsAttention(reason: String) {
    guard let currentRecoveryID else { return }
    recoveryStore.markNeedsRecovery(id: currentRecoveryID, reason: reason)
  }

  private func clearCurrentRecovery() {
    currentRecoveryID = nil
    currentRecordingURL = nil
  }

  /// Opens the re-route window on a capture that just landed in a note.
  func armNoteReroute(_ offer: NoteRerouteOffer) {
    noteRerouteOffer = offer
    noteRerouteExpiry?.cancel()
    noteRerouteExpiry = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(noteRerouteWindowSeconds))
      guard !Task.isCancelled else { return }
      self?.noteRerouteOffer = nil
    }
  }

  func clearNoteReroute() {
    noteRerouteExpiry?.cancel()
    noteRerouteExpiry = nil
    noteRerouteOffer = nil
  }

  /// Typed command entry point — same agent pipeline as voice (routines,
  /// memory, MCP, confirmation sheet), just skipping the recorder +
  /// Whisper. For meetings, trains, and anywhere talking is awkward.
  func runTypedAction(
    _ text: String,
    provider: AIProvider,
    pinned: [QuillActDestination] = []
  ) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    actTargeting.pinned = pinned
    switch phase {
    case .idle, .done, .error:
      break
    default:
      return  // recording/transcribing in flight — don't fight it
    }
    isActionRecording = true
    wasAutoRouted = false
    matchedRoutine = nil
    routineDraft = nil
    parsedMultiIntents = nil
    recordingSessionID = UUID()
    rawTranscript = trimmed
    await routeActionTranscript(trimmed, provider: provider, sessionID: recordingSessionID)
  }

  /// Re-runs an already-transcribed capture through the agent — the
  /// re-route path, when Auto left a command sitting in a note.
  ///
  /// No recorder and no Whisper: the transcript is the one we already have,
  /// which is the whole point (the user shouldn't have to say it twice).
  /// `wasAutoRouted` is left as the caller set it so the confirmation sheet
  /// still offers "Save to note instead" — the way back.
  func rerunAsAction(_ transcript: String, provider: AIProvider) async {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    matchedRoutine = nil
    routineDraft = nil
    parsedMultiIntents = nil
    recordingSessionID = UUID()
    rawTranscript = trimmed
    await routeActionTranscript(trimmed, provider: provider, sessionID: recordingSessionID)
  }

  /// Shared Action-mode continuation: routine authoring → saved-routine
  /// trigger → LLM parse. Called by the Action FAB path, by Auto
  /// routing when a dictation sounds like a command, and by typed
  /// commands.
  private func routeActionTranscript(
    _ cleaned: String,
    provider: AIProvider,
    sessionID: UUID
  ) async {
        // Routine authoring — "new routine: when I say ship it, …" goes to
        // the routine parser, not the action parser (mirrors macOS Branch 3).
        let agentName = UserDefaults.standard.string(forKey: QuillIOSSettingsKey.agentName)
          ?? QuillIOSSettingsKey.defaultAgentName
        if let description = RoutineMatcher.authoringRequest(transcript: cleaned, agentName: agentName) {
          phase = .actionParsing
          do {
            let draft = try await IOSActionParsingClient.parseRoutine(
              description: description, provider: provider
            )
            guard sessionID == recordingSessionID else { return }
            routineDraft = draft
            phase = .done
            UINotificationFeedbackGenerator().notificationOccurred(.success)
          } catch {
            guard sessionID == recordingSessionID else { return }
            phase = .error("Couldn't understand that routine: \(error.localizedDescription)")
          }
          return
        }

        // Saved-routine trigger — exact phrase match posts the stored steps
        // straight to the multi sheet: instant, free, works offline.
        let routines = await RoutineStore.shared.loadAll()
        if let routine = RoutineMatcher.match(transcript: cleaned, routines: routines) {
          guard sessionID == recordingSessionID else { return }
          await RoutineStore.shared.recordRun(id: routine.id)
          matchedRoutine = routine
          parsedMultiIntents = routine.steps
          phase = .done
          UINotificationFeedbackGenerator().notificationOccurred(.success)
          return
        }

        phase = .actionParsing
        do {
          // MCP: list connected servers' tools so the LLM can emit
          // mcpCall actions (no-op when no server has a cached catalog).
          // Servers outside the targeting focus are withheld entirely —
          // a tool the model never saw is one it can't call.
          let targeting = actTargeting
          let mcpContext = await MCPToolCatalog.shared.promptContext(
            servers: targeting.allowedServers(from: MCPServersStorage.load())
          )
          // Agent memory: known people/projects/preferences so "email Mike"
          // resolves without clarifying questions.
          let memoryEnabled = UserDefaults.standard.object(forKey: QuillIOSSettingsKey.agentMemoryEnabled) as? Bool
            ?? QuillIOSSettingsKey.defaultAgentMemoryEnabled
          var memoryContext: String?
          if memoryEnabled {
            memoryContext = MemoryContextBuilder.context(from: await MemoryStore.shared.loadAll())
          }
          let response = try await IOSActionParsingClient.parseMulti(
            transcript: cleaned,
            provider: provider,
            memoryContext: memoryContext,
            mcpContext: mcpContext,
            targeting: targeting
          )
          // Fire-and-forget memory pass: distill durable entities from the
          // transcript so the agent gets smarter with every action.
          if memoryEnabled {
            Task {
              if let candidates = try? await IOSActionParsingClient.extractMemory(
                transcript: cleaned, provider: provider
              ), !candidates.isEmpty {
                await MemoryStore.shared.upsert(candidates)
              }
            }
          }
          guard sessionID == recordingSessionID else { return }
          // Every parse — single or multi — flows through the one
          // confirmation sheet (a single action is a one-item list).
          //
          // An unambiguous pin (exactly one native destination) hard-wins
          // over whatever the model chose; two or more stay advisory since
          // "@Gmail draft it and log it in @Dex" is a real two-step command.
          if let forced = targeting.forcedIntegration {
            parsedMultiIntents = response.actions.map { intent in
              guard intent.actionType != .mcpCall, intent.actionType != .open,
                    intent.actionType != .composeReply else { return intent }
              var resolved = intent
              resolved.targetIntegration = forced
              return resolved
            }
          } else {
            parsedMultiIntents = response.actions
          }
          actTargeting.pinned = []
          phase = .done
          UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
          guard sessionID == recordingSessionID else { return }
          if QueueableErrorClassifier.isQueueable(error) {
            await ActionQueueManager.shared.enqueueTranscript(
              cleaned,
              provider: provider,
              lastError: error.localizedDescription
            )
            phase = .done
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            NotificationCenter.default.post(name: .quillActionQueuedOffline, object: nil)
          } else {
            phase = .error("Action parsing failed: \(error.localizedDescription)")
          }
        }
  }
}

/// What the home NavigationStack can push: a note's detail, or the
/// dedicated Suggestions page.
enum QuillRoute: Hashable {
  case note(UUID)
  case suggestions
}

struct ContentView: View {
  @AppStorage(QuillIOSSettingsKey.selectedModel) private var selectedModel: String = QuillIOSSettingsKey.defaultModel
  @AppStorage(QuillIOSSettingsKey.aiProcessingMode) private var aiModeRaw: String = QuillIOSSettingsKey.defaultMode
  @AppStorage(QuillIOSSettingsKey.aiProvider) private var aiProviderRaw: String = QuillIOSSettingsKey.defaultProvider
  @AppStorage(QuillIOSSettingsKey.voiceCommandsEnabled) private var voiceCommandsEnabled: Bool = QuillIOSSettingsKey.defaultVoiceCommandsEnabled
  @AppStorage(CustomAIModesStorage.userDefaultsKey) private var customModesData: Data = Data()
  @AppStorage(QuillIOSSettingsKey.disabledBuiltInModes) private var disabledBuiltInModesData: Data = Data()
  @AppStorage(QuillIOSSettingsKey.defaultCaptureMode) private var defaultCaptureModeRaw: String = QuillIOSSettingsKey.defaultCaptureModeValue
  @AppStorage(IntegrationConnectionStore.userDefaultsKey) private var connectedIntegrationsData: Data = Data()
  @AppStorage(MCPServersStorage.userDefaultsKey) private var mcpServersData: Data = Data()
  @AppStorage(QuillIOSSettingsKey.suggestionsEnabled) private var suggestionsEnabled: Bool = true
  @AppStorage(QuillIOSSettingsKey.selectedPlan) private var selectedPlanRaw: String = ""

  @StateObject private var vm = RecordingViewModel()
  @StateObject private var notes = NotesStore.shared
  @StateObject private var suggestions = SuggestionsController.shared
  @StateObject private var recovery = RecordingRecoveryStore.shared
  /// View-model for the action confirmation sheet. Owned by ContentView
  /// (rather than the sheet itself via @StateObject) so the sheet can
  /// open *before* the LLM parse completes — we populate the
  /// transcript here, present the sheet, and then call
  /// `applyParsedIntent` once the parse returns. Using a single
  /// long-lived instance also avoids the brief flicker that comes
  /// from rebuilding the VM on every presentation.
  @EnvironmentObject private var deepLinks: QuillDeepLinkRouter
  @State private var showingSettings = false
  @State private var showingNotesList = false
  @State private var showingRecoveryCenter = false
  @State private var showingAskQuill = false
  @State private var askFocusedNoteID: UUID?
  @State private var lastAppendedTranscript: String = ""
  @State private var showCopied = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var showingPhotoSourceDialog = false
  @State private var showingCamera = false
  @State private var showingLibrary = false
  @State private var showingRenameAlert = false
  @State private var renameDraft: String = ""
  @State private var shareRequest: ShareRequest?
  @State private var isBuildingPDF = false
  @State private var pendingDeleteNoteID: UUID?
  @State private var editingNoteID: UUID?
  @State private var showingMultiActionConfirmation = false
  @State private var showingRoutineSave = false
  @State private var showingTypedAction = false
  @State private var showingConnections = false
  @State private var showingCustomModes = false
  @State private var activeNoteCapture: ActiveNoteCapture?
  @State private var activeCaptureMode: QuillMode?
  @State private var showingDiscardRecordingConfirmation = false
  @AppStorage(QuillIOSSettingsKey.editCommandUsage) private var editCommandUsageData: Data = Data()
  @StateObject private var multiActionVM = MultiActionConfirmationViewModel()
  /// Transient banner state — set true when an action mode item is queued
  /// because we're offline. Auto-clears after a few seconds via the task
  /// kicked off in `.onReceive`.
  @State private var showOfflineQueuedBanner = false

  /// The mode this capture runs in. Seeded from — and written back to —
  /// `defaultCaptureMode`, so picking Act on the rail is still Act the
  /// next time the app opens.
  @State private var captureMode: QuillMode = .auto
  /// Act destinations the user has switched off for this capture.
  @State private var mutedDestinations: Set<String> = []
  /// Set when the user corrects the routing preview, which stops the live
  /// keyword intuition for the rest of the utterance.
  @State private var lockedDestinationID: String?
  /// The note composer's mode. Separate from `captureMode` because the
  /// note rail offers Edit where home offers Auto — sharing one value
  /// would strand the rail on a mode its own rail can't show.
  @State private var noteMode: QuillMode = .dictate
  /// Navigation. Home is the root; a note or the Suggestions page pushes.
  @State private var path: [QuillRoute] = []
  @State private var offlineBannerDismissTask: Task<Void, Never>?

  /// The currently-selected mode, which may be either a built-in
  /// `AIProcessingMode` or a user-created custom mode. Stored as
  /// string in `aiModeRaw` using `AIModeSelection.rawValue`
  /// (e.g. `"clean"`, `"notes"`, or `"custom:<uuid>"`).
  private var currentSelection: AIModeSelection {
    AIModeSelection(rawValue: aiModeRaw) ?? .builtIn(.off)
  }

  /// Back-compat helper — treated as `.off` whenever the current
  /// selection is a custom mode. Code paths that need to know
  /// "is AI processing on at all" should use
  /// `currentSelection.resolveSystemPrompt(...) != nil` instead.
  private var aiMode: AIProcessingMode {
    if case .builtIn(let mode) = currentSelection { return mode }
    // Custom mode selected — behaves like a non-off mode for UI
    // colouring. `.clean` is a reasonable placeholder because it's
    // purple-tinted and indicates "AI is on".
    return .clean
  }

  private var aiProvider: AIProvider {
    AIProvider(rawValue: aiProviderRaw) ?? .anthropic
  }

  private var customModes: [CustomAIMode] {
    CustomAIModesStorage.decode(customModesData)
  }

  var body: some View {
    NavigationStack(path: $path) {
      ZStack(alignment: .bottom) {
        backgroundGradient
          .ignoresSafeArea()

        VStack(spacing: 0) {
          headerBar
          home
        }

        statusCard
          .padding(.bottom, 12)
      }
      .navigationDestination(for: QuillRoute.self) { route in
        switch route {
        case .note(let id):
          noteDetail(for: id)
        case .suggestions:
          QuillSuggestionsPage(
            suggestions: suggestions.current,
            isPro: selectedPlanRaw == "pro",
            noReadableSources: suggestions.hadNoReadableSources,
            isGenerating: suggestions.isGenerating,
            onReview: { reviewSuggestion($0) },
            onDismiss: { suggestions.dismiss($0) },
            onUnlock: { showingSettings = true },
            onRefresh: { Task { await suggestions.regenerateNow() } }
          )
        }
      }
      .toolbar(.hidden, for: .navigationBar)
      .onAppear {
        // Pre-warm the Whisper model immediately on first appear so
        // the initial transcription doesn't block on a long
        // download + load. Happens in the background — user can
        // still interact with everything else.
        Task { await vm.prewarmModel(selectedModel) }
      }
      .onChange(of: selectedModel) { _, newModel in
        Task { await vm.prewarmModel(newModel) }
      }
      .onChange(of: deepLinks.pendingLink) { _, link in
        guard let link else { return }
        switch link.link {
        case .record:
          // Widget tap: always start a FRESH note, then begin
          // recording. Appending to an existing active note would
          // feel surprising to a user who just tapped a home-screen
          // widget — they expect a dedicated new capture.
          Task {
            notes.setActiveNote(id: nil)
            activeCaptureMode = .auto
            // Delay briefly to let the app finish becoming active so
            // the mic permission prompt (if any) and recording
            // startup don't race UIKit window transitions.
            try? await Task.sleep(for: .milliseconds(300))
            await vm.toggleRecording(
              model: selectedModel,
              mode: aiMode,
              provider: aiProvider,
              voiceCommandsEnabled: voiceCommandsEnabled
            )
            if vm.phase == .recording {
              beginActiveNoteCapture(noteID: nil, navigate: true)
            } else {
              activeCaptureMode = nil
            }
            deepLinks.consume()
          }
        case .notes:
          showingNotesList = true
          deepLinks.consume()
        }
      }
      .onChange(of: vm.phase) { _, newPhase in
        if case .done = newPhase, !vm.isActionRecording {
          // Finishing a capture from home opens the note it just made.
          appendTranscriptToActiveNote(navigate: path.isEmpty)
        }
        if case .error = newPhase {
          preserveDraftAfterTranscriptionFailure()
        }
        // Open the confirmation sheet the moment we start parsing —
        // the user sees their captured transcript in HEARD with a
        // skeleton card where WILL DO will land. `applyParsedIntents`
        // fills it in place when the parse returns.
        if case .actionParsing = newPhase, !showingMultiActionConfirmation {
          multiActionVM.onSaveToNote = { appendTranscriptToActiveNote() }
          multiActionVM.startParsing(
            transcript: vm.rawTranscript,
            wasAutoRouted: vm.wasAutoRouted
          )
          showingMultiActionConfirmation = true
        }
        // Parse failed (queue path or hard error) without intents ever
        // landing → close the parsing sheet so the offline banner /
        // error pill in the main UI can take over.
        if case .done = newPhase,
           vm.isActionRecording,
           vm.parsedMultiIntents == nil,
           showingMultiActionConfirmation,
           multiActionVM.isParsing {
          showingMultiActionConfirmation = false
        }
        if case .error = newPhase,
           showingMultiActionConfirmation,
           multiActionVM.isParsing {
          showingMultiActionConfirmation = false
        }
      }
      .onChange(of: vm.livePartial) { _, text in
        guard vm.phase == .recording, let capture = activeNoteCapture else { return }
        notes.updateTranscriptionDraft(
          noteID: capture.noteID,
          sessionID: capture.sessionID,
          text: text
        )
      }
      .onChange(of: vm.parsedMultiIntents) { _, intents in
        guard let intents, !intents.isEmpty else { return }
        // Routine trust ladder: an auto-run routine skips the confirmation —
        // the sheet opens straight into execution progress.
        let autoRun = vm.matchedRoutine?.autoRun ?? false
        multiActionVM.onSaveToNote = { appendTranscriptToActiveNote() }
        multiActionVM.applyParsedIntents(
          intents,
          rawTranscript: vm.rawTranscript,
          autoExecute: autoRun
        )
        showingMultiActionConfirmation = true
      }
      .onChange(of: vm.routineDraft) { _, draft in
        guard draft != nil else { return }
        showingRoutineSave = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .quillActionQueuedOffline)) { _ in
        // Show a transient pill above the FAB cluster acknowledging the
        // queue. Auto-dismiss after 3s — long enough to read, short
        // enough not to nag.
        offlineBannerDismissTask?.cancel()
        QuillMotion.run(.spring(duration: 0.3, bounce: 0.2)) {
          showOfflineQueuedBanner = true
        }
        offlineBannerDismissTask = Task { @MainActor in
          try? await Task.sleep(for: .seconds(3))
          guard !Task.isCancelled else { return }
          QuillMotion.run(.easeOut(duration: 0.3)) {
            showOfflineQueuedBanner = false
          }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .quillToggleRecordingPauseRequested)) { _ in
        vm.togglePause()
      }
      .onReceive(NotificationCenter.default.publisher(for: .quillStopRecordingRequested)) { _ in
        Task { await endCapture() }
      }
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
        vm.checkpointCurrentRecovery()
      }
    }
      // Presentations attach to the STACK, not to the root screen —
      // otherwise a pushed note covers them: the capture sheet is a ZStack
      // overlay so it drew *under* the detail view, and the .sheets fired
      // against a screen that was no longer visible.
      .quillCaptureSheet(
        isPresented: isCapturing,
        reduceMotion: reduceMotion
      ) {
        captureSheet
      }
      .confirmationDialog(
        "Discard this recording?",
        isPresented: $showingDiscardRecordingConfirmation,
        titleVisibility: .visible
      ) {
        if activeNoteCapture != nil, hasRecoverablePartial {
          Button("Keep Partial Transcription") { keepPartialAndStop() }
        }
        Button("Discard Recording", role: .destructive) { cancelCapture() }
        Button("Continue Recording", role: .cancel) {}
      } message: {
        Text(
          hasRecoverablePartial
            ? "The words recognized so far can be kept in the note, or the recording can be discarded."
            : "The recording has not produced a recoverable transcript yet."
        )
      }
      .sheet(isPresented: $showingSettings) {
        SettingsView()
      }
      .sheet(isPresented: $showingNotesList) {
        NotesListView(store: notes, onOpenNote: { id in
          // The sheet dismisses itself; push the detail so the picked
          // note actually opens (home is just a launcher).
          path = [.note(id)]
        }, onAsk: {
          askFocusedNoteID = nil
          showingAskQuill = true
        })
      }
      .sheet(isPresented: $showingRecoveryCenter) {
        RecordingRecoveryView(
          store: recovery,
          onRecover: recoverRecording,
          onKeepDraft: keepRecoveredPartial
        )
      }
      .sheet(isPresented: $showingAskQuill) {
        AskQuillView(
          notes: notes.notes,
          focusedNoteID: askFocusedNoteID,
          provider: aiProvider,
          onOpenCitation: { id in
            showingNotesList = false
            notes.setActiveNote(id: id)
            path = [.note(id)]
          }
        )
      }
      // "+ Connect an app" / "+ Add" on the mode sub-rows go straight to
      // the screen that does the thing, rather than dropping the user at
      // the top of Settings to find it.
      .sheet(isPresented: $showingConnections) {
        NavigationStack {
          ConnectionsView()
            .toolbar {
              ToolbarItem(placement: .topBarLeading) {
                Button("Done") { showingConnections = false }
              }
            }
        }
      }
      .sheet(isPresented: $showingCustomModes) {
        NavigationStack {
          CustomModesView()
            .toolbar {
              ToolbarItem(placement: .topBarLeading) {
                Button("Done") { showingCustomModes = false }
              }
            }
        }
      }
      .sheet(isPresented: $showingCamera) {
        CameraPicker { image in
          showingCamera = false
          if let image { handlePickedPhoto(image) }
        }
        .ignoresSafeArea()
      }
      .sheet(isPresented: $showingLibrary) {
        PhotoLibraryPicker { image in
          showingLibrary = false
          if let image { handlePickedPhoto(image) }
        }
      }
      .confirmationDialog("Add Photo", isPresented: $showingPhotoSourceDialog, titleVisibility: .visible) {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button("Take Photo") { showingCamera = true }
        }
        Button("Choose from Library") { showingLibrary = true }
        Button("Cancel", role: .cancel) {}
      }
      .alert("Rename Note", isPresented: $showingRenameAlert) {
        TextField("Title", text: $renameDraft)
        Button("Save") { commitRename() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Leave blank to auto-derive from the first line of the note.")
      }
      .alert("Delete Note?", isPresented: Binding(
        get: { pendingDeleteNoteID != nil },
        set: { if !$0 { pendingDeleteNoteID = nil } }
      )) {
        Button("Delete", role: .destructive) {
          if let id = pendingDeleteNoteID {
            notes.deleteNote(id: id)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
          }
          pendingDeleteNoteID = nil
        }
        Button("Cancel", role: .cancel) { pendingDeleteNoteID = nil }
      } message: {
        Text("This removes the note and all attached photos. This can't be undone.")
      }
      .sheet(item: $shareRequest) { req in
        ShareSheet(items: req.items)
      }
      .sheet(isPresented: $showingMultiActionConfirmation, onDismiss: {
        // If Auto routed this capture to an action and the user ran or
        // dismissed it, its provisional note paragraph no longer belongs in
        // the note. "Save to note instead" finalizes it before dismissal.
        if vm.isActionRecording { discardActiveNoteCapture() }
        activeCaptureMode = nil
      }) {
        MultiActionConfirmationSheet(vm: multiActionVM)
      }
      .sheet(isPresented: $showingRoutineSave) {
        if let draft = vm.routineDraft {
          RoutineSaveSheet(draft: draft) {
            vm.routineDraft = nil
          }
        }
      }
      .sheet(isPresented: $showingTypedAction) {
        TypedActionSheet(destinations: routableDestinations) { text, pinned in
          Task { await vm.runTypedAction(text, provider: aiProvider, pinned: pinned) }
        }
      }
      .sheet(isPresented: Binding(
        get: { editingNoteID != nil },
        set: { if !$0 { editingNoteID = nil } }
      )) {
        if let id = editingNoteID, let note = notes.notes.first(where: { $0.id == id }) {
          NoteEditSheet(note: note)
        }
      }
  }

  // MARK: - Photo flow

  /// Tapped from the active-note strip. If a recording is in flight, stop
  /// it first (so the dictated text is committed to the note before the
  /// photo lands), then present the source chooser.
  private func tapAddPhoto() {
    UISelectionFeedbackGenerator().selectionChanged()
    if vm.phase == .recording {
      Task {
        await vm.toggleRecording(
          model: selectedModel,
          mode: aiMode,
          provider: aiProvider,
          voiceCommandsEnabled: voiceCommandsEnabled,
          customSystemPrompt: currentSelection.resolveSystemPrompt(customModes: customModes).flatMap { _ in
            // Only pass a custom prompt when the selection IS a custom mode;
            // built-in selections use their own `mode.systemPrompt` via `aiMode`.
            if case .custom = currentSelection {
              return currentSelection.resolveSystemPrompt(customModes: customModes)
            }
            return nil
          }
        )
        showingPhotoSourceDialog = true
      }
    } else {
      showingPhotoSourceDialog = true
    }
  }

  private func handlePickedPhoto(_ image: UIImage) {
    Task {
      let loc = notes.activeNote == nil
        ? await LocationClient.shared.currentPlace()
        : nil
      if let ids = notes.insertPhotoIntoActiveNote(image, locationIfCreating: loc) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // Fire-and-forget: the store flips `analyzingPhotoIDs` and
        // publishes the result so the view refreshes automatically.
        notes.analyzePhoto(noteID: ids.noteID, photoID: ids.photoID, provider: aiProvider)
      }
    }
  }

  // MARK: - Rename flow

  /// Pre-fill the rename draft with the user's stored title (not the
  /// derived one) so saving an empty string falls back to derivation.
  private func tapRenameTitle() {
    guard let note = notes.activeNote else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    renameDraft = note.title
    showingRenameAlert = true
  }

  private func commitRename() {
    guard let id = notes.activeNoteID else { return }
    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    notes.renameNote(id: id, to: trimmed)
  }

  // MARK: - Share flow

  private func shareNoteText(_ note: Note) {
    let text = NoteContent.stripPhotos(from: note.body)
    guard !text.isEmpty else { return }
    shareRequest = ShareRequest(items: [text])
  }

  private func sharePDF(_ note: Note) {
    isBuildingPDF = true
    let snapshot = notes.photoAnalyses
    Task { @MainActor in
      defer { isBuildingPDF = false }
      if let url = NotePDFExporter.export(note, analyses: snapshot) {
        shareRequest = ShareRequest(items: [url])
      }
    }
  }

  // MARK: - Home

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var home: some View {
    QuillHome(
      mode: $captureMode,
      format: Binding(
        get: { aiMode },
        set: { aiModeRaw = AIModeSelection.builtIn($0).rawValue }
      ),
      mutedDestinations: $mutedDestinations,
      notes: notes.sortedNotes,
      destinations: actDestinations,
      hiddenFormats: disabledBuiltInModes,
      suggestions: suggestions.current,
      suggestionsEnabled: suggestionsEnabled,
      isPro: selectedPlanRaw == "pro",
      meetings: suggestions.meetings,
      onTapTrigger: { Task { await beginCapture() } },
      onHoldTrigger: { Task { await beginCapture() } },
      onReleaseTrigger: { Task { await endCapture() } },
      onTapKeyboard: { showingTypedAction = true },
      onOpenNote: { note in
        notes.setActiveNote(id: note.id)
        path = [.note(note.id)]
      },
      onAddFormat: { showingCustomModes = true },
      onAddDestination: { showingConnections = true },
      onOpenSuggestions: { path.append(.suggestions) },
      onDictateMeeting: { dictateIntoMeeting($0) }
    )
    .onAppear {
      captureMode = QuillMode(rawValue: defaultCaptureModeRaw) ?? .auto
    }
    // The rail is the primary way the mode gets set, so it's also what
    // decides the stored default — otherwise the choice evaporated on
    // relaunch. Settings edits flow the other way via the second handler.
    .onChange(of: captureMode) { _, newMode in
      defaultCaptureModeRaw = newMode.rawValue
    }
    .onChange(of: defaultCaptureModeRaw) { _, newRaw in
      captureMode = QuillMode(rawValue: newRaw) ?? .auto
    }
    // Keep the agent's routing set in step with the chip row. Muting an app
    // now narrows what the planner is shown, rather than only dimming a chip.
    .onAppear { syncActTargeting() }
    .onChange(of: mutedDestinations) { _, _ in syncActTargeting() }
    .onChange(of: connectedIntegrationsData) { _, _ in syncActTargeting() }
    .onChange(of: mcpServersData) { _, _ in syncActTargeting() }
  }

  private func syncActTargeting() {
    vm.actTargeting.routable = ActTargeting(
      all: actDestinations, muted: mutedDestinations
    ).routable
  }

  // MARK: - Suggestions

  /// Accept path: opens the existing confirmation sheet pre-filled with the
  /// suggestion's already-built intents — no parse, straight to review.
  private func reviewSuggestion(_ suggestion: Suggestion) {
    // Don't clobber an in-flight voice capture or an already-open sheet:
    // the sheet VM is shared with the voice path.
    guard !showingMultiActionConfirmation, !vm.isActionRecording, !isCapturing else { return }
    multiActionVM.presentPrebuilt(
      intents: suggestion.intents,
      headline: suggestion.headline,
      source: suggestion.source,
      onRan: { suggestions.consume(suggestion) }
    )
    showingMultiActionConfirmation = true
  }

  /// Dictate × Calendar: start a dictation whose note is titled for the
  /// meeting, so the capture lands as that meeting's notes.
  private func dictateIntoMeeting(_ meeting: IOSSuggestionSources.UpcomingMeeting) {
    guard !isCapturing else { return }
    Task {
      let loc = await LocationClient.shared.currentPlace()
      let note = notes.startNewNote(location: loc)
      notes.renameNote(id: note.id, to: meeting.title)
      path = [.note(note.id)]
      await beginNoteCapture(noteID: note.id)
    }
  }

  /// Everything currently connected, minus anything muted for this capture.
  private var actDestinations: [QuillActDestination] {
    QuillActDestination.connected(
      integrationData: connectedIntegrationsData,
      mcpData: mcpServersData
    )
  }

  private var routableDestinations: [QuillActDestination] {
    actDestinations.filter { !mutedDestinations.contains($0.id) }
  }

  // MARK: - Capture

  private var isCapturing: Bool {
    switch vm.phase {
    case .recording, .transcribing, .aiProcessing, .actionParsing: true
    case .done: vm.noteTargetBanner != nil
    case .idle, .requestingPermission, .error: false
    }
  }

  private var capturePhase: QuillOrb.Phase {
    switch vm.phase {
    case .recording: .listening
    case .transcribing, .aiProcessing, .actionParsing: .transcribing
    case .done: .result
    default: .idle
    }
  }

  private var captureSheet: QuillCaptureSheet {
    let mode = activeCaptureMode ?? captureMode
    return QuillCaptureSheet(
      mode: mode,
      format: aiMode,
      phase: capturePhase,
      transcript: vm.livePartial,
      level: Double(vm.meterLevel),
      statusText: captureStatusText,
      resultText: vm.noteTargetBanner,
      routing: mode == .act ? routingPreview : nil,
      isRecording: vm.phase == .recording,
      isPaused: vm.isPaused,
      onStop: { Task { await endCapture() } },
      onTogglePause: { vm.togglePause() },
      onCancel: requestCancelCapture,
      onPickDestination: { d in
        lockedDestinationID = d.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
      }
    )
  }

  private var captureStatusText: String {
    switch vm.phase {
    case .recording:
      if vm.isPaused { return "paused" }
      if (activeCaptureMode ?? captureMode) == .act, let target = intuitedDestination {
        return "routing → \(target.name)"
      }
      return "listening…"
    case .transcribing: return "transcribing…"
    case .aiProcessing: return "enhancing…"
    case .actionParsing: return "parsing…"
    case .done: return "done"
    default: return ""
    }
  }

  /// The destination the live transcript points at — the user's pick wins,
  /// otherwise keyword intuition, re-run as words arrive.
  private var intuitedDestination: QuillActDestination? {
    if let lockedDestinationID {
      return routableDestinations.first { $0.id == lockedDestinationID }
    }
    return QuillActDestination.intuit(from: vm.livePartial, among: routableDestinations)
  }

  private var routingPreview: QuillCaptureSheet.RoutingPreview {
    QuillCaptureSheet.RoutingPreview(
      target: intuitedDestination,
      options: routableDestinations,
      isLocked: lockedDestinationID != nil
    )
  }

  /// Home always starts a fresh note: clearing the active note means the
  /// append-on-done creates one rather than extending whatever was last
  /// open. Appending to an existing note happens from its own composer.
  private func beginCapture() async {
    guard vm.phase != .recording else { return }
    lockedDestinationID = nil
    if path.isEmpty { notes.setActiveNote(id: nil) }
    activeCaptureMode = captureMode

    switch captureMode {
    case .act:
      await vm.toggleActionRecording(model: selectedModel, provider: aiProvider)
    case .auto, .dictate, .edit:
      await vm.toggleRecording(
        model: selectedModel,
        mode: aiMode,
        provider: aiProvider,
        voiceCommandsEnabled: voiceCommandsEnabled,
        customSystemPrompt: micCustomSystemPrompt,
        captureMode: captureMode
      )
      if vm.phase == .recording, captureMode == .auto || captureMode == .dictate {
        beginActiveNoteCapture(noteID: nil, navigate: true)
      }
    }
    if vm.phase != .recording { activeCaptureMode = nil }
  }

  private func endCapture() async {
    guard vm.phase == .recording else { return }
    let mode = activeCaptureMode ?? captureMode
    switch mode {
    case .act:
      await vm.toggleActionRecording(model: selectedModel, provider: aiProvider)
    case .auto, .dictate, .edit:
      await vm.toggleRecording(
        model: selectedModel,
        mode: aiMode,
        provider: aiProvider,
        voiceCommandsEnabled: voiceCommandsEnabled,
        customSystemPrompt: micCustomSystemPrompt,
        captureMode: mode
      )
    }
  }

  private func cancelCapture() {
    vm.discardRecording()
    discardActiveNoteCapture()
    activeCaptureMode = nil
    lockedDestinationID = nil
  }

  /// Creates the provisional paragraph only after the recorder has actually
  /// started, avoiding empty notes when microphone permission is denied.
  private func beginActiveNoteCapture(noteID: UUID?, navigate: Bool) {
    guard activeNoteCapture == nil else { return }
    let sessionID = UUID()
    let result = notes.beginTranscriptionDraft(
      noteID: noteID,
      sessionID: sessionID
    )
    activeNoteCapture = ActiveNoteCapture(
      sessionID: sessionID,
      noteID: result.note.id,
      createdNote: result.created,
      navigateOnFinalize: navigate
    )
    vm.associateCurrentRecovery(with: result.note.id)

    // Recognition may produce its first hypothesis in the short interval
    // between the recorder starting and the note draft being established.
    notes.updateTranscriptionDraft(
      noteID: result.note.id,
      sessionID: sessionID,
      text: vm.livePartial
    )
    if navigate { path = [.note(result.note.id)] }
  }

  private func requestCancelCapture() {
    guard vm.phase == .recording else { return }
    if vm.elapsedSeconds >= 0.5 || hasRecoverablePartial {
      showingDiscardRecordingConfirmation = true
    } else {
      cancelCapture()
    }
  }

  private var hasRecoverablePartial: Bool {
    guard let capture = activeNoteCapture else { return false }
    return !(notes.notes
      .first(where: { $0.id == capture.noteID })?
      .pendingTranscription?.text
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
  }

  /// Stops without waiting for Whisper and promotes the latest durable live
  /// hypothesis into the note. This is the non-destructive escape hatch in
  /// the explicit discard confirmation.
  private func keepPartialAndStop() {
    guard vm.phase == .recording else { return }
    _ = finalizeActiveNoteCapture(finalText: "", offerReroute: false)
    vm.discardRecording()
    lockedDestinationID = nil
  }

  /// A Whisper failure should not strand a draft in transient state. Keep the
  /// last live hypothesis when one exists; otherwise remove the empty shell.
  private func preserveDraftAfterTranscriptionFailure() {
    guard let capture = activeNoteCapture else { return }
    let livePartial = notes.notes
      .first(where: { $0.id == capture.noteID })?
      .pendingTranscription?.text
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let recovered = vm.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let bestAvailableText = recovered.isEmpty ? livePartial : recovered
    if bestAvailableText.isEmpty {
      discardActiveNoteCapture()
    } else {
      _ = finalizeActiveNoteCapture(
        finalText: bestAvailableText,
        offerReroute: false,
        completeRecovery: false
      )
    }
  }

  @discardableResult
  private func finalizeActiveNoteCapture(
    finalText: String,
    offerReroute shouldOfferReroute: Bool,
    completeRecovery: Bool = true
  ) -> Bool {
    guard let capture = activeNoteCapture,
          let result = notes.finalizeTranscriptionDraft(
            noteID: capture.noteID,
            sessionID: capture.sessionID,
            finalText: finalText
          )
    else { return false }

    activeNoteCapture = nil
    activeCaptureMode = nil
    if completeRecovery { vm.completeCurrentRecovery() }
    let appended = result.appendedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !appended.isEmpty else { return true }
    lastAppendedTranscript = appended
    notes.generateTitleIfNeeded(noteID: result.note.id, provider: aiProvider)
    if capture.navigateOnFinalize { path = [.note(result.note.id)] }
    if shouldOfferReroute {
      offerNoteReroute(
        noteID: result.note.id,
        appended: appended,
        createdNote: capture.createdNote
      )
    }
    if capture.createdNote {
      Task {
        notes.setLocation(
          id: result.note.id,
          location: await LocationClient.shared.currentPlace()
        )
      }
    }
    return true
  }

  private func discardActiveNoteCapture() {
    guard let capture = activeNoteCapture else { return }
    let removed = notes.discardTranscriptionDraft(
      noteID: capture.noteID,
      sessionID: capture.sessionID,
      deleteEmptyNote: capture.createdNote
    )
    activeNoteCapture = nil
    activeCaptureMode = nil
    if removed, path == [.note(capture.noteID)] { path = [] }
  }

  // MARK: - Note detail

  @ViewBuilder
  private func noteDetail(for id: UUID) -> some View {
    if let note = notes.notes.first(where: { $0.id == id }) {
      NoteDetailView(
        note: note,
        mode: $noteMode,
        format: Binding(
          get: { aiMode },
          set: { aiModeRaw = AIModeSelection.builtIn($0).rawValue }
        ),
        mutedDestinations: $mutedDestinations,
        destinations: actDestinations,
        hiddenFormats: disabledBuiltInModes,
        learnedEditCommands: EditCommandUsage.mostUsed(
          EditCommandUsage.decode(editCommandUsageData)
        ),
        onTapTrigger: { Task { await beginNoteCapture(noteID: id) } },
        onHoldTrigger: { Task { await beginNoteCapture(noteID: id) } },
        onReleaseTrigger: { Task { await endNoteCapture() } },
        onSendText: { text in
          notes.setActiveNote(id: id)
          if noteMode == .act {
            Task { await vm.runTypedAction(text, provider: aiProvider) }
          } else {
            notes.appendToNote(id: id, text: text)
          }
        },
        onEditCommand: { command in
          notes.setActiveNote(id: id)
          Task { await runNoteEdit(command, noteID: id) }
        },
        onAddPhoto: {
          notes.setActiveNote(id: id)
          tapAddPhoto()
        },
        onEditBody: { editingNoteID = id },
        onAsk: {
          askFocusedNoteID = id
          showingAskQuill = true
        },
        onRename: {
          notes.setActiveNote(id: id)
          tapRenameTitle()
        },
        onShareText: {
          if let note = notes.notes.first(where: { $0.id == id }) {
            shareNoteText(note)
          }
        },
        onSharePDF: {
          if let note = notes.notes.first(where: { $0.id == id }) {
            sharePDF(note)
          }
        },
        isBuildingPDF: isBuildingPDF,
        onAddDestination: { showingConnections = true },
        onAddFormat: { showingCustomModes = true },
        isEditing: vm.isEditingNote,
        editError: vm.noteEditError,
        onDismissEditError: { vm.noteEditError = nil },
        canRerouteToAction: vm.noteRerouteOffer?.noteID == note.id,
        onRerouteToAction: runNoteReroute,
        onDismissReroute: { vm.clearNoteReroute() }
      )
    }
  }

  /// Revise a note from a spoken/typed instruction. Replaces the demo
  /// transform engine in the design prototype with a real model call,
  /// keeping the diff + Undo affordance that makes edits feel safe.
  private func runNoteEdit(_ command: String, noteID: UUID) async {
    guard let note = notes.notes.first(where: { $0.id == noteID }) else { return }
    vm.noteEditError = nil
    let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
      vm.noteEditError = "Nothing to edit yet — add something to the note first."
      return
    }

    // Learn what the user actually reaches for so it floats to the front.
    var counts = EditCommandUsage.decode(editCommandUsageData)
    counts[command, default: 0] += 1
    editCommandUsageData = EditCommandUsage.encode(counts)

    vm.isEditingNote = true
    defer { vm.isEditingNote = false }

    do {
      let revised = try await TextAIClient.process(
        text: InlineEditPrompt.userMessage(instruction: command, selection: body),
        mode: .clean,
        provider: aiProvider,
        customSystemPrompt: InlineEditPrompt.systemPrompt
      )
      let cleaned = revised.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty, cleaned != body else {
        // The model handed back the note unchanged (or nothing at all).
        // Say so — silently returning here is indistinguishable from a
        // dead button.
        vm.noteEditError = "The model returned the note unchanged. Try rewording the command."
        return
      }

      notes.applyEdit(id: noteID, newBody: cleaned, label: editLabel(for: command))
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      vm.noteEditError = error.localizedDescription
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
  }

  /// A short past-tense label for the diff banner. Shared with macOS.
  private func editLabel(for command: String) -> String {
    NoteEditCommands.label(for: command)
  }

  /// A capture started from inside a note appends to THAT note rather than
  /// creating a new one.
  private func beginNoteCapture(noteID: UUID) async {
    guard vm.phase != .recording else { return }
    notes.setActiveNote(id: noteID)
    lockedDestinationID = nil
    activeCaptureMode = noteMode
    switch noteMode {
    case .act:
      await vm.toggleActionRecording(model: selectedModel, provider: aiProvider)
    case .auto, .dictate, .edit:
      await vm.toggleRecording(
        model: selectedModel,
        mode: aiMode,
        provider: aiProvider,
        voiceCommandsEnabled: voiceCommandsEnabled,
        customSystemPrompt: micCustomSystemPrompt,
        captureMode: noteMode
      )
      if vm.phase == .recording, noteMode == .auto || noteMode == .dictate {
        beginActiveNoteCapture(noteID: noteID, navigate: false)
      }
    }
    if vm.phase != .recording { activeCaptureMode = nil }
  }

  private func endNoteCapture() async {
    guard vm.phase == .recording else { return }
    let mode = activeCaptureMode ?? noteMode
    switch mode {
    case .act:
      await vm.toggleActionRecording(model: selectedModel, provider: aiProvider)
    case .auto, .dictate, .edit:
      await vm.toggleRecording(
        model: selectedModel,
        mode: aiMode,
        provider: aiProvider,
        voiceCommandsEnabled: voiceCommandsEnabled,
        customSystemPrompt: micCustomSystemPrompt,
        captureMode: mode
      )
    }
  }

  // MARK: - Custom header

  private var headerBar: some View {
    QuillTopBar(
      onTapList: { showingNotesList = true },
      onTapNewNote: {
        Task {
          let loc = await LocationClient.shared.currentPlace()
          let note = notes.startNewNote(location: loc)
          path = [.note(note.id)]
        }
      },
      onTapSettings: { showingSettings = true },
      recoveryCount: recovery.recordings.count,
      onTapRecovery: { showingRecoveryCenter = true },
      onTapSuggestions: (selectedPlanRaw == "pro" && suggestionsEnabled)
        ? { path.append(.suggestions) } : nil
    )
  }

  // MARK: - Recovery Center

  private func recoverRecording(_ recording: RecoveryRecording) async throws -> UUID? {
    let transcript = try await vm.recoverRecording(
      recording,
      model: selectedModel,
      voiceCommandsEnabled: voiceCommandsEnabled
    )
    guard let note = notes.applyRecoveredRecording(
      noteID: recording.noteID,
      liveTranscript: recording.liveTranscript,
      finalTranscript: transcript
    ) else { return nil }
    recovery.complete(id: recording.id, deleteAudio: true)
    notes.setActiveNote(id: note.id)
    notes.generateTitleIfNeeded(noteID: note.id, provider: aiProvider)
    path = [.note(note.id)]
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    return note.id
  }

  private func keepRecoveredPartial(_ recording: RecoveryRecording) -> UUID? {
    guard let note = notes.applyRecoveredRecording(
      noteID: recording.noteID,
      liveTranscript: recording.liveTranscript,
      finalTranscript: recording.liveTranscript
    ) else { return nil }
    recovery.complete(id: recording.id, deleteAudio: true)
    notes.setActiveNote(id: note.id)
    notes.generateTitleIfNeeded(noteID: note.id, provider: aiProvider)
    path = [.note(note.id)]
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    return note.id
  }

  // MARK: - Append-on-done

  /// Called whenever the recording VM transitions to .done. Appends the
  /// final transcript (AI-enhanced if a mode was selected, raw otherwise)
  /// to the active note, creating a new one with a location tag if none
  /// exists yet. Guards against double-append by tracking the last
  /// transcript we consumed.
  /// - Parameter navigate: open the note when the append lands. True for
  ///   captures started from home, which always produce a new note; false
  ///   when appending from a note's own composer (we're already there).
  private func appendTranscriptToActiveNote(navigate: Bool = false) {
    let text = vm.displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // Note-producing audio captures already have a provisional paragraph in
    // a specific note. Replace it in place instead of performing a second
    // generic append (which could duplicate text or target a different note).
    if activeNoteCapture != nil,
       finalizeActiveNoteCapture(finalText: text, offerReroute: true) {
      return
    }

    guard text != lastAppendedTranscript else { return }
    lastAppendedTranscript = text

    // The note is created and opened synchronously, always.
    //
    // This used to `await LocationClient.currentPlace()` first when there was
    // no active note — which meant the note didn't exist and the app didn't
    // navigate until a permission dialog (up to 10 s), a GPS fix, and a
    // network reverse-geocode had all resolved. The user finished speaking
    // and stared at a screen with no note on it, reasonably concluding it
    // had been lost. Location is decoration; it lands later via `setLocation`.
    let isNewNote = notes.activeNote == nil
    let note = notes.appendToActiveNote(text, locationIfCreating: nil)
    vm.completeCurrentRecovery()
    // Kick off AI title generation on the background. No-op if the note
    // already has a locked-in title (user-renamed or previously AI-titled)
    // — see `generateTitleIfNeeded`.
    notes.generateTitleIfNeeded(noteID: note.id, provider: aiProvider)
    if navigate { path = [.note(note.id)] }
    offerNoteReroute(noteID: note.id, appended: text, createdNote: isNewNote)

    if isNewNote {
      Task { notes.setLocation(id: note.id, location: await LocationClient.shared.currentPlace()) }
    }
  }

  /// Offers "run as action" on a capture that just became note text.
  ///
  /// Only in Auto: picking Dictate is the user saying "this is a note", and
  /// second-guessing that is noise. This is the mirror of the confirmation
  /// sheet's "Save to note instead" — together they make Auto's guess
  /// reversible in both directions.
  private func offerNoteReroute(noteID: UUID, appended: String, createdNote: Bool) {
    guard captureMode == .auto, !vm.isActionRecording else { return }
    // The raw transcript is what the agent should parse — `appended` may
    // have been through an AI format pass, which rewrites a command into
    // prose and loses the instruction.
    let transcript = vm.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else { return }
    vm.armNoteReroute(NoteRerouteOffer(
      transcript: transcript,
      noteID: noteID,
      appendedText: appended,
      createdNote: createdNote
    ))
  }

  /// Takes the dictation back out of the note and hands it to the agent.
  private func runNoteReroute() {
    guard let offer = vm.noteRerouteOffer else { return }
    vm.clearNoteReroute()

    let retracted = notes.retractAppend(id: offer.noteID, text: offer.appendedText)
    // A note this capture created, now empty again, is a shell the user
    // never asked for — take it with us. A note that already existed stays.
    if retracted, offer.createdNote,
       let note = notes.notes.first(where: { $0.id == offer.noteID }),
       note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      notes.deleteNote(id: offer.noteID)
      if path == [.note(offer.noteID)] { path = [] }
    }
    // Let the same transcript append again if the user re-routes back.
    lastAppendedTranscript = ""

    vm.isActionRecording = true
    vm.wasAutoRouted = true
    Task { await vm.rerunAsAction(offer.transcript, provider: aiProvider) }
  }

  // MARK: - Background

  @Environment(\.colorScheme) private var colorScheme

  /// The page gradient from the design tokens: a soft vertical wash in
  /// light, a radial glow from above in dark.
  private var backgroundGradient: some View {
    let theme = QuillTheme.of(colorScheme)
    return Group {
      if theme.isDark {
        RadialGradient(
          gradient: Gradient(colors: theme.pageGradient),
          center: UnitPoint(x: 0.5, y: -0.08),
          startRadius: 0,
          endRadius: 900
        )
      } else {
        LinearGradient(
          gradient: Gradient(colors: theme.pageGradient),
          startPoint: .top,
          endPoint: .bottom
        )
      }
    }
  }

  // MARK: - Mode chips

  /// Built-in modes the user has hidden via Settings → AI Modes.
  /// `.off` is never hideable — the user always needs a way back to
  /// Raw, even if every other mode is disabled.
  private var disabledBuiltInModes: Set<AIProcessingMode> {
    BuiltInModeVisibility.decode(disabledBuiltInModesData)
  }

  /// Resolved custom prompt to thread through `vm.toggleRecording`. Pulls
  /// the current selection's prompt only when it's a custom mode — built-
  /// in modes use their own `mode.systemPrompt` via `aiMode`.
  private var micCustomSystemPrompt: String? {
    if case .custom = currentSelection {
      return currentSelection.resolveSystemPrompt(customModes: customModes)
    }
    return nil
  }

  /// Compact floating status card rendered above the FAB cluster. Only
  /// visible for non-idle phases; hidden when `.idle` or `.done` so the
  /// notes underneath stay clean.
  @ViewBuilder
  private var statusCard: some View {
    if showOfflineQueuedBanner {
      statusPill(
        "Saved offline — will retry when online",
        icon: "wifi.exclamationmark",
        tint: .orange
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }
    if let aiError = vm.aiErrorMessage, vm.phase == .done {
      statusPill(aiError, icon: "exclamationmark.triangle", tint: .orange)
    }
    if let banner = vm.noteTargetBanner {
      statusPill(banner, icon: "note.text.badge.plus", tint: QuillDesign.success)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
    // Whisper model load runs on first launch (and when the user
    // switches models). The first transcription blocks on this if
    // it hasn't finished — surface it so users see "Loading model"
    // rather than a 60-120 s hang during "Transcribing…".
    if vm.isPreparingModel, vm.phase != .recording {
      statusPill("Loading Whisper model…", icon: "arrow.down.circle", tint: .blue)
    }
    switch vm.phase {
    case .recording:
      // No status pill while recording — the new layout owns the
      // recording UI: live transcript card in the canvas, waveform
      // pinned to the bottom, timer in the active-note strip. The
      // legacy floating timer pill that lived here is gone.
      EmptyView()
    case .requestingPermission:
      statusPill("Requesting mic…", icon: "mic.slash", tint: .secondary)
    case .transcribing:
      statusPill("Transcribing…", icon: "waveform", tint: .blue)
    case .actionParsing:
      statusPill("Parsing action…", icon: "bolt.fill", tint: QuillDesign.actionAccent)
    case .aiProcessing:
      statusPill("Enhancing with \(aiProvider.displayName)…", icon: "sparkles", tint: .purple)
    case .error(let msg):
      statusPill(msg, icon: "exclamationmark.triangle", tint: .red)
    case .idle, .done:
      EmptyView()
    }
  }

  private func statusPill(_ text: String, icon: String, tint: Color) -> some View {
    Label(text, systemImage: icon)
      .font(.caption.weight(.medium))
      .foregroundStyle(tint)
      .lineLimit(2)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        Capsule().fill(.ultraThinMaterial)
      )
      .frame(maxWidth: 260, alignment: .trailing)
  }

  private func formatElapsed(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    let cs = Int((seconds - floor(seconds)) * 10)
    return String(format: "%02d:%02d.%d", m, s, cs)
  }

  // MARK: - Result

  /// Flip a `- [ ]` / `- [x]` marker tapped in the note canvas. The
  /// canvas renders body *segments* (text between photo tokens), so the
  /// toggle runs on the segment string and the edited segment is
  /// spliced back into the note body at its first occurrence.
  private func toggleCheckbox(noteID: UUID, segmentText: String, lineIndex: Int) {
    guard let note = notes.notes.first(where: { $0.id == noteID }),
          let toggledSegment = MarkdownCheckbox.toggleLine(lineIndex, in: segmentText),
          let range = note.body.range(of: segmentText)
    else { return }
    var body = note.body
    body.replaceSubrange(range, with: toggledSegment)
    notes.updateBody(id: noteID, to: body)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  private func noteCanvas(for note: Note) -> some View {
    let tint: Color = aiMode == .off ? .blue : .purple
    let segments = NoteContent.segments(from: note.body)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Label(
          aiMode == .off ? "Transcript" : "\(aiMode.displayName) mode",
          systemImage: aiMode == .off ? "waveform" : "sparkles"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)

        Spacer()

        if note.photoCount > 0 {
          Label("\(note.photoCount)", systemImage: "photo")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Text("\(note.wordCount) words")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.trailing, 2)

        noteEditButton(for: note, tint: tint)
        noteShareMenu(for: note, tint: tint)
        noteCopyButton(for: note, tint: tint)
        noteDeleteButton(for: note)
      }

      VStack(alignment: .leading, spacing: 12) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
          segmentView(seg, noteID: note.id)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(tint.opacity(0.08))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .stroke(tint.opacity(0.15), lineWidth: 1)
        )
    )
  }

  @ViewBuilder
  private func segmentView(_ seg: NoteSegment, noteID: UUID) -> some View {
    switch seg {
    case .text(let text):
      NoteTextView(
        text: text,
        headingColor: .purple,
        onToggleCheckbox: { lineIndex in
          toggleCheckbox(noteID: noteID, segmentText: text, lineIndex: lineIndex)
        }
      )
      .textSelection(.enabled)
    case .photo(let photoID):
      VStack(alignment: .leading, spacing: 8) {
        if let ui = PhotoStore.shared.loadImage(noteID: noteID, photoID: photoID) {
          Image(uiImage: ui)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous))
        } else {
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 80)
            .overlay(
              Label("Missing photo", systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
            )
        }
        analysisCard(noteID: noteID, photoID: photoID)
      }
    }
  }

  @ViewBuilder
  private func analysisCard(noteID: UUID, photoID: UUID) -> some View {
    let analyzing = notes.analyzingPhotoIDs.contains(photoID)
    let analysis = notes.photoAnalyses[photoID]
    let error = notes.analysisErrors[photoID]

    if analyzing {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Analyzing photo…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card).fill(Color.purple.opacity(0.06))
      )
    } else if let analysis {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
          Text("AI Analysis")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
          Spacer()
        }

        if !analysis.summary.isEmpty {
          Text(analysis.summary)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
        }

        if !analysis.keyDetails.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(analysis.keyDetails.enumerated()), id: \.offset) { _, detail in
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.purple)
                Text(detail)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
          }
        }

        if let transcribed = analysis.transcribedText, !transcribed.isEmpty {
          DisclosureGroup {
            Text(transcribed)
              .font(.footnote.monospaced())
              .foregroundStyle(.primary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 4)
          } label: {
            Label("Transcribed text", systemImage: "text.viewfinder")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card).fill(Color.purple.opacity(0.08))
      )
    } else if let error {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
          Button {
            showingSettings = true
          } label: {
            Label("Open Settings", systemImage: "gearshape")
              .font(.caption.weight(.semibold))
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.orange)

          Button {
            notes.analyzePhoto(noteID: noteID, photoID: photoID, provider: aiProvider)
          } label: {
            Label("Retry", systemImage: "arrow.clockwise")
              .font(.caption.weight(.semibold))
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.orange)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: QuillDesign.Radius.card).fill(Color.orange.opacity(0.1)))
    }
  }

  /// Compact round icon button used in the note title row. Light tinted
  /// background, tint-coloured glyph — mirrors the other circular pill
  /// controls in the header/active-note strip.
  private func circleIconButton(
    systemName: String,
    tint: Color,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(Circle().fill(tint.opacity(0.14)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }

  /// Shared toolbar-glyph styling for the note-card actions: 26pt round
  /// affordance with a near-transparent tint fill so the buttons read
  /// as a connected toolbar rather than three competing color blocks.
  /// The glyph itself carries the only saturated color.
  private static let noteToolbarGlyphSize: CGFloat = 26

  private func noteShareMenu(for note: Note, tint: Color) -> some View {
    let text = NoteContent.stripPhotos(from: note.body)
    let hasPhotos = note.photoCount > 0

    return Menu {
      Button {
        shareNoteText(note)
      } label: {
        Label("Share Text Only", systemImage: "text.alignleft")
      }
      .disabled(text.isEmpty)

      Button {
        sharePDF(note)
      } label: {
        Label(
          hasPhotos ? "Share as PDF (text + photos)" : "Share as PDF",
          systemImage: "doc.richtext"
        )
      }
    } label: {
      noteToolbarGlyph(systemName: "square.and.arrow.up", tint: tint)
    }
    .disabled(isBuildingPDF)
    .opacity(isBuildingPDF ? 0.5 : 1.0)
    .accessibilityLabel("Share note")
  }

  private func noteDeleteButton(for note: Note) -> some View {
    Button {
      UISelectionFeedbackGenerator().selectionChanged()
      pendingDeleteNoteID = note.id
    } label: {
      noteToolbarGlyph(systemName: "trash", tint: .red)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Delete note")
  }

  private func noteEditButton(for note: Note, tint: Color) -> some View {
    Button {
      UISelectionFeedbackGenerator().selectionChanged()
      editingNoteID = note.id
    } label: {
      noteToolbarGlyph(systemName: "pencil", tint: tint)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Edit note")
  }

  private func noteCopyButton(for note: Note, tint: Color) -> some View {
    let text = NoteContent.stripPhotos(from: note.body)
    let effectiveTint: Color = showCopied ? .green : tint
    return Button {
      copyToClipboard(text)
    } label: {
      noteToolbarGlyph(
        systemName: showCopied ? "checkmark" : "doc.on.doc",
        tint: effectiveTint,
        contentTransition: .symbolEffect(.replace)
      )
    }
    .buttonStyle(.plain)
    .animation(.easeInOut(duration: 0.2), value: showCopied)
    .accessibilityLabel(showCopied ? "Copied" : "Copy note text")
  }

  /// 26pt round glyph with a faint tint backdrop. Used by every note-
  /// card toolbar button so they share the same restrained visual
  /// weight — the glyph reads, the affordance recedes.
  @ViewBuilder
  private func noteToolbarGlyph(
    systemName: String,
    tint: Color,
    contentTransition: ContentTransition = .identity
  ) -> some View {
    Image(systemName: systemName)
      .contentTransition(contentTransition)
      .font(.caption.weight(.semibold))
      .foregroundStyle(tint)
      .frame(width: Self.noteToolbarGlyphSize, height: Self.noteToolbarGlyphSize)
      .background(Circle().fill(tint.opacity(0.06)))
      .contentShape(Circle())
  }

  private func copyToClipboard(_ text: String) {
    UIPasteboard.general.string = text
    UINotificationFeedbackGenerator().notificationOccurred(.success)

    // Flip to the "Copied" state, then auto-revert after ~1.5s.
    copyResetTask?.cancel()
    showCopied = true
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1500))
      guard !Task.isCancelled else { return }
      showCopied = false
    }
  }

  // Legacy signature kept for backwards-compat in case a preview still
  // references it — unused in the live layout now.
  private func resultCard(title: String, icon: String, tint: Color, text: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(title, systemImage: icon)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
        Spacer()
      }
      Text(text)
        .textSelection(.enabled)
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
        .fill(tint.opacity(0.08))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.panel, style: .continuous)
            .stroke(tint.opacity(0.15), lineWidth: 1)
        )
    )
  }
}

// MARK: - Mode chip

private struct ModeChip: View {
  let mode: AIProcessingMode
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: mode.iosIconName)
          .font(.caption.weight(.semibold))
        Text(mode.iosDisplayName)
          .font(.subheadline.weight(.medium))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .modifier(ModeChipBackground(isSelected: isSelected, tint: tint))
      .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
  }

  private var tint: Color {
    switch mode {
    case .off: .blue
    default: .purple
    }
  }
}

/// Mode chip for user-authored custom modes. Visually matches
/// `ModeChip` (same capsule / tint / padding) so the two types read
/// as one unified picker row.
private struct CustomModeChip: View {
  let mode: CustomAIMode
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: mode.icon)
          .font(.caption.weight(.semibold))
        Text(mode.displayName)
          .font(.subheadline.weight(.medium))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .modifier(ModeChipBackground(isSelected: isSelected, tint: .purple))
      .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
  }
}

/// Shared chip background for built-in `ModeChip` and `CustomModeChip`.
/// On the selected state, layers (1) the tinted capsule fill,
/// (2) a top-edge inset white highlight that reads as a slight bevel,
/// and (3) a purple drop-glow so the chip lifts off the row.
/// Unselected stays restrained — light gray fill + 1pt outline.
private struct ModeChipBackground: ViewModifier {
  let isSelected: Bool
  let tint: Color

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          Capsule()
            .fill(isSelected ? tint : Color.secondary.opacity(0.12))
          if isSelected {
            // Inset white glow at the top edge — fades from 35% white
            // at the top to nothing by the midpoint. Reads as a
            // pressed-button highlight rather than a border.
            Capsule()
              .strokeBorder(
                LinearGradient(
                  colors: [.white.opacity(0.35), .clear],
                  startPoint: .top,
                  endPoint: .bottom
                ),
                lineWidth: 1
              )
          }
        }
      }
      .overlay {
        if !isSelected {
          Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
      }
      // Drop glow only on selected — soft purple-tint shadow that
      // signals brand-pressed state, distinct from the light gray
      // inactive chips.
      .shadow(
        color: isSelected ? tint.opacity(0.40) : .clear,
        radius: 6,
        y: 2
      )
  }
}

#Preview {
  ContentView()
}
