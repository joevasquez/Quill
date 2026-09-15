//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import Sauce
import SwiftUI

/// Maps Sauce key codes for top-row digits 1…9 to their numeric value.
/// Returns nil for any other key (including `0` — the picker only goes
/// up to nine integrations to keep the chip row from wrapping).
private func digitValue(for key: Key) -> Int? {
  switch key {
  case .one: return 1
  case .two: return 2
  case .three: return 3
  case .four: return 4
  case .five: return 5
  case .six: return 6
  case .seven: return 7
  case .eight: return 8
  case .nine: return 9
  default: return nil
  }
}

@Reducer
struct AppFeature {
  enum ActiveTab: Equatable {
    /// The landing pane: proactive suggestions (Pro) + recent
    /// cloud-synced notes — the macOS mirror of the iOS home.
    case home
    /// General settings: permissions, sound, general (login, dock,
    /// sleep), and history-retention configuration.
    case general
    /// The personal agent hub: identity (name), saved routines,
    /// learned memory, and pending offline actions.
    case agent
    /// Recording-specific settings: Whisper/Parakeet model, output
    /// language, hotkey configuration, microphone selection.
    case recording
    /// AI post-processing settings: API keys, modes, voice commands,
    /// inline edit, custom user-authored modes.
    case ai
    /// Identity, Free vs Pro, Google sign-in, and cross-device sync.
    case account
    /// Theme and recording-indicator presentation.
    case appearance
    /// Integration connections (Todoist, Apple Reminders, Notion,
    /// Things, Slack, Linear). Frontend-only as of 0.9.x — connection
    /// state is persisted but send adapters land in a follow-up.
    case integrations
    /// Transcription history viewer.
    case history
    /// Action-run history with per-step traces — what the agent did, and
    /// what each step's tool actually returned.
    case actions
    /// Cloud-synced notes (originating on iOS) viewer.
    case notes
  }

	@ObservableState
	struct State {
		var transcription: TranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var history: HistoryFeature.State = .init()
		var activeTab: ActiveTab = .home
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    // Permission state
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var inputMonitoringPermission: PermissionStatus = .notDetermined
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case setActiveTab(ActiveTab)
    case task
    case pasteLastTranscript

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus)
    case appActivated
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring
    case modelStatusEvaluated(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcription) var transcription
  @Dependency(\.permissions) var permissions

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none
        
      case .task:
        return .merge(
          startPasteLastTranscriptMonitoring(),
          startCycleModeHotKeyMonitoring(),
          startActionIntegrationHotKeyMonitoring(),
          ensureSelectedModelReadiness(),
          startPermissionMonitoring()
        )
        
      case .pasteLastTranscript:
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
        guard let lastTranscript = transcriptionHistory.history.first?.text else {
          return .none
        }
        return .run { _ in
          // No source app to reactivate — this action is triggered by
          // a user hotkey / menu click; the frontmost app at that
          // moment IS the target.
          _ = await pasteboard.paste(lastTranscript, nil)
        }
        
      case .transcription(.modelMissing):
        HexLog.app.notice("Model missing - activating app and switching to Recording settings")
        // The model selector now lives in the Recording tab (split
        // out of the old monolithic Settings page in 0.9.x).
        state.activeTab = .recording
        state.settings.shouldFlashModelSection = true
        return .run { send in
          await MainActor.run {
            HexLog.app.notice("Activating app for model missing")
            NSApplication.shared.activate(ignoringOtherApps: true)
          }
          try? await Task.sleep(for: .seconds(2))
          await send(.settings(.set(\.shouldFlashModelSection, false)))
        }

      case .transcription:
        return .none

      case .settings:
        return .none

      case .history(.navigateToSettings):
        state.activeTab = .general
        return .none
      case .history:
        return .none
		case let .setActiveTab(tab):
			state.activeTab = tab
			return .none

      // Permission handling
      case .checkPermissions:
        return .run { send in
          async let mic = permissions.microphoneStatus()
          async let acc = permissions.accessibilityStatus()
          async let input = permissions.inputMonitoringStatus()
          await send(.permissionsUpdated(mic: mic, acc: acc, input: input))
        }

      case let .permissionsUpdated(mic, acc, input):
        state.microphonePermission = mic
        state.accessibilityPermission = acc
        state.inputMonitoringPermission = input
        return .none

      case .appActivated:
        // App became active — re-check permissions, and refresh the Home
        // suggestions feed (self-gating: Pro + 30-min TTL) so a window
        // reopened after lunch isn't showing a stale morning feed.
        return .merge(
          .send(.checkPermissions),
          .run { _ in await MacSuggestionsController.shared.refreshOnAppear() },
          .run { _ in
            @Shared(.transcriptionHistory) var history: TranscriptionHistory
            await MacCloudSync.shared.syncIfNeeded(history.history)
          }
        )

      case .requestMicrophone:
        return .run { send in
          _ = await permissions.requestMicrophone()
          await send(.checkPermissions)
        }

      case .requestAccessibility:
        return .run { send in
          await permissions.requestAccessibility()
          // Poll for status change (macOS doesn't provide callback)
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .requestInputMonitoring:
        return .run { send in
          _ = await permissions.requestInputMonitoring()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .modelStatusEvaluated:
        return .none
      }
    }
  }
  
  private func startPasteLastTranscriptMonitoring() -> Effect<Action> {
    .run { send in
      // Capture the shared *storage references* (Shared<Value> is Sendable) rather
      // than the @Shared property wrapper's var binding. Capturing the wrapper
      // produces a "reference to captured var in concurrently-executing code"
      // warning (hard error in Swift 6) and, more importantly, is a real data race
      // because the closure runs on the CGEvent tap's main-thread callback on every
      // key press. We project the Shared refs once and read them fresh on each hit.
      @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings
      let sharedIsSettingPaste = $isSettingPasteLastTranscriptHotkey
      let sharedHexSettings = $hexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if user is setting a hotkey
        if sharedIsSettingPaste.wrappedValue {
          return false
        }

        // Check if this matches the paste last transcript hotkey
        guard let pasteHotkey = sharedHexSettings.wrappedValue.pasteLastTranscriptHotkey,
              let key = keyEvent.key,
              key == pasteHotkey.key,
              keyEvent.modifiers.matchesExactly(pasteHotkey.modifiers) else {
          return false
        }

        // Trigger paste action - use MainActor to avoid escaping send
        MainActor.assumeIsolated {
          send(.pasteLastTranscript)
        }
        return true // Intercept the key event
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

  private func startCycleModeHotKeyMonitoring() -> Effect<Action> {
    .run { send in
      // Mirror startPasteLastTranscriptMonitoring's data-race-safe pattern.
      @Shared(.isSettingCycleModeHotkey) var isSettingCycleModeHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings
      let sharedIsSettingCycle = $isSettingCycleModeHotkey
      let sharedHexSettings = $hexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        if sharedIsSettingCycle.wrappedValue {
          return false
        }

        guard let cycleHotkey = sharedHexSettings.wrappedValue.cycleModeHotkey,
              let key = keyEvent.key,
              key == cycleHotkey.key,
              keyEvent.modifiers.matchesExactly(cycleHotkey.modifiers) else {
          return false
        }

        MainActor.assumeIsolated {
          send(.transcription(.cycleMode))
        }
        return true
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

  /// Listens for `fn + 1`…`fn + 9` while the HUD is in Action mode and
  /// toggles the matching integration lock. Mirrors the data-race-safe
  /// pattern used by the paste / cycle-mode monitors above.
  ///
  /// The reducer (TranscriptionFeature) ignores the action when not in
  /// Action mode, but we also gate it here so we don't intercept fn+digit
  /// keystrokes for users who never touch Action mode.
  private func startActionIntegrationHotKeyMonitoring() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      let sharedHexSettings = $hexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        // Fast reject: must have fn modifier and exactly one of digits 1-9.
        guard keyEvent.modifiers.contains(kind: .fn),
              let key = keyEvent.key,
              let digit = digitValue(for: key) else {
          return false
        }
        // Must be ONLY fn (no command/option/shift/control combos), so
        // we don't fight other apps' fn+modifier shortcuts.
        let mods = keyEvent.modifiers
        if mods.contains(kind: .command) || mods.contains(kind: .option) ||
           mods.contains(kind: .shift) || mods.contains(kind: .control) {
          return false
        }
        // Don't intercept while the user is dictating (recording) so the
        // running hotkey + speech path stays clean. The picker is a
        // pre-recording or idle affordance.
        _ = sharedHexSettings.wrappedValue  // future-proof — kept for symmetry

        MainActor.assumeIsolated {
          send(.transcription(.actionIntegrationKeyboardToggle(digit)))
        }
        return true
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

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else {
        await send(.modelStatusEvaluated(false))
        return
      }
      let isReady = await transcription.isModelDownloaded(selectedModel)
      $modelBootstrapState.withLock { state in
        state.modelIdentifier = selectedModel
        if state.modelDisplayName?.isEmpty ?? true {
          state.modelDisplayName = selectedModel
        }
        state.isModelReady = isReady
        if isReady {
          state.lastError = nil
          state.progress = 1
        } else {
          state.progress = 0
        }
      }
      await send(.modelStatusEvaluated(isReady))
    }
  }

  private func startPermissionMonitoring() -> Effect<Action> {
    .run { send in
      // Initial check on app launch
      await send(.checkPermissions)

      // Monitor app activation events
      for await activation in permissions.observeAppActivation() {
        if case .didBecomeActive = activation {
          await send(.appActivated)
        }
      }

    }
  }

}

/// Stable, app-level navigation. Contextual lists (notes and settings) live
/// in the workspace beside this sidebar instead of replacing it.
private enum PrimaryDestination: Hashable {
  case home, notes, actions, history, settings
}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var lastSettingsTab: AppFeature.ActiveTab = .general

  private var primaryDestination: PrimaryDestination {
    switch store.state.activeTab {
    case .home: return .home
    case .notes: return .notes
    case .actions: return .actions
    case .history: return .history
    default: return .settings
    }
  }

  private var isSettingsTab: Bool {
    switch store.state.activeTab {
    case .general, .account, .appearance, .agent, .recording, .ai, .integrations: true
    default: false
    }
  }

  var body: some View {
    NavigationSplitView {
      primarySidebar
    } detail: {
      detailContent
    }
    // The shortcut summary in General posts this so its "Change
    // shortcuts…" row lands on the actual editor.
    .onReceive(NotificationCenter.default.publisher(for: .openRecordingSettings)) { _ in
      store.send(.setActiveTab(.recording))
    }
    .onChange(of: store.state.activeTab, initial: true) { _, newTab in
      if isSettingsTab { lastSettingsTab = newTab }
    }
    .sheet(isPresented: Binding(
      get: { !store.settings.hexSettings.hasCompletedOnboarding },
      set: { newValue in
        // The onboarding view fires `.markOnboardingComplete` itself
        // when it dismisses; this setter just handles the case where
        // SwiftUI dismisses the sheet for some other reason.
        if newValue == false {
          store.send(.settings(.markOnboardingComplete))
        }
      }
    )) {
      onboardingSheet
    }
    .enableInjection()
  }

  /// Persistent app navigation. Toolbars remain contextual to the current
  /// destination instead of doubling as navigation controls.
  @ViewBuilder
  private var primarySidebar: some View {
    VStack(spacing: 0) {
      List {
        primaryNavigationButton(.home, label: "Home", icon: "house")
        primaryNavigationButton(.notes, label: "Notes", icon: "note.text")
        primaryNavigationButton(.actions, label: "Actions", icon: "bolt.badge.clock")
        primaryNavigationButton(.history, label: "History", icon: "clock.arrow.circlepath")
      }
      .listStyle(.sidebar)

      Divider()
      primaryNavigationButton(.settings, label: "Settings", icon: "gearshape")
        .padding(8)
    }
    .navigationTitle("Quill")
    .navigationSplitViewColumnWidth(min: 155, ideal: 175, max: 220)
  }

  private func primaryNavigationButton(
    _ destination: PrimaryDestination,
    label: String,
    icon: String
  ) -> some View {
    Button {
      switch destination {
      case .home: store.send(.setActiveTab(.home))
      case .notes: store.send(.setActiveTab(.notes))
      case .actions: store.send(.setActiveTab(.actions))
      case .history: store.send(.setActiveTab(.history))
      case .settings: store.send(.setActiveTab(lastSettingsTab))
      }
    } label: {
      Label(label, systemImage: icon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
        .fill(primaryDestination == destination ? Color.accentColor.opacity(0.18) : Color.clear)
    )
    .accessibilityAddTraits(primaryDestination == destination ? .isSelected : [])
  }

  @ViewBuilder
  private var detailContent: some View {
    if isSettingsTab {
      settingsWorkspace
    } else {
      switch store.state.activeTab {
      case .home:
        HomeView(
          transcriptionStore: store.scope(state: \.transcription, action: \.transcription),
          openNote: { id in
            NoteSelectionState.shared.selectedNoteID = id
            store.send(.setActiveTab(.notes))
          },
          openSettings: { store.send(.setActiveTab(.general)) },
          openIntegrations: { store.send(.setActiveTab(.integrations)) },
          openNotesPane: { store.send(.setActiveTab(.notes)) }
        )
        .navigationTitle("Home")
      case .notes:
        notesWorkspace
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
      case .actions:
        ActionRunsView()
          .navigationTitle("Actions")
      case .general, .account, .appearance, .agent, .recording, .ai, .integrations:
        EmptyView()
      }
    }
  }

  private var notesWorkspace: some View {
    HSplitView {
      NotesSidebarList()
        .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
      NotesView()
        .frame(minWidth: 360)
        .navigationTitle("Notes")
    }
  }

  private var settingsWorkspace: some View {
    HSplitView {
      List(selection: $store.activeTab) {
        tabRow(.general, label: "General", icon: "gearshape")
        tabRow(.account, label: "Account", icon: "person.crop.circle")
        tabRow(.appearance, label: "Appearance", icon: "paintbrush")
        tabRow(.agent, label: agentTabLabel, icon: "sparkles")
        tabRow(.recording, label: "Recording", icon: "mic")
        tabRow(.ai, label: "AI Processing", icon: "wand.and.stars")
        tabRow(.integrations, label: "Integrations", icon: "app.connected.to.app.below.fill")
      }
      .listStyle(.sidebar)
      .frame(minWidth: 190, idealWidth: 220, maxWidth: 270)

      settingsDetail
        .frame(minWidth: 420)
    }
  }

  @ViewBuilder
  private var settingsDetail: some View {
    switch store.state.activeTab {
      case .general:
        GeneralSettingsTabView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission,
          accessibilityPermission: store.accessibilityPermission,
          inputMonitoringPermission: store.inputMonitoringPermission
        )
        .navigationTitle("General")
      case .account:
        AccountSettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Account")
      case .appearance:
        AppearanceSettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Appearance")
      case .agent:
        AgentSettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle(agentTabLabel)
      case .recording:
        RecordingSettingsTabView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission
        )
        .navigationTitle("Recording")
      case .ai:
        AISettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("AI")
      case .integrations:
        IntegrationsSettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Integrations")
      case .home, .notes, .history, .actions:
        EmptyView()
      }
  }

  /// Extracted from the `.sheet` call site along with the rest of the split
  /// view's body — inline it and `body` stops type-checking in reasonable time.
  private var onboardingSheet: some View {
    OnboardingView(
      store: store.scope(state: \.settings, action: \.settings),
      microphonePermission: store.microphonePermission,
      accessibilityPermission: store.accessibilityPermission,
      inputMonitoringPermission: store.inputMonitoringPermission,
      onDismiss: {
        // Already marked complete inside `OnboardingView.complete`, but the
        // SwiftUI sheet binding needs us to flip its `isPresented`
        // source-of-truth, which we do by sending the same action defensively.
        store.send(.settings(.markOnboardingComplete))
      }
    )
  }

  /// The agent tab shows the user's chosen agent name so the sidebar
  /// reads "Hermes" (or whatever they named it), not a generic "Agent".
  private var agentTabLabel: String {
    let name = store.hexSettings.agentName.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "Agent" : name
  }

  /// Sidebar row builder. Encodes the consistent button-as-row
  /// pattern used by every entry in the navigation list and keeps
  /// the call sites readable. One monochrome symbol language matches the
  /// primary sidebar; Quill violet appears only on the active destination.
  @ViewBuilder
  private func tabRow(_ tab: AppFeature.ActiveTab, label: String, icon: String) -> some View {
    Button {
      store.send(.setActiveTab(tab))
    } label: {
      Label {
        Text(label)
          .font(.system(size: 13))
      } icon: {
        Image(systemName: icon)
          .symbolRenderingMode(.monochrome)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(store.state.activeTab == tab ? QuillDesign.brand.color() : Color.primary)
          .frame(width: 22, height: 22)
      }
    }
    .buttonStyle(.plain)
    .tag(tab)
  }
}
