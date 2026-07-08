import AVFoundation
import AppKit
import ComposableArchitecture
import CoreAudio
import Dependencies
import HexCore
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private let settingsLogger = HexLog.settings
private typealias SettingsAudioPropertyListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

private enum HotKeyCaptureTarget {
  case recording
  case pasteLastTranscript
  case cycleMode
}

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }

  static var isSettingPasteLastTranscriptHotkey: Self {
    Self[.inMemory("isSettingPasteLastTranscriptHotkey"), default: false]
  }

  static var isSettingCycleModeHotkey: Self {
    Self[.inMemory("isSettingCycleModeHotkey"), default: false]
  }

  static var isRemappingScratchpadFocused: Self {
    Self[.inMemory("isRemappingScratchpadFocused"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool = false
    @Shared(.isSettingCycleModeHotkey) var isSettingCycleModeHotkey: Bool = false
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.hotkeyPermissionState) var hotkeyPermissionState: HotkeyPermissionState

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    var currentPasteLastModifiers: Modifiers = .init(modifiers: [])
    var currentCycleModeModifiers: Modifiers = .init(modifiers: [])
    var remappingScratchpadText: String = ""
    
    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []
    var defaultInputDeviceName: String?

    // Model Management
    var modelDownload = ModelDownloadFeature.State()
    var shouldFlashModelSection = false

    // AI Processing
    var loadedAPIKey: String = ""
    var apiKeySaved: Bool = false
    /// Result of the last API key validation ping: nil = not yet checked,
    /// true = key works, false = key is invalid (401/403).
    var apiKeyValid: Bool?

    /// Guards `.task` so the long-running effect (key-event listener,
    /// device monitoring, model fetch, API key load) only runs once —
    /// not on every tab switch.
    var hasRunTask: Bool = false
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case startSettingPasteLastTranscriptHotkey
    case clearPasteLastTranscriptHotkey
    case startSettingCycleModeHotkey
    case clearCycleModeHotkey
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case toggleShowDockIcon(Bool)
    case toggleHudPinnedToTop(Bool)
    case setDisplayMode(DisplayMode)
    case togglePreventSystemSleep(Bool)
    case setRecordingAudioBehavior(RecordingAudioBehavior)
    case toggleSuperFastMode(Bool)
    case setUseClipboardPaste(Bool)
    case setCopyToClipboard(Bool)
    case addAppPasteDelay
    case updateAppPasteDelay(AppPasteDelay)
    case removeAppPasteDelay(UUID)
    case setDoubleTapLockEnabled(Bool)
    case setUseDoubleTapOnly(Bool)
    case setMinimumKeyTime(Double)
    case setOutputLanguage(String?)
    case setSelectedMicrophoneID(String?)
    case setSoundEffectsEnabled(Bool)
    case setSoundEffectsVolume(Double)

    // Permission delegation (forwarded to AppFeature)
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring

    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice], String?)

    // Model Management
    case modelDownload(ModelDownloadFeature.Action)
    
    // History Management
    case toggleSaveTranscriptionHistory(Bool)
    case setMaxHistoryEntries(Int?)

    // Modifier configuration
    case setModifierSide(Modifier.Kind, Modifier.Side)

    // Word remappings
    case setWordRemovalsEnabled(Bool)
    case addWordRemoval
    case updateWordRemoval(WordRemoval)
    case removeWordRemoval(UUID)
    case addWordRemapping
    case updateWordRemapping(WordRemapping)
    case removeWordRemapping(UUID)
    case setRemappingScratchpadFocused(Bool)

    // AI Processing
    case setAIProcessingEnabled(Bool)
    case setAIProcessingMode(AIProcessingMode)
    case setAIProvider(AIProvider)
    case setContextAwareAutoMode(Bool)
    case setVoiceCommandsEnabled(Bool)
    case addAppModeRule
    case updateAppModeRule(AppModeRule)
    case removeAppModeRule(UUID)
    case saveAPIKey(String, forProvider: AIProvider)
    case loadAPIKey(AIProvider)
    case apiKeyLoaded(String)
    case apiKeyValidated(Bool)
    case setContextEnrichmentEnabled(Bool)
    case setLiveTranscriptEnabled(Bool)
    case setInlineEditEnabled(Bool)
    case addCustomAIMode(CustomAIMode)
    case updateCustomAIMode(CustomAIMode)
    case removeCustomAIMode(UUID)
    /// Fired by the onboarding flow when the user finishes (or skips
    /// through to) the last step. Persists `hasCompletedOnboarding`
    /// so we don't re-present the welcome tour.
    case markOnboardingComplete
    /// Reset `hasCompletedOnboarding` so the welcome tour appears
    /// again on the next launch / window open. Triggered by the
    /// "Replay Tutorial" entry in Settings → General.
    case replayOnboarding

    /// Reset all settings to factory defaults. Preserves API keys
    /// in the Keychain and the onboarding-complete flag.
    case resetToDefaults
    /// Export current settings to a user-chosen JSON file.
    case exportSettings
    /// Import settings from a user-chosen JSON file.
    case importSettings

    // Plan
    case setSelectedPlan(String?)

    // Cloud Sync
    case setCloudSyncEnabled(Bool)
    case syncNow
    case syncCompleted(notesDown: Int, transcriptsUp: Int)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.permissions) var permissions
  @Dependency(\.soundEffects) var soundEffects
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.keychain) var keychain

  private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
    .run { [transcriptPersistence] _ in
      for transcript in transcripts {
        try? await transcriptPersistence.deleteAudio(transcript)
      }
    }
  }

  private func beginCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = true }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = true }
      state.currentPasteLastModifiers = .init(modifiers: [])
    case .cycleMode:
      state.$isSettingCycleModeHotkey.withLock { $0 = true }
      state.currentCycleModeModifiers = .init(modifiers: [])
    }
  }

  private func endCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = false }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = false }
      state.currentPasteLastModifiers = .init(modifiers: [])
    case .cycleMode:
      state.$isSettingCycleModeHotkey.withLock { $0 = false }
      state.currentCycleModeModifiers = .init(modifiers: [])
    }
  }

  private func captureModifiers(for target: HotKeyCaptureTarget, state: State) -> Modifiers {
    switch target {
    case .recording:
      state.currentModifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers
    case .cycleMode:
      state.currentCycleModeModifiers
    }
  }

  private func updateCaptureModifiers(_ modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.currentModifiers = modifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers = modifiers
    case .cycleMode:
      state.currentCycleModeModifiers = modifiers
    }
  }

  private func applyCapturedHotKey(key: Key?, modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$hexSettings.withLock {
        $0.hotkey.key = key
        $0.hotkey.modifiers = modifiers.erasingSides()
      }
    case .pasteLastTranscript:
      guard let key else { return }
      state.$hexSettings.withLock {
        $0.pasteLastTranscriptHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    case .cycleMode:
      guard let key else { return }
      state.$hexSettings.withLock {
        $0.cycleModeHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    }
  }

  private func handleCapture(_ keyEvent: KeyEvent, for target: HotKeyCaptureTarget, state: inout State) -> Effect<Action> {
    if keyEvent.key == .escape {
      endCapture(target, state: &state)
      return .none
    }

    let updatedModifiers = keyEvent.modifiers.union(captureModifiers(for: target, state: state))
    updateCaptureModifiers(updatedModifiers, for: target, state: &state)

    if (target == .pasteLastTranscript || target == .cycleMode), keyEvent.key != nil, updatedModifiers.isEmpty {
      return .none
    }

    if let key = keyEvent.key {
      applyCapturedHotKey(key: key, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
      return .none
    }

    if target == .recording, keyEvent.modifiers.isEmpty {
      applyCapturedHotKey(key: nil, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
    }

    return .none
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        let didNormalizeDoubleTapOnly = !state.hexSettings.doubleTapLockEnabled && state.hexSettings.useDoubleTapOnly
        if didNormalizeDoubleTapOnly {
          state.$hexSettings.withLock {
            $0.useDoubleTapOnly = false
          }
        }

        return .none

      case .task:
        guard !state.hasRunTask else { return .none }
        state.hasRunTask = true

        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          settingsLogger.error("Failed to load languages JSON from bundle")
        }

        // Eagerly load the API key so the Status overview can show the
        // right state without a separate keychain hit on the AI tab.
        let provider = state.hexSettings.aiProvider

        // Listen for key events and load microphones (existing + new)
        return .run { send in
          // Load API key once at startup so switching tabs doesn't re-prompt.
          await send(.loadAPIKey(provider))
          func audioPropertyAddress(
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
          ) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
              mSelector: selector,
              mScope: scope,
              mElement: element
            )
          }

          await send(.modelDownload(.fetchModels))
          await send(.loadAvailableInputDevices)

          // Set up periodic refresh of available devices (every 120 seconds)
          // Using a longer interval to reduce resource usage
          let deviceRefreshTask = Task { @MainActor in
            for await _ in clock.timer(interval: .seconds(120)) {
              // Only refresh when the app is active to save resources
              if NSApplication.shared.isActive {
                await send(.loadAvailableInputDevices)
              }
            }
          }

          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          var audioHardwareObservers: [(AudioObjectPropertySelector, SettingsAudioPropertyListenerBlock)] = []

          // Helper function to debounce device updates
          func debounceDeviceUpdate() {
            deviceUpdateTask?.cancel()
            deviceUpdateTask = Task {
              try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
              if !Task.isCancelled {
                await send(.loadAvailableInputDevices)
              }
            }
          }

          func installAudioHardwareObserver(_ selector: AudioObjectPropertySelector) {
            let listener: SettingsAudioPropertyListenerBlock = { _, _ in
              debounceDeviceUpdate()
            }
            var address = audioPropertyAddress(selector)
            let status = AudioObjectAddPropertyListenerBlock(
              AudioObjectID(kAudioObjectSystemObject),
              &address,
              DispatchQueue.main,
              listener
            )

            if status == noErr {
              audioHardwareObservers.append((selector, listener))
            } else {
              settingsLogger.error("Failed to observe audio hardware selector \(selector): \(status)")
            }
          }

          let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          let deviceDisconnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          let appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          installAudioHardwareObserver(kAudioHardwarePropertyDefaultInputDevice)
          installAudioHardwareObserver(kAudioHardwarePropertyDevices)

          // Be sure to clean up resources when the task is finished
          defer {
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)

            for (selector, listener) in audioHardwareObservers {
              var address = audioPropertyAddress(selector)
              let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
              )
              if status != noErr {
                settingsLogger.error("Failed to remove audio hardware observer for selector \(selector): \(status)")
              }
            }
          }

          for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
            await send(.keyEvent(keyEvent))
          }
          
          deviceRefreshTask.cancel()
        }

      case .startSettingHotKey:
        beginCapture(.recording, state: &state)
        return .none

      case .addWordRemoval:
        state.$hexSettings.withLock {
          $0.wordRemovals.append(.init(pattern: ""))
        }
        return .none

      case let .updateWordRemoval(removal):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemovals.firstIndex(where: { $0.id == removal.id }) else { return }
          $0.wordRemovals[index] = removal
        }
        return .none

      case let .removeWordRemoval(id):
        state.$hexSettings.withLock {
          $0.wordRemovals.removeAll { $0.id == id }
        }
        return .none

      case .addWordRemapping:
        state.$hexSettings.withLock {
          $0.wordRemappings.append(.init(match: "", replacement: ""))
        }
        return .none

      case let .updateWordRemapping(remapping):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemappings.firstIndex(where: { $0.id == remapping.id }) else { return }
          $0.wordRemappings[index] = remapping
        }
        return .none

      case let .removeWordRemapping(id):
        state.$hexSettings.withLock {
          $0.wordRemappings.removeAll { $0.id == id }
        }
        return .none

      case let .setRemappingScratchpadFocused(isFocused):
        state.$isRemappingScratchpadFocused.withLock { $0 = isFocused }
        return .none

      case .startSettingPasteLastTranscriptHotkey:
        beginCapture(.pasteLastTranscript, state: &state)
        return .none

      case .clearPasteLastTranscriptHotkey:
        state.$hexSettings.withLock { $0.pasteLastTranscriptHotkey = nil }
        return .none

      case .startSettingCycleModeHotkey:
        beginCapture(.cycleMode, state: &state)
        return .none

      case .clearCycleModeHotkey:
        state.$hexSettings.withLock { $0.cycleModeHotkey = nil }
        return .none

      case let .keyEvent(keyEvent):
        if state.isSettingPasteLastTranscriptHotkey {
          return handleCapture(keyEvent, for: .pasteLastTranscript, state: &state)
        }

        if state.isSettingCycleModeHotkey {
          return handleCapture(keyEvent, for: .cycleMode, state: &state)
        }

        guard state.isSettingHotKey else { return .none }
        return handleCapture(keyEvent, for: .recording, state: &state)

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .toggleShowDockIcon(enabled):
        state.$hexSettings.withLock { $0.showDockIcon = enabled }
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: .updateAppMode, object: nil)
          }
        }

      case let .toggleHudPinnedToTop(pinned):
        state.$hexSettings.withLock { $0.hudPinnedToTop = pinned }
        return .run { [pinned] _ in
          await MainActor.run {
            NotificationCenter.default.post(
              name: .hudPositionModeChanged,
              object: nil,
              userInfo: ["pinned": pinned]
            )
          }
        }

      case let .setDisplayMode(mode):
        state.$hexSettings.withLock { $0.displayMode = mode }
        // The menu-bar status item (chip vs static feather) is AppKit-
        // managed and can't observe @Shared — nudge it.
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: .displayModeChanged, object: nil)
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .setUseClipboardPaste(enabled):
        state.$hexSettings.withLock { $0.useClipboardPaste = enabled }
        return .none

      case let .setCopyToClipboard(enabled):
        state.$hexSettings.withLock { $0.copyToClipboard = enabled }
        return .none

      case .addAppPasteDelay:
        state.$hexSettings.withLock {
          $0.appPasteDelays.append(.init(bundleIdentifier: "", appName: "", delayMs: 300))
        }
        return .none

      case let .updateAppPasteDelay(rule):
        state.$hexSettings.withLock {
          if let idx = $0.appPasteDelays.firstIndex(where: { $0.id == rule.id }) {
            $0.appPasteDelays[idx] = rule
          }
        }
        return .none

      case let .removeAppPasteDelay(id):
        state.$hexSettings.withLock {
          $0.appPasteDelays.removeAll { $0.id == id }
        }
        return .none

      case let .setRecordingAudioBehavior(behavior):
        state.$hexSettings.withLock { $0.recordingAudioBehavior = behavior }
        return .none

      case let .toggleSuperFastMode(enabled):
        state.$hexSettings.withLock { $0.superFastModeEnabled = enabled }
        return .run { _ in
          await recording.warmUpRecorder()
        }

      case let .setDoubleTapLockEnabled(enabled):
        state.$hexSettings.withLock {
          $0.doubleTapLockEnabled = enabled
          if !enabled {
            $0.useDoubleTapOnly = false
          }
        }
        return .none

      case let .setUseDoubleTapOnly(enabled):
        state.$hexSettings.withLock {
          $0.useDoubleTapOnly = enabled && $0.doubleTapLockEnabled
        }
        return .none

      case let .setMinimumKeyTime(value):
        state.$hexSettings.withLock { $0.minimumKeyTime = value }
        return .none

      case let .setOutputLanguage(language):
        state.$hexSettings.withLock { $0.outputLanguage = language }
        return .none

      case let .setSelectedMicrophoneID(deviceID):
        state.$hexSettings.withLock { $0.selectedMicrophoneID = deviceID }
        return .none

      case let .setSoundEffectsEnabled(enabled):
        state.$hexSettings.withLock { $0.soundEffectsEnabled = enabled }
        return .run { _ in
          await soundEffects.setEnabled(enabled)
        }

      case let .setSoundEffectsVolume(volume):
        state.$hexSettings.withLock { $0.soundEffectsVolume = volume }
        return .none

      // Permission requests
      case .requestMicrophone:
        settingsLogger.info("User requested microphone permission from settings")
        return .run { _ in
          _ = await permissions.requestMicrophone()
        }

      case .requestAccessibility:
        settingsLogger.info("User requested accessibility permission from settings")
        return .run { _ in
          await permissions.requestAccessibility()
        }

      case .requestInputMonitoring:
        settingsLogger.info("User requested input monitoring permission from settings")
        return .run { _ in
          _ = await permissions.requestInputMonitoring()
        }

      // Model Management
      case let .modelDownload(.selectModel(newModel)):
        // Also store it in hexSettings:
        state.$hexSettings.withLock {
          $0.selectedModel = newModel
        }
        // Then continue with the child's normal logic:
        return .none

      case .modelDownload:
        return .none
      
      // Microphone device selection
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          let defaultName = await recording.getDefaultInputDeviceName()
          await send(.availableInputDevicesLoaded(devices, defaultName))
        }
        
      case let .availableInputDevicesLoaded(devices, defaultName):
        state.availableInputDevices = devices
        state.defaultInputDeviceName = defaultName
        return .none
        
      case let .toggleSaveTranscriptionHistory(enabled):
        state.$hexSettings.withLock { $0.saveTranscriptionHistory = enabled }
        
        // If disabling history, delete all existing entries
        if !enabled {
          let transcripts = state.transcriptionHistory.history
          
          // Clear the history
          state.$transcriptionHistory.withLock { history in
            history.history.removeAll()
          }

          return deleteAudioEffect(for: transcripts)
        }
        
        return .none

      case let .setMaxHistoryEntries(maxHistoryEntries):
        state.$hexSettings.withLock { $0.maxHistoryEntries = maxHistoryEntries }
        return .none

      case let .setModifierSide(kind, side):
        guard state.hexSettings.hotkey.key == nil else { return .none }
        state.$hexSettings.withLock {
          $0.hotkey.modifiers = $0.hotkey.modifiers.setting(kind: kind, to: side)
        }
        return .none

      case let .setWordRemovalsEnabled(enabled):
        state.$hexSettings.withLock { $0.wordRemovalsEnabled = enabled }
        return .none

      // AI Processing
      case let .setAIProcessingEnabled(enabled):
        state.$hexSettings.withLock { $0.aiProcessingEnabled = enabled }
        return .none

      case let .setAIProcessingMode(mode):
        state.$hexSettings.withLock { $0.aiProcessingMode = mode }
        return .none

      case let .setAIProvider(provider):
        state.$hexSettings.withLock { $0.aiProvider = provider }
        return .none

      case let .setContextAwareAutoMode(enabled):
        state.$hexSettings.withLock { $0.contextAwareAutoMode = enabled }
        return .none

      case let .setVoiceCommandsEnabled(enabled):
        state.$hexSettings.withLock { $0.voiceCommandsEnabled = enabled }
        return .none

      case .addAppModeRule:
        state.$hexSettings.withLock {
          $0.appModeRules.append(.init(bundleIdentifier: "", appName: "", mode: .clean))
        }
        return .none

      case let .updateAppModeRule(rule):
        state.$hexSettings.withLock {
          guard let index = $0.appModeRules.firstIndex(where: { $0.id == rule.id }) else { return }
          $0.appModeRules[index] = rule
        }
        return .none

      case let .removeAppModeRule(id):
        state.$hexSettings.withLock {
          $0.appModeRules.removeAll { $0.id == id }
        }
        return .none

      case let .saveAPIKey(key, forProvider: provider):
        state.apiKeySaved = false
        state.apiKeyValid = nil
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return .run { [keychain] send in
          let keychainKey: String
          switch provider {
          case .openAI: keychainKey = KeychainKey.openAIAPIKey
          case .anthropic: keychainKey = KeychainKey.anthropicAPIKey
          }
          if trimmed.isEmpty {
            await keychain.delete(keychainKey)
          } else {
            try? await keychain.save(keychainKey, trimmed)
          }
          // Reload to confirm it saved
          let saved = await keychain.read(keychainKey)
          await send(.apiKeyLoaded(saved ?? ""))

          // Validate the key with a lightweight API ping
          if !trimmed.isEmpty {
            let valid = await validateAPIKey(trimmed, provider: provider)
            await send(.apiKeyValidated(valid))
          }
        }

      case let .loadAPIKey(provider):
        return .run { [keychain] send in
          let keychainKey: String
          switch provider {
          case .openAI: keychainKey = KeychainKey.openAIAPIKey
          case .anthropic: keychainKey = KeychainKey.anthropicAPIKey
          }
          let value = await keychain.read(keychainKey) ?? ""
          await send(.apiKeyLoaded(value))

          // Validate the existing key on load
          if !value.isEmpty {
            let valid = await validateAPIKey(value, provider: provider)
            await send(.apiKeyValidated(valid))
          }
        }

      case let .apiKeyLoaded(key):
        state.loadedAPIKey = key
        state.apiKeySaved = !key.isEmpty
        return .none

      case let .apiKeyValidated(valid):
        state.apiKeyValid = valid
        return .none

      case let .setContextEnrichmentEnabled(enabled):
        state.$hexSettings.withLock { $0.contextEnrichmentEnabled = enabled }
        return .none

      case let .setLiveTranscriptEnabled(enabled):
        state.$hexSettings.withLock { $0.liveTranscriptEnabled = enabled }
        return .none

      case let .setInlineEditEnabled(enabled):
        state.$hexSettings.withLock { $0.inlineEditEnabled = enabled }
        return .none

      case let .addCustomAIMode(mode):
        state.$hexSettings.withLock { $0.customAIModes.append(mode) }
        return .none

      case let .updateCustomAIMode(mode):
        state.$hexSettings.withLock {
          guard let idx = $0.customAIModes.firstIndex(where: { $0.id == mode.id }) else { return }
          $0.customAIModes[idx] = mode
        }
        return .none

      case let .removeCustomAIMode(id):
        state.$hexSettings.withLock {
          $0.customAIModes.removeAll { $0.id == id }
        }
        return .none

      case .markOnboardingComplete:
        state.$hexSettings.withLock { $0.hasCompletedOnboarding = true }
        return .none

      case .replayOnboarding:
        state.$hexSettings.withLock { $0.hasCompletedOnboarding = false }
        return .none

      case .resetToDefaults:
        let preserveOnboarding = state.hexSettings.hasCompletedOnboarding
        state.$hexSettings.withLock { settings in
          let fresh = HexSettings()
          // Preserve onboarding flag so user doesn't see the tutorial again
          settings = fresh
          settings.hasCompletedOnboarding = preserveOnboarding
        }
        return .none

      case .exportSettings:
        return .run { [settings = state.hexSettings] _ in
          await MainActor.run {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "quill-settings.json"
            panel.title = "Export Settings"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
              let encoder = JSONEncoder()
              encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
              let data = try encoder.encode(settings)
              try data.write(to: url)
            } catch {
              HexLog.settings.error("Failed to export settings: \(error.localizedDescription)")
            }
          }
        }

      case .importSettings:
        return .run { send in
          await MainActor.run {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            panel.title = "Import Settings"
            panel.message = "Choose a Quill settings file to import"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
              let data = try Data(contentsOf: url)
              var imported = try JSONDecoder().decode(HexSettings.self, from: data)
              // Preserve onboarding flag
              imported.hasCompletedOnboarding = true
              @Shared(.hexSettings) var hexSettings
              $hexSettings.withLock { $0 = imported }
            } catch {
              HexLog.settings.error("Failed to import settings: \(error.localizedDescription)")
            }
          }
        }

      case let .setSelectedPlan(plan):
        state.$hexSettings.withLock { $0.selectedPlan = plan }
        if plan == "pro" {
          state.$hexSettings.withLock { $0.aiProcessingEnabled = true }
        }
        return .run { _ in
          await AnalyticsUploader.shared.scheduleUpload()
        }

      case let .setCloudSyncEnabled(enabled):
        state.$hexSettings.withLock { $0.cloudSyncEnabled = enabled }
        return .none

      case .syncNow:
        let history = state.transcriptionHistory.history
        return .run { send in
          await MacCloudSync.shared.syncTranscripts(history)
          let count = await MacCloudSync.shared.lastSyncNotesCount
          await send(.syncCompleted(notesDown: count, transcriptsUp: history.count))
        }

      case .syncCompleted:
        return .none

      }
    }
  }
}

// MARK: - API Key Validation

/// Lightweight validation: hit a cheap endpoint to confirm the key
/// authenticates. Returns true if the API accepts it, false on 401/403.
private func validateAPIKey(_ key: String, provider: AIProvider) async -> Bool {
  switch provider {
  case .anthropic:
    // Send a minimal messages request — Anthropic doesn't have a
    // dedicated "whoami" endpoint, so we send max_tokens=1 to
    // keep the response tiny and fast.
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = 10
    let body: [String: Any] = [
      // Same model the app uses for real calls. A hardcoded
      // "claude-sonnet-4-20250514" here started 404ing when that model
      // retired (June 2026), which read as "invalid key" for every user.
      "model": AIProvider.anthropic.defaultModel,
      "messages": [["role": "user", "content": "hi"]],
      "max_tokens": 1,
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    guard let (_, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse
    else { return false }
    // Only auth failures prove the key is bad. Anything else (404 for a
    // retired model, 429 rate limit, 5xx) means the key authenticated —
    // or at least isn't proven invalid — so don't lock the user out.
    return http.statusCode != 401 && http.statusCode != 403

  case .openAI:
    // GET /v1/models is free and confirms the key.
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10
    guard let (_, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse
    else { return false }
    return http.statusCode == 200
  }
}
