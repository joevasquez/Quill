//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ApplicationServices
import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var isAIProcessing: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var capturedContext: AppContext?
    var partialTranscript: String = ""
    /// Set at recording-start when `inlineEditEnabled` is on AND the
    /// focused app had a non-empty selection. When this is non-nil,
    /// the dictation is interpreted as an *instruction* for editing
    /// this text rather than as new content to paste. The transcript
    /// pipeline branches on this at finalize time.
    var inlineEditSelection: String?
    /// User-selected mode for the HUD pill. Cycles through
    /// Auto → Dictate → Edit → Action on tap.
    var selectedMode: TranscriptionIndicatorView.Mode = .auto
    /// When selectedMode is .auto, the live-detected sub-mode based
    /// on partial transcript keyword analysis. Updated on every
    /// partialTranscriptUpdated. Reset on recording start.
    var autoDetectedMode: TranscriptionIndicatorView.Mode = .dictate
    /// Transient message shown when the user tries to record in
    /// Edit mode without highlighting text. Auto-dismissed after 3s.
    var editNeedsSelectionMessage: String?
    /// After an inline edit replaces text, holds the original so
    /// the user can accept (✓) or undo (✗) from the HUD.
    var pendingEditResult: PendingEditResult?
    var pendingAction: ActionIntent?
    var isActionExecuting: Bool = false
    /// Connected & authenticated integrations available as Action targets.
    /// Loaded on `.task` and refreshed when the user enters Action mode.
    var availableActionIntegrations: [Integration.Identifier] = []
    /// User's hard-locked Action integration. When non-nil, the LLM-picked
    /// `targetIntegration` is overridden with this value before the
    /// confirmation panel opens. Toggled from the HUD picker row.
    var lockedActionIntegration: Integration.Identifier?
    /// The raw transcript that was sent to the action LLM parser. Carried
    /// through to the confirmation panel so the "HEARD" section can quote it.
    var lastActionTranscript: String = ""
    /// True when a clipboard-based selection capture is in flight (Edit mode,
    /// AX failed). Prevents the transcription result from racing ahead of the
    /// clipboard fallback — if the transcription finishes first, the result
    /// is stashed in `pendingTranscriptionForEdit` and replayed once the
    /// clipboard result arrives.
    var editClipboardFallbackPending: Bool = false
    var pendingTranscriptionForEdit: PendingTranscription?
    var recordingSessionID = UUID()
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.usageStats) var usageStats: UsageStats
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL, sessionID: UUID)
    case transcriptionError(Error, URL?, sessionID: UUID)
    case aiProcessingFinished
    case contextCaptured(AppContext)
    case partialTranscriptUpdated(String)
    /// Fired after AX finishes reading the selection at recording-
    /// start (see `inlineEdit.captureSelection`). Non-nil value
    /// tells the finalize path to treat the dictation as an edit
    /// instruction and replace this selection rather than paste.
    case inlineEditSelectionCaptured(String)

    // Mode cycling
    case cycleMode
    /// Direct mode selection (menu-bar Mode submenu). `cycleMode` funnels
    /// through this so both paths share the reset/refresh side effects.
    case setMode(TranscriptionIndicatorView.Mode)

    // Edit mode
    case editNeedsSelectionDismiss
    /// Result of the clipboard fallback capture (Cmd+C → read).
    /// Sent when AX-based selection reading failed and we tried the
    /// clipboard path instead. `isEditMode` controls failure behavior:
    /// Edit mode cancels transcription; Dictate mode falls through.
    case editClipboardFallbackResult(String?, isEditMode: Bool)
    case inlineEditApplied(PendingEditResult)
    case inlineEditAccept
    case inlineEditUndo

    // Action mode
    /// A command typed (not spoken) via the menu bar's "Type a Command…"
    /// panel — runs the same agent pipeline as a dictated action.
    case typedActionSubmitted(String)
    case actionIntentParsed(ActionIntent)
    case multiActionIntentsParsed([ActionIntent])
    case actionParsingFailed(String)
    /// Network failure caught during LLM parsing; the raw transcript was
    /// persisted to the offline queue and will be re-parsed + executed
    /// when connectivity returns. Treated as a soft success.
    case actionParsingQueued
    case actionExecuted
    case actionCancelled
    case presentActionConfirmation(ActionIntent, String)
    case presentMultiActionConfirmation([ActionIntent], String)
    case actionIntegrationsLoaded([Integration.Identifier])
    case toggleActionIntegrationLock(Integration.Identifier)
    case loadActionIntegrations
    /// fn+1..fn+9 keyboard toggle. The digit (1-based) selects the
    /// integration in `availableActionIntegrations` at index `digit - 1`.
    /// No-op if the digit is out of range or Action mode isn't active.
    case actionIntegrationKeyboardToggle(Int)

    // Agent routines
    /// A dictated trigger phrase matched a saved routine — its stored steps
    /// go straight to the confirmation panel (no LLM call).
    case routineTriggered(Routine)
    /// A "new routine: …" dictation was parsed and persisted.
    case routineSaved(RoutineDraft)

    // Mode error feedback
    case editModeNeedsAPIKey
    case actionModeNeedsAPIKey
    case editModeAIFailed(String)

    // Model availability
    case modelMissing
  }

  /// Holds enough context to undo an inline edit.
  struct PendingEditResult: Equatable {
    let original: String
    let edited: String
    let sourceAppBundleID: String?
  }

  /// Stashed transcription result waiting for clipboard fallback to resolve.
  struct PendingTranscription: Equatable {
    let result: String
    let audioURL: URL
    let sessionID: UUID
  }

  enum CancelID {
    case metering
    case recordingCleanup
    case transcription
    case liveTranscription
    case editNeedsSelectionTimer
    case editAcceptanceTimer
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.aiProcessing) var aiProcessing
  @Dependency(\.contextClient) var contextClient
  @Dependency(\.inlineEdit) var inlineEdit
  @Dependency(\.actionParsing) var actionParsing
  @Dependency(\.speechRecognition) var speechRecognition
  @Dependency(\.keychain) var keychain
  @Dependency(\.googleOAuth) var googleOAuth

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        // 4) Asking for speech-recognition permission so the live preview
        //    works on the very first recording (silently no-ops if denied)
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect(),
          .run { [speechRecognition] _ in
            _ = await speechRecognition.requestAuthorization()
          },
          .send(.loadActionIntegrations)
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL, sessionID):
        guard sessionID == state.recordingSessionID else {
          transcriptionFeatureLogger.info("Ignoring stale transcription result from session \(sessionID)")
          return .run { _ in try? FileManager.default.removeItem(at: audioURL) }
        }
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

      case let .transcriptionError(error, audioURL, sessionID):
        guard sessionID == state.recordingSessionID else {
          transcriptionFeatureLogger.info("Ignoring stale transcription error from session \(sessionID)")
          return .run { _ in
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
          }
        }
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .aiProcessingFinished:
        state.isAIProcessing = false
        return .none

      case let .contextCaptured(context):
        state.capturedContext = context
        return .none

      case let .partialTranscriptUpdated(text):
        state.partialTranscript = text
        // In Auto mode, run the classifier on every partial transcript
        // update so the orb badge shifts in real time.
        if state.selectedMode == .auto {
          state.autoDetectedMode = AutoModeClassifier.classifyPartial(text).indicatorMode
        }
        return .none

      case let .inlineEditSelectionCaptured(selection):
        state.inlineEditSelection = selection
        transcriptionFeatureLogger.info("Inline edit: captured selection (\(selection.count) chars)")
        return .none

      case .cycleMode:
        return .send(.setMode(state.selectedMode.next))

      case let .setMode(newMode):
        let modeChanged = state.selectedMode != newMode
        state.selectedMode = newMode
        transcriptionFeatureLogger.info("Mode set to \(newMode.rawValue)")
        // Reset auto-detected mode when entering Auto.
        if state.selectedMode == .auto {
          state.autoDetectedMode = .dictate
        }
        // Announce the switch so the mode-switch HUD can flash a bubble
        // when the menu bar is hidden (full-screen app). Only on an actual
        // change — re-selecting the current mode shouldn't flash anything.
        let announce: Effect<Action> = modeChanged
          ? .run { [name = newMode.rawValue] _ in
              await MainActor.run { ModeChangeNotification.post(modeName: name) }
            }
          : .none
        // Refresh available integrations for Action or Auto (Auto may
        // resolve to Action at stop time).
        if state.selectedMode == .action || state.selectedMode == .auto {
          return .merge(announce, .send(.loadActionIntegrations))
        }
        return announce

      // MARK: - Edit Mode

      case .editNeedsSelectionDismiss:
        state.editNeedsSelectionMessage = nil
        return .none

      case let .editClipboardFallbackResult(selection, isEditMode):
        state.editClipboardFallbackPending = false

        if let selection {
          state.inlineEditSelection = selection
          let charCount = selection.count
          transcriptionFeatureLogger.info(
            "Inline edit: clipboard fallback captured \(charCount) chars (isEditMode=\(isEditMode))"
          )
        } else if isEditMode {
          // No selection captured. Don't cancel transcription — the
          // Edit-mode-no-selection branch in handleTranscriptionResult
          // will treat the dictation as a standalone AI instruction.
          transcriptionFeatureLogger.notice(
            "Edit mode: both AX and clipboard capture failed — continuing with no-selection fallback"
          )
        } else {
          transcriptionFeatureLogger.info(
            "Dictate mode: both AX and clipboard capture failed — falling through to normal paste path"
          )
        }

        // If the transcription result arrived before this clipboard
        // fallback (race condition), replay the stashed result now
        // that we know whether a selection was captured.
        if let stashed = state.pendingTranscriptionForEdit {
          state.pendingTranscriptionForEdit = nil
          transcriptionFeatureLogger.info(
            "Replaying stashed transcription result after clipboard fallback resolved"
          )
          return .send(.transcriptionResult(stashed.result, stashed.audioURL, sessionID: stashed.sessionID))
        }
        return .none

      case let .inlineEditApplied(pending):
        state.pendingEditResult = pending
        // Auto-accept after 10 seconds if the user doesn't act.
        return .run { send in
          try? await Task.sleep(for: .seconds(10))
          await send(.inlineEditAccept)
        }
        .cancellable(id: CancelID.editAcceptanceTimer, cancelInFlight: true)

      case .inlineEditAccept:
        state.pendingEditResult = nil
        return .cancel(id: CancelID.editAcceptanceTimer)

      case .inlineEditUndo:
        guard let pending = state.pendingEditResult else { return .none }
        state.pendingEditResult = nil
        let bundleID = pending.sourceAppBundleID
        return .merge(
          .cancel(id: CancelID.editAcceptanceTimer),
          .run { [inlineEdit] _ in
            // Send Cmd+Z to the source app. The previous "select and
            // replace with original" approach failed because the
            // cursor is collapsed at the end of the edited text after
            // AX-set or paste — calling replaceSelection again just
            // inserted the original text *after* the edit.
            await inlineEdit.undoLastEdit(bundleID)
            soundEffect.play(.cancel)
          }
        )

      // MARK: - Action Mode

      case let .typedActionSubmitted(text):
        // Typed commands run the same agent pipeline as spoken ones —
        // routine authoring, trigger fast-path, memory context, MCP —
        // just without the recorder/Whisper front-half (and without a
        // history entry: there's no audio, and the panel is the record).
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return .none }
        state.isAIProcessing = true
        state.lastActionTranscript = typed
        state.$usageStats.withLock { stats in
          stats.actionCount += 1
          stats.totalWordsTranscribed += transcriptionWordCount(of: typed)
        }
        let typedAgentName = state.hexSettings.agentName
        let typedMemoryEnabled = state.hexSettings.agentMemoryEnabled
        let typedProvider = state.hexSettings.aiProvider
        return .run { [actionParsing] send in
          if let routineDescription = RoutineMatcher.authoringRequest(transcript: typed, agentName: typedAgentName) {
            do {
              let draft = try await actionParsing.parseRoutine(routineDescription, typedProvider)
              await RoutineStore.shared.add(
                Routine(name: draft.name, triggerPhrases: [draft.triggerPhrase], steps: draft.actions)
              )
              await send(.aiProcessingFinished)
              await send(.routineSaved(draft))
            } catch {
              await send(.aiProcessingFinished)
              if let actionError = error as? ActionParsingError, case .missingAPIKey = actionError {
                await send(.actionModeNeedsAPIKey)
              } else {
                await send(.actionParsingFailed(typed))
              }
            }
            return
          }

          let routines = await RoutineStore.shared.loadAll()
          if let routine = RoutineMatcher.match(transcript: typed, routines: routines) {
            await RoutineStore.shared.recordRun(id: routine.id)
            await send(.aiProcessingFinished)
            await send(.routineTriggered(routine))
            return
          }

          do {
            let response = try await actionParsing.parseMulti(typed, typedProvider, nil)
            await send(.aiProcessingFinished)
            if response.isSingleAction, let intent = response.actions.first,
               intent.actionType != .mcpCall, intent.actionType != .open {
              await send(.actionIntentParsed(intent))
            } else {
              await send(.multiActionIntentsParsed(response.actions))
            }
            if typedMemoryEnabled {
              Task {
                if let candidates = try? await actionParsing.extractMemory(typed, typedProvider),
                   !candidates.isEmpty {
                  await MemoryStore.shared.upsert(candidates)
                }
              }
            }
          } catch {
            await send(.aiProcessingFinished)
            if let actionError = error as? ActionParsingError, case .missingAPIKey = actionError {
              await send(.actionModeNeedsAPIKey)
            } else if QueueableErrorClassifier.isQueueable(error) {
              await ActionQueueManager.shared.enqueueTranscript(
                typed, provider: typedProvider, lastError: error.localizedDescription
              )
              await send(.actionParsingQueued)
            } else {
              await send(.actionParsingFailed(typed))
            }
          }
        }

      case let .actionIntentParsed(intent):
        // Apply hard-lock: if the user pre-selected an integration on the
        // HUD picker, override whatever the LLM chose so the action lands
        // in the user's pick regardless of voice phrasing.
        var resolvedIntent = intent
        if let locked = state.lockedActionIntegration {
          resolvedIntent.targetIntegration = locked
        }
        state.pendingAction = resolvedIntent
        let raw = state.lastActionTranscript
        return .send(.presentActionConfirmation(resolvedIntent, raw))

      case let .multiActionIntentsParsed(intents):
        // Multi-action: apply hard-lock to all intents if set.
        var resolvedIntents = intents
        if let locked = state.lockedActionIntegration {
          resolvedIntents = intents.map { intent in
            var r = intent
            r.targetIntegration = locked
            return r
          }
        }
        state.pendingAction = resolvedIntents.first
        let raw = state.lastActionTranscript
        return .send(.presentMultiActionConfirmation(resolvedIntents, raw))

      case let .routineTriggered(routine):
        // The user authored these steps explicitly when saving the routine,
        // so the HUD integration hard-lock does NOT override them.
        state.pendingAction = routine.steps.first
        let rawRoutineTranscript = state.lastActionTranscript
        let routineBundleID = state.sourceAppBundleID
        return .run { _ in
          await MainActor.run {
            ActionConfirmationNotification.postMulti(
              intents: routine.steps,
              rawTranscript: rawRoutineTranscript,
              autoExecute: routine.autoRun,
              sourceAppBundleID: routineBundleID
            )
          }
        }

      case let .routineSaved(draft):
        state.editNeedsSelectionMessage = "Routine saved — say \u{201C}\(draft.triggerPhrase)\u{201D}"
        return .merge(
          .run { _ in soundEffect.play(.pasteTranscript) },
          .run { send in
            try? await Task.sleep(for: .seconds(4))
            await send(.editNeedsSelectionDismiss)
          }
          .cancellable(id: CancelID.editNeedsSelectionTimer, cancelInFlight: true)
        )

      case let .actionParsingFailed(rawText):
        transcriptionFeatureLogger.warning("Action parsing failed; falling back to paste")
        state.editNeedsSelectionMessage = "Action failed — pasted as text"
        let bundleID = state.sourceAppBundleID
        return .merge(
          .run { [pasteboard] _ in
            await pasteboard.paste(rawText, bundleID)
            soundEffect.play(.pasteTranscript)
          },
          .run { send in
            try? await Task.sleep(for: .seconds(3))
            await send(.editNeedsSelectionDismiss)
          }
          .cancellable(id: CancelID.editNeedsSelectionTimer, cancelInFlight: true)
        )

      case .editModeNeedsAPIKey:
        state.editNeedsSelectionMessage = "Add an API key in Settings → AI"
        return .merge(
          .run { _ in soundEffect.play(.cancel) },
          .run { send in
            try? await Task.sleep(for: .seconds(3))
            await send(.editNeedsSelectionDismiss)
          }
          .cancellable(id: CancelID.editNeedsSelectionTimer, cancelInFlight: true)
        )

      case .actionModeNeedsAPIKey:
        state.editNeedsSelectionMessage = "Add an API key in Settings → AI"
        return .merge(
          .run { _ in soundEffect.play(.cancel) },
          .run { send in
            try? await Task.sleep(for: .seconds(3))
            await send(.editNeedsSelectionDismiss)
          }
          .cancellable(id: CancelID.editNeedsSelectionTimer, cancelInFlight: true)
        )

      case let .editModeAIFailed(rawText):
        state.editNeedsSelectionMessage = "Edit failed — pasted as text"
        let bundleID = state.sourceAppBundleID
        return .merge(
          .run { [pasteboard] _ in
            await pasteboard.paste(rawText, bundleID)
            soundEffect.play(.pasteTranscript)
          },
          .run { send in
            try? await Task.sleep(for: .seconds(3))
            await send(.editNeedsSelectionDismiss)
          }
          .cancellable(id: CancelID.editNeedsSelectionTimer, cancelInFlight: true)
        )

      case .actionParsingQueued:
        // Same audio cue as a successful paste — confirms something
        // happened. The menu bar status item picks up the pending count
        // automatically (see HexAppDelegate.refreshStatusItemTooltip).
        transcriptionFeatureLogger.info("Action parsing queued for offline retry")
        soundEffect.play(.pasteTranscript)
        NotificationCenter.default.post(name: .actionConfirmationExecuted, object: nil)
        return .none

      case .actionExecuted:
        state.pendingAction = nil
        return .none

      case .actionCancelled:
        state.pendingAction = nil
        return .none

      case let .presentActionConfirmation(intent, rawTranscript):
        transcriptionFeatureLogger.info("Posting action confirmation notification for intent: \(intent.title, privacy: .private)")
        return .run { _ in
          await MainActor.run {
            ActionConfirmationNotification.post(intent: intent, rawTranscript: rawTranscript)
          }
        }

      case let .presentMultiActionConfirmation(intents, rawTranscript):
        transcriptionFeatureLogger.info("Posting multi-action confirmation notification for \(intents.count, privacy: .public) intents")
        let multiBundleID = state.sourceAppBundleID
        return .run { _ in
          await MainActor.run {
            ActionConfirmationNotification.postMulti(intents: intents, rawTranscript: rawTranscript, sourceAppBundleID: multiBundleID)
          }
        }

      case let .actionIntegrationsLoaded(integrations):
        state.availableActionIntegrations = integrations
        // Drop the lock if the locked integration is no longer available
        // (e.g. user signed out of Google). Keeps the picker honest.
        if let locked = state.lockedActionIntegration, !integrations.contains(locked) {
          state.lockedActionIntegration = nil
        }
        return .none

      case let .toggleActionIntegrationLock(id):
        if state.lockedActionIntegration == id {
          state.lockedActionIntegration = nil
        } else {
          state.lockedActionIntegration = id
        }
        return .none

      case let .actionIntegrationKeyboardToggle(digit):
        // Only honor while in Action mode — otherwise the global tap
        // would be hijacking fn+digit for users not even using Action.
        guard state.selectedMode == .action else { return .none }
        let index = digit - 1
        guard index >= 0, index < state.availableActionIntegrations.count else {
          return .none
        }
        let id = state.availableActionIntegrations[index]
        return .send(.toggleActionIntegrationLock(id))

      case .loadActionIntegrations:
        return .run { [keychain, googleOAuth] send in
          let connected = IntegrationConnectionStore.decode(
            UserDefaults.standard.data(forKey: IntegrationConnectionStore.userDefaultsKey)
          )
          var available: [Integration.Identifier] = [.appleReminders, .calendar]
          if connected.contains(.todoist),
             let token = await keychain.read(KeychainKey.todoistAPIToken),
             !token.isEmpty {
            available.append(.todoist)
          }
          if await googleOAuth.isAuthorized() {
            if connected.contains(.googleCalendar) { available.append(.googleCalendar) }
            if connected.contains(.gmail) { available.append(.gmail) }
          }
          await send(.actionIntegrationsLoaded(available))
        }

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      nonisolated(unsafe) var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      let _isSettingHotKey = Shared(wrappedValue: false, .isSettingHotKey)
      let _hexSettings = Shared(wrappedValue: HexSettings(), .hexSettings)

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if _isSettingHotKey.wrappedValue {
          return false
        }

        let hexSettings = _hexSettings.wrappedValue
        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

          // Process the key event
          switch hotKeyProcessor.process(keyEvent: keyEvent) {
          case .startRecording:
            // If double-tap lock is triggered, we start recording immediately
            if hotKeyProcessor.state == .doubleTapLock {
              Task { await send(.startRecording) }
            } else {
              Task { await send(.hotKeyPressed) }
            }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }

  /// Periodically snapshots the in-progress recording and transcribes it for live display.
  func startLiveTranscriptionEffect(model: String, language: String?) -> Effect<Action> {
    .run { send in
      transcriptionFeatureLogger.info("Live transcription started, waiting 1.5s for initial audio...")
      try? await Task.sleep(for: .seconds(1.5))

      while !Task.isCancelled {
        if let snapshotURL = await recording.snapshotCurrentRecording() {
          transcriptionFeatureLogger.info("Live transcription: got snapshot, transcribing...")
          do {
            let options = DecodingOptions(
              language: language,
              detectLanguage: language == nil,
              chunkingStrategy: .vad
            )
            let result = try await transcription.transcribe(snapshotURL, model, options) { _ in }
            if !result.isEmpty {
              transcriptionFeatureLogger.info("Live transcript partial: '\(result)'")
              await send(.partialTranscriptUpdated(result))
            }
          } catch {
            transcriptionFeatureLogger.warning("Live transcription chunk failed: \(error.localizedDescription)")
          }
          try? FileManager.default.removeItem(at: snapshotURL)
        } else {
          transcriptionFeatureLogger.debug("Live transcription: no snapshot available")
        }

        try? await Task.sleep(for: .seconds(1.5))
      }
    }
    .cancellable(id: CancelID.liveTranscription, cancelInFlight: true)
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none
    let startRecording = Effect.send(Action.startRecording)
    return .merge(maybeCancel, startRecording)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    // Starting is idempotent: ignore a start while a recording is already in
    // flight. Without this, a stray duplicate `.startRecording` (e.g. the
    // hotkey processor re-emitting a press mid-hold) silently DESTROYS the
    // take — `beginRecording` resets `recordingStartTime` and makes the
    // capture controller re-open the audio file, truncating everything
    // spoken so far. Observed as a 75s dictation landing as 13s of audio
    // with only the closing sentence transcribed.
    guard !state.isRecording else {
      transcriptionFeatureLogger.notice(
        "Ignoring duplicate startRecording — a recording is already in flight"
      )
      return .none
    }

    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.recordingSessionID = UUID()
    state.pendingEditResult = nil
    state.editNeedsSelectionMessage = nil
    state.capturedContext = nil
    state.partialTranscript = ""
    state.inlineEditSelection = nil
    state.editClipboardFallbackPending = false
    state.pendingTranscriptionForEdit = nil
    state.isTranscribing = false
    state.isAIProcessing = false
    state.autoDetectedMode = .dictate

    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }

    // All modes (Dictate, Edit, Action) take the same path here.
    // Edit-mode selection capture is deferred to handleStopRecording
    // so no AX / clipboard work can interfere with recording start.
    return beginRecording(&state)
  }

  /// Start audio recording and associated effects (sound, sleep
  /// prevention, context capture). Mode-agnostic — Edit-mode
  /// selection capture happens later in `handleStopRecording`.
  func beginRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    let contextEnrichmentEnabled = state.hexSettings.contextEnrichmentEnabled && state.hexSettings.aiProcessingEnabled

    let outputLanguage = state.hexSettings.outputLanguage

    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .cancel(id: CancelID.liveTranscription),
      .cancel(id: CancelID.transcription),
      .run { [sleepManagement, contextClient, preventSleep = state.hexSettings.preventSystemSleep] send in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }

        // Capture context from active app before recording starts
        if contextEnrichmentEnabled {
          let context = await contextClient.captureContext()
          await send(.contextCaptured(context))
        }

        await recording.startRecording()
      },
      // Live preview via Apple's SFSpeechRecognizer (on-device when supported).
      // Runs in parallel with the file-based RecordingClient — both consume the
      // default input device. The authoritative transcript is still produced
      // by WhisperKit/Parakeet on stop. Stream is closed via CancelID.liveTranscription.
      .run { [speechRecognition] send in
        let stream = await speechRecognition.startRecognition(outputLanguage)
        for await partial in stream {
          await send(.partialTranscriptUpdated(partial))
        }
      }
      .cancellable(id: CancelID.liveTranscription, cancelInFlight: true)
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.partialTranscript = ""
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return .merge(
        .cancel(id: CancelID.liveTranscription),
        .run { [speechRecognition] _ in await speechRecognition.stopRecognition() },
        .run { _ in
          let url = await recording.stopRecording()
          guard !Task.isCancelled else { return }
          try? FileManager.default.removeItem(at: url)
        }
        .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
      )
    }

    // ── Edit mode: capture selection at stop time ──
    //
    // Selection capture is done HERE (not at recording start) so that
    // no AX calls or clipboard work can block or delay the recording.
    // The source app is still frontmost with text highlighted because
    // the HUD is a non-activating panel, so AX reads the same state
    // the user saw when they pressed the hotkey.
    let isEditMode = state.selectedMode == .edit
    let isAutoMode = state.selectedMode == .auto
    let isActionMode = state.selectedMode == .action
    let isVDI = VDIBundleIdentifiers.isVDI(state.sourceAppBundleID)

    // Auto mode always attempts selection capture so we know at
    // transcription-result time whether the user had text selected.
    // Action mode captures too (AX-only, no clipboard fallback) so
    // commands like "add this to my Kearney list" can resolve "this"
    // to the highlighted text in the source app.
    if isEditMode || isAutoMode || isActionMode || state.hexSettings.inlineEditEnabled {
      if let selection = inlineEdit.captureSelectionSync() {
        state.inlineEditSelection = selection
        transcriptionFeatureLogger.info(
          "Edit capture: AX got \(selection.count) chars at stop time (isAutoMode=\(isAutoMode))"
        )
      } else {
        if !isEditMode && !isAutoMode && !isActionMode {
          transcriptionFeatureLogger.info(
            "Inline edit enabled but no selection — normal paste path"
          )
        }
      }
    } else {
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    state.partialTranscript = ""
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage
    let sessionID = state.recordingSessionID

    state.isPrewarming = true

    let transcriptionEffect: Effect<Action> = .merge(
      .cancel(id: CancelID.liveTranscription),
      .run { [speechRecognition] _ in await speechRecognition.stopRecognition() },
      .run { [sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        var audioURL: URL?
        do {
          let capturedURL = await recording.stopRecording()
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)
          audioURL = capturedURL

          // Create transcription options with the selected language
          // Note: cap concurrency to avoid audio I/O overloads on some Macs
          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil, // Only auto-detect if no language specified
            chunkingStrategy: .vad,
          )

          let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }

          transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
          await send(.transcriptionResult(result, capturedURL, sessionID: sessionID))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
          await send(.transcriptionError(error, audioURL, sessionID: sessionID))
        }
      }
      .cancellable(id: CancelID.transcription)
    )

    // If AX didn't capture and we attempted it (Edit mode or
    // inlineEditEnabled), run clipboard fallback in parallel with
    // transcription. The fallback result lands via
    // editClipboardFallbackResult. If transcription finishes first
    // (possible with warm models), the result is stashed and
    // replayed once the clipboard result arrives.
    //
    // VDI apps (Citrix, RDP, Horizon) are the exception: their AX layer
    // never exposes a selection (the window is a remote bitmap), so the
    // Cmd+C clipboard fallback ALWAYS runs there. With a networked
    // clipboard, that Cmd+C bumps the local pasteboard with synced/stale
    // content that looks like a selection even when nothing is selected.
    // That false positive hijacks plain dictation into the inline-edit AI
    // path (Branch 1), which is why a dictation in Citrix can come back as
    // a conversational LLM reply. So for VDI we only attempt the clipboard
    // fallback in explicit Edit mode, where the user is deliberately
    // editing a selection; in Dictate/Auto we skip it and paste normally.
    let allowClipboardFallback = isVDI
      ? isEditMode
      : (isEditMode || isAutoMode || state.hexSettings.inlineEditEnabled)
    if allowClipboardFallback && state.inlineEditSelection == nil {
      let clipboardTimeout: TimeInterval = isVDI ? 0.5 : 0.15
      transcriptionFeatureLogger.info(
        "Edit/Auto capture: AX returned nil at stop (isEditMode=\(isEditMode) isAutoMode=\(isAutoMode) isVDI=\(isVDI)) — trying clipboard fallback (timeout=\(clipboardTimeout)s) in parallel with transcription"
      )
      state.editClipboardFallbackPending = true
      return .merge(
        transcriptionEffect,
        .run { [inlineEdit] send in
          let selection = await inlineEdit.captureSelectionViaClipboard(clipboardTimeout)
          await send(.editClipboardFallbackResult(selection, isEditMode: isEditMode || isAutoMode))
        }
      )
    }

    return transcriptionEffect
  }
}

// MARK: - Transcription Handlers

private func transcriptionWordCount(of text: String) -> Int {
  text.split { $0.isWhitespace || $0.isNewline }.count
}

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result rawResult: String,
    audioURL: URL
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // Strip Whisper's non-speech diagnostic tokens ([BLANK_AUDIO],
    // [ Silence ], [Music], [APPLAUSE], [INAUDIBLE], etc.) before any
    // downstream step sees the transcript. Otherwise those tokens leak
    // into the active app's paste buffer, word-remapping output, voice
    // command detection, and history.
    let result = WhisperOutputCleaner.clean(rawResult)
    if result != rawResult {
    }

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        try? FileManager.default.removeItem(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .none
    }

    // Voice command detection — check before any text processing.
    // Whole-utterance editor commands (undo / redo / select all) are
    // executed here and short-circuit the transcript pipeline entirely.
    // Inline punctuation and structural commands ("period",
    // "new paragraph", etc.) fall through and get substituted into the
    // text below so they work mid-sentence, not only as standalone
    // utterances.
    if state.hexSettings.voiceCommandsEnabled,
       let command = VoiceCommandDetector.detect(result),
       VoiceCommand.editorCommands.contains(command)
    {
      transcriptionFeatureLogger.info("Voice command detected: \(String(describing: command))")
      return executeVoiceCommand(command, audioURL: audioURL, sourceAppBundleID: state.sourceAppBundleID)
    }

    // Inline substitution: turn "hello comma world period new paragraph
    // done" into "Hello, world.\n\nDone" before word remapping and AI
    // post-processing run. Gated by the same voiceCommandsEnabled
    // toggle as the standalone detector.
    let commandResult: String = state.hexSettings.voiceCommandsEnabled
      ? VoiceCommandSubstituter.substitute(in: result)
      : result
    if commandResult != result {
      transcriptionFeatureLogger.info("Voice command substitutions applied")
    }

    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    transcriptionFeatureLogger.info("Raw transcription: '\(commandResult)'")
    let remappings = state.hexSettings.wordRemappings
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = commandResult
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    } else {
      var output = commandResult
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      modifiedResult = remappedResult
    }

    guard !modifiedResult.isEmpty else {
      return .none
    }

    // ── Fix A: If clipboard fallback is still in flight (Edit/Auto mode,
    // AX failed), stash the transcription result and wait. The result
    // will be replayed once editClipboardFallbackResult arrives.
    if state.editClipboardFallbackPending && (state.selectedMode == .edit || state.selectedMode == .auto) && state.inlineEditSelection == nil {
      transcriptionFeatureLogger.info(
        "Stashing transcription result — clipboard fallback still pending"
      )
      state.pendingTranscriptionForEdit = PendingTranscription(
        result: rawResult,
        audioURL: audioURL,
        sessionID: state.recordingSessionID
      )
      return .none
    }

    // ── Auto mode: resolve the effective pipeline mode ──
    // Uses the full transcript + selection state to decide which branch
    // (Edit / Action / Dictate) to route through.
    let effectiveMode: TranscriptionIndicatorView.Mode
    if state.selectedMode == .auto {
      effectiveMode = AutoModeClassifier.resolve(
        transcript: modifiedResult,
        hasSelection: state.inlineEditSelection != nil,
        hasIntegrations: !state.availableActionIntegrations.isEmpty
      ).indicatorMode
      state.autoDetectedMode = effectiveMode
      let _hasSelection = state.inlineEditSelection != nil
      transcriptionFeatureLogger.info("Auto mode resolved to \(effectiveMode.rawValue) (hasSelection=\(_hasSelection))")
    } else {
      effectiveMode = state.selectedMode
    }

    // Resolve AI processing mode (context-aware or manual)
    let resolvedMode = resolveAIMode(state: state)
    let aiEnabled = state.hexSettings.aiProcessingEnabled && resolvedMode != .off
    let aiProvider = state.hexSettings.aiProvider

    if aiEnabled {
      state.isAIProcessing = true
      transcriptionFeatureLogger.info("AI processing enabled: \(resolvedMode.displayName) mode via \(aiProvider.displayName)")
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let capturedContext = state.capturedContext
    let transcriptionHistory = state.$transcriptionHistory
    let inlineEditSelection = state.inlineEditSelection
    let sessionID = state.recordingSessionID
    let selectedMode = state.selectedMode

    // Decision-tree log — emitted before every finalize so we can
    // see at a glance which branch is taken and why.
    let _inlineEditEnabled = state.hexSettings.inlineEditEnabled
    let _selectionLabel: String = {
      guard let sel = inlineEditSelection else { return "nil" }
      return "captured(\(sel.count) chars)"
    }()
    let _previewSnippet = String(modifiedResult.prefix(80))
    transcriptionFeatureLogger.info(
      "Finalize: inlineEditEnabled=\(_inlineEditEnabled) inlineEditSelection=\(_selectionLabel) aiEnabled=\(aiEnabled) mode=\(resolvedMode.rawValue) selectedMode=\(selectedMode.rawValue) effectiveMode=\(effectiveMode.rawValue) preview=\"\(_previewSnippet, privacy: .private)\""
    )

    // ── Branch 1: Inline edit (selection captured) ──
    // Fires when selection exists AND one of:
    //  - Auto resolved to Edit (selection + edit keywords)
    //  - Explicit Edit mode is active
    //  - inlineEditEnabled is on (any non-Auto, non-Action mode)
    // Explicit Action mode is excluded: it now captures a selection too
    // (as context for "add this to …" commands), and the global inline-
    // edit toggle must not hijack those dictations into the edit path.
    let shouldInlineEdit = inlineEditSelection != nil && (
      effectiveMode == .edit ||
      (selectedMode != .auto && selectedMode != .action && _inlineEditEnabled)
    )
    if shouldInlineEdit, let selection = inlineEditSelection, !modifiedResult.isEmpty {
      state.$usageStats.withLock { stats in
        stats.editCount += 1
        stats.totalWordsTranscribed += transcriptionWordCount(of: modifiedResult)
      }
      state.isAIProcessing = true
      let isPro = state.hexSettings.selectedPlan == "pro"
      return .run { [aiProcessing, inlineEdit, pasteboard, keychain, transcriptPersistence] send in
        if !isPro {
          let keychainKey = aiProvider == .openAI ? KeychainKey.openAIAPIKey : KeychainKey.anthropicAPIKey
          guard let apiKey = await keychain.read(keychainKey), !apiKey.isEmpty else {
            transcriptionFeatureLogger.warning("Inline edit: no \(aiProvider.displayName) API key — cannot process")
            await send(.aiProcessingFinished)
            await send(.editModeNeedsAPIKey)
            try? FileManager.default.removeItem(at: audioURL)
            return
          }
        }

        let userMessage = InlineEditPrompt.userMessage(
          instruction: modifiedResult,
          selection: selection
        )
        do {
          let edited = try await aiProcessing.process(
            userMessage,
            .clean,
            aiProvider,
            nil,
            InlineEditPrompt.systemPrompt,
            true
          )
          await send(.aiProcessingFinished)

          let replaced = await inlineEdit.replaceSelection(edited)
          if !replaced {
            transcriptionFeatureLogger.warning("Inline edit: AX replace failed; falling back to paste")
            await pasteboard.paste(edited, sourceAppBundleID)
          }
          await send(.inlineEditApplied(PendingEditResult(
            original: selection,
            edited: edited,
            sourceAppBundleID: sourceAppBundleID
          )))
          soundEffect.play(.pasteTranscript)
          try? await storeTranscriptInHistory(
            text: modifiedResult, audioURL: audioURL, duration: duration,
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            mode: .edit, transcriptionHistory: transcriptionHistory
          )
        } catch {
          // Fix C: surface the failure visibly
          transcriptionFeatureLogger.error("Inline edit AI failed: \(error.localizedDescription)")
          await send(.aiProcessingFinished)
          await send(.editModeAIFailed(modifiedResult))
          try? FileManager.default.removeItem(at: audioURL)
        }
      }
      .cancellable(id: CancelID.transcription)
    }

    // ── Branch 2: Edit mode with no selection (no-selection fallback) ──
    // User is in explicit Edit mode (not Auto) but no text was selected.
    // Treat the dictation as a standalone AI instruction.
    if effectiveMode == .edit && inlineEditSelection == nil && !modifiedResult.isEmpty {
      state.$usageStats.withLock { stats in
        stats.editCount += 1
        stats.totalWordsTranscribed += transcriptionWordCount(of: modifiedResult)
      }
      state.isAIProcessing = true
      let isPro2 = state.hexSettings.selectedPlan == "pro"
      return .run { [aiProcessing, pasteboard, keychain] send in
        if !isPro2 {
          let keychainKey = aiProvider == .openAI ? KeychainKey.openAIAPIKey : KeychainKey.anthropicAPIKey
          guard let apiKey = await keychain.read(keychainKey), !apiKey.isEmpty else {
            transcriptionFeatureLogger.warning("Edit mode (no selection): no \(aiProvider.displayName) API key")
            await send(.aiProcessingFinished)
            await send(.editModeNeedsAPIKey)
            try? FileManager.default.removeItem(at: audioURL)
            return
          }
        }

        do {
          let generated = try await aiProcessing.process(
            modifiedResult,
            .clean,
            aiProvider,
            nil,
            InlineEditPrompt.noSelectionSystemPrompt,
            true
          )
          transcriptionFeatureLogger.info("Edit mode (no selection): AI generated \(generated.count) chars")
          await send(.aiProcessingFinished)
          await pasteboard.paste(generated, sourceAppBundleID)
          soundEffect.play(.pasteTranscript)
          try? await storeTranscriptInHistory(
            text: modifiedResult, audioURL: audioURL, duration: duration,
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            mode: .edit, transcriptionHistory: transcriptionHistory
          )
        } catch {
          transcriptionFeatureLogger.error("Edit mode (no selection) AI failed: \(error.localizedDescription)")
          await send(.aiProcessingFinished)
          await send(.editModeAIFailed(modifiedResult))
          try? FileManager.default.removeItem(at: audioURL)
        }
      }
      .cancellable(id: CancelID.transcription)
    }

    // ── Branch 3: Action mode ──
    // Parse the voice command into a structured action intent via the
    // LLM, then surface the confirmation panel.
    if effectiveMode == .action && !modifiedResult.isEmpty {
      state.$usageStats.withLock { stats in
        stats.actionCount += 1
        stats.totalWordsTranscribed += transcriptionWordCount(of: modifiedResult)
      }
      state.isAIProcessing = true
      state.lastActionTranscript = modifiedResult
      let agentName = state.hexSettings.agentName
      let memoryEnabled = state.hexSettings.agentMemoryEnabled
      // Selected-text context captured at stop time (AX-only in Action
      // mode) — lets "add this to my Kearney list" resolve "this".
      let selectionContext = state.inlineEditSelection
      return .run { [actionParsing] send in
        // Routine authoring: "new routine: when I say ship it, …" parses the
        // description into a trigger + steps and persists it.
        if let routineDescription = RoutineMatcher.authoringRequest(transcript: modifiedResult, agentName: agentName) {
          do {
            let draft = try await actionParsing.parseRoutine(routineDescription, aiProvider)
            await RoutineStore.shared.add(
              Routine(name: draft.name, triggerPhrases: [draft.triggerPhrase], steps: draft.actions)
            )
            transcriptionFeatureLogger.info("Routine saved: trigger=\(draft.triggerPhrase, privacy: .private) steps=\(draft.actions.count, privacy: .public)")
            await send(.aiProcessingFinished)
            await send(.routineSaved(draft))
            try? await storeTranscriptInHistory(
              text: modifiedResult, audioURL: audioURL, duration: duration,
              sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
              mode: .action, transcriptionHistory: transcriptionHistory
            )
          } catch {
            transcriptionFeatureLogger.error("Routine authoring failed: \(error.localizedDescription)")
            await send(.aiProcessingFinished)
            if let actionError = error as? ActionParsingError, case .missingAPIKey = actionError {
              await send(.actionModeNeedsAPIKey)
            } else {
              await send(.actionParsingFailed(modifiedResult))
            }
            try? FileManager.default.removeItem(at: audioURL)
          }
          return
        }

        // Routine trigger fast-path: a saved phrase match skips the LLM
        // entirely — instant, free, works offline.
        let routines = await RoutineStore.shared.loadAll()
        if let routine = RoutineMatcher.match(transcript: modifiedResult, routines: routines) {
          transcriptionFeatureLogger.info("Routine triggered: \(routine.name, privacy: .private)")
          await RoutineStore.shared.recordRun(id: routine.id)
          await send(.aiProcessingFinished)
          await send(.routineTriggered(routine))
          try? await storeTranscriptInHistory(
            text: modifiedResult, audioURL: audioURL, duration: duration,
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            mode: .action, transcriptionHistory: transcriptionHistory
          )
          return
        }

        do {
          let response = try await actionParsing.parseMulti(modifiedResult, aiProvider, selectionContext)
          await send(.aiProcessingFinished)
          // MCP + open actions always go through the multi-action panel — the
          // single-action panel's per-integration editors don't apply.
          if response.isSingleAction, let intent = response.actions.first,
             intent.actionType != .mcpCall, intent.actionType != .open {
            await send(.actionIntentParsed(intent))
          } else {
            await send(.multiActionIntentsParsed(response.actions))
          }
          // Background memory pass: fire-and-forget so it never delays the
          // confirmation panel and survives the next recording cancelling
          // this effect.
          if memoryEnabled {
            Task {
              if let candidates = try? await actionParsing.extractMemory(modifiedResult, aiProvider),
                 !candidates.isEmpty {
                await MemoryStore.shared.upsert(candidates)
                transcriptionFeatureLogger.info("Agent memory: merged \(candidates.count, privacy: .public) candidate(s)")
              }
            }
          }
          try? await storeTranscriptInHistory(
            text: modifiedResult, audioURL: audioURL, duration: duration,
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            mode: .action, transcriptionHistory: transcriptionHistory
          )
        } catch {
          transcriptionFeatureLogger.error("Action parsing failed: \(error.localizedDescription)")
          await send(.aiProcessingFinished)
          // Fix B: distinguish missing API key from other failures
          if let actionError = error as? ActionParsingError,
             case .missingAPIKey = actionError {
            await send(.actionModeNeedsAPIKey)
          } else if QueueableErrorClassifier.isQueueable(error) {
            await ActionQueueManager.shared.enqueueTranscript(
              modifiedResult,
              provider: aiProvider,
              lastError: error.localizedDescription
            )
            await send(.actionParsingQueued)
          } else {
            await send(.actionParsingFailed(modifiedResult))
          }
          try? FileManager.default.removeItem(at: audioURL)
        }
      }
      .cancellable(id: CancelID.transcription)
    }

    // ── Branch 4: Dictate mode (default) ──
    state.$usageStats.withLock { stats in
      stats.dictationCount += 1
      stats.totalWordsTranscribed += transcriptionWordCount(of: modifiedResult)
    }
    return .run { [aiProcessing] send in
      do {
        var finalResult = modifiedResult
        if aiEnabled {
          do {
            finalResult = try await aiProcessing.process(modifiedResult, resolvedMode, aiProvider, capturedContext, nil, false)
            transcriptionFeatureLogger.info("AI processing produced \(finalResult.count) chars from \(modifiedResult.count) chars")
          } catch {
            transcriptionFeatureLogger.error("AI processing failed, using unprocessed text: \(error.localizedDescription)")
          }
          await send(.aiProcessingFinished)
        }

        try await finalizeRecordingAndStoreTranscript(
          result: finalResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          mode: .dictate,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.transcriptionError(error, audioURL, sessionID: sessionID))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  /// Resolves the AI mode based on context-aware rules or manual selection.
  func resolveAIMode(state: State) -> AIProcessingMode {
    if let autoMode = AppModeResolver.resolve(
      bundleID: state.sourceAppBundleID,
      customRules: state.hexSettings.appModeRules,
      contextAwareEnabled: state.hexSettings.contextAwareAutoMode
    ) {
      return autoMode
    }
    return state.hexSettings.aiProcessingMode
  }

  /// Executes a voice command via keyboard simulation instead of pasting text.
  /// Punctuation cases (period, comma, etc.) are unreachable as of 0.8.x —
  /// `VoiceCommandSubstituter` handles those inline now; only editor
  /// commands (undo, redo, selectAll, newLine, newParagraph) reach this
  /// path via `VoiceCommand.editorCommands` filtering. Kept for safety.
  func executeVoiceCommand(
    _ command: VoiceCommand,
    audioURL: URL,
    sourceAppBundleID: String?
  ) -> Effect<Action> {
    .run { [pasteboard, soundEffect] _ in
      try? FileManager.default.removeItem(at: audioURL)

      switch command {
      case .newParagraph:
        await pasteboard.sendKeyboardCommand(.enter)
        try? await Task.sleep(for: .milliseconds(50))
        await pasteboard.sendKeyboardCommand(.enter)
      case .newLine:
        await pasteboard.sendKeyboardCommand(.enter)
      case .selectAll:
        await pasteboard.sendKeyboardCommand(.init(key: .a, modifiers: [.command]))
      case .undo:
        await pasteboard.sendKeyboardCommand(.init(key: .z, modifiers: [.command]))
      case .redo:
        await pasteboard.sendKeyboardCommand(.init(key: .z, modifiers: [.command, .shift]))
      case .period:
        await pasteboard.paste(".", sourceAppBundleID)
      case .comma:
        await pasteboard.paste(",", sourceAppBundleID)
      case .questionMark:
        await pasteboard.paste("?", sourceAppBundleID)
      case .exclamationMark:
        await pasteboard.paste("!", sourceAppBundleID)
      }

      soundEffect.play(.pasteTranscript)
    }
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }

    return .none
  }

  /// Save transcript to history, handling max-entries pruning and cloud sync.
  /// Used by all branches — edit, action, and dictate.
  func storeTranscriptInHistory(
    text: String,
    audioURL: URL,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    mode: TranscriptionMode?,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        text,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName,
        mode
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      try? FileManager.default.removeItem(at: audioURL)
    }

    if hexSettings.cloudSyncEnabled {
      let transcript = Transcript(
        timestamp: Date(),
        text: text,
        audioPath: audioURL,
        duration: duration,
        sourceAppBundleID: sourceAppBundleID,
        sourceAppName: sourceAppName,
        mode: mode
      )
      Task { @MainActor in
        await MacCloudSync.shared.uploadTranscript(transcript)
      }
    }

    Task { @MainActor in
      AnalyticsUploader.shared.scheduleUpload()
    }
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    mode: TranscriptionMode?,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    try await storeTranscriptInHistory(
      text: result,
      audioURL: audioURL,
      duration: duration,
      sourceAppBundleID: sourceAppBundleID,
      sourceAppName: sourceAppName,
      mode: mode,
      transcriptionHistory: transcriptionHistory
    )

    await pasteboard.paste(result, sourceAppBundleID)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isAIProcessing = false
    state.partialTranscript = ""

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.liveTranscription),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        // Stop the recording to release microphone access
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        try? FileManager.default.removeItem(at: url)
        soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false

    // Silently discard - no sound effect
    return .run { [sleepManagement] _ in
      // Allow system to sleep again
      await sleepManagement.allowSleep()
      let url = await recording.stopRecording()
      guard !Task.isCancelled else { return }
      try? FileManager.default.removeItem(at: url)
    }
    .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isAIProcessing {
      return .aiProcessing
    } else if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else {
      return .idle
    }
  }

  private var hotkeyHint: String {
    let hotkey = store.hexSettings.hotkey
    var parts: [String] = []
    if hotkey.modifiers.isHyperkey {
      parts.append("Hyper")
    } else {
      for mod in hotkey.modifiers.sorted {
        parts.append(mod.kind.symbol)
      }
    }
    if let key = hotkey.key {
      switch key {
      case .space: parts.append("Space")
      case .escape: parts.append("Esc")
      default: parts.append(key.toString)
      }
    }
    let keys = parts.joined(separator: " ")
    let verb: String = switch store.selectedMode {
    case .auto: "to start"
    case .dictate: "to dictate"
    case .edit: "to edit"
    case .action: "for action"
    }
    return "Hold \(keys) \(verb)"
  }

  var body: some View {
    Group {
      if store.hexSettings.displayMode == .chip {
        // Chip mode lives in the menu bar (QuillStatusItemController owns
        // the NSStatusItem chip + Corner Bloom panel). The HUD panel shows
        // nothing — but this view must stay alive: its `.task` below runs
        // the feature's long-lived effects (hotkeys, meters).
        Color.clear.frame(width: 1, height: 1)
      } else if store.hexSettings.displayMode == .orb {
        OrbView(
          status: status,
          mode: store.selectedMode,
          meter: store.meter,
          recordingStartTime: store.recordingStartTime,
          hotkeyHint: hotkeyHint,
          editMessage: store.editNeedsSelectionMessage,
          pendingEditResult: store.pendingEditResult,
          partialTranscript: store.partialTranscript,
          actionIntegrations: store.availableActionIntegrations,
          mcpServerNames: store.hexSettings.mcpServers.filter(\.isEnabled).map(\.name),
          lockedActionIntegration: store.lockedActionIntegration,
          autoDetectedMode: store.autoDetectedMode,
          isPinnedToTop: store.hexSettings.hudPinnedToTop,
          onCycleMode: { store.send(.cycleMode) },
          onEditAccept: { store.send(.inlineEditAccept) },
          onEditUndo: { store.send(.inlineEditUndo) },
          onToggleActionIntegration: { id in store.send(.toggleActionIntegrationLock(id)) }
        )
      } else {
        TranscriptionIndicatorView(
          status: status,
          mode: store.selectedMode,
          meter: store.meter,
          recordingStartTime: store.recordingStartTime,
          hotkeyHint: hotkeyHint,
          editMessage: store.editNeedsSelectionMessage,
          pendingEditResult: store.pendingEditResult,
          partialTranscript: store.partialTranscript,
          actionIntegrations: store.availableActionIntegrations,
          lockedActionIntegration: store.lockedActionIntegration,
          autoDetectedMode: store.autoDetectedMode,
          isPinnedToTop: store.hexSettings.hudPinnedToTop,
          onCycleMode: { store.send(.cycleMode) },
          onEditAccept: { store.send(.inlineEditAccept) },
          onEditUndo: { store.send(.inlineEditUndo) },
          onToggleActionIntegration: { id in store.send(.toggleActionIntegrationLock(id)) }
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.hexSettings.hudPinnedToTop ? .top : .center)
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

// MARK: - AutoModeClassifier bridging

extension TranscriptionMode {
  /// Maps the HexCore classifier's portable mode onto the macOS HUD's
  /// mode enum (which additionally has `.auto`).
  var indicatorMode: TranscriptionIndicatorView.Mode {
    switch self {
    case .dictate: .dictate
    case .edit: .edit
    case .action: .action
    }
  }
}
