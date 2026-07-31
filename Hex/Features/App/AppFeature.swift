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
    /// Free vs Pro comparison + plan activation.
    case plan
    /// Integration connections (Todoist, Apple Reminders, Notion,
    /// Things, Slack, Linear). Frontend-only as of 0.9.x — connection
    /// state is persisted but send adapters land in a follow-up.
    case integrations
    /// Transcription history viewer.
    case history
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
          await pasteboard.paste(lastTranscript, nil)
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
          .run { _ in await MacSuggestionsController.shared.refreshOnAppear() }
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

/// Top-level "mode" the sidebar is in. The user toggles between
/// these via a segmented control at the top of the sidebar — when
/// Settings is selected the sidebar lists configuration sub-tabs,
/// when History is selected the sidebar collapses so the transcript
/// list and detail get the full window width.
private enum SidebarMode: String, CaseIterable, Identifiable {
  case home, settings, history, notes
  var id: String { rawValue }
}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic
  /// Resolved from `store.activeTab` so sub-tab clicks keep the
  /// sidebar in the right mode without an extra source of truth.
  private var sidebarMode: SidebarMode {
    switch store.state.activeTab {
    case .home: .home
    case .history: .history
    case .notes: .notes
    default: .settings
    }
  }

  /// "← Home" for every non-home pane — with the sidebar toggle gone,
  /// Home is the hub and this is the way back.
  private var backToHome: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button {
        store.send(.setActiveTab(.home))
      } label: {
        Label("Home", systemImage: "chevron.left")
      }
      .help("Back to Home")
    }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      // Home is the navigation hub (toolbar icons + back buttons replace
      // the old segmented mode toggle), so the sidebar only exists where
      // it carries real content: Settings sub-tabs and the note list.
      // Home and History collapse it entirely via `columnVisibility`.
      Group {
        // Home and History have no sidebar at all — also drop the
        // window's sidebar-toggle button there so an empty column can't
        // be summoned.
        if sidebarMode == .home || sidebarMode == .history {
          VStack(alignment: .leading, spacing: 0) {}
            .toolbar(removing: .sidebarToggle)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            if sidebarMode == .settings {
              List(selection: $store.activeTab) {
                tabRow(.general, label: "General", icon: "gearshape.fill", tint: .gray)
                tabRow(.agent, label: agentTabLabel, icon: "sparkles", tint: .purple)
                tabRow(.recording, label: "Recording", icon: "mic.fill", tint: .red)
                tabRow(.ai, label: "AI Processing", icon: "wand.and.stars", tint: .blue)
                tabRow(.integrations, label: "Integrations", icon: "app.connected.to.app.below.fill", tint: .teal)
                tabRow(.plan, label: "Subscription", icon: "crown.fill", tint: .yellow)
              }
              .listStyle(.sidebar)
            } else {
              NotesSidebarList()
            }
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    } detail: {
      switch store.state.activeTab {
      case .home:
        HomeView(
          openNote: { id in
            NoteSelectionState.shared.selectedNoteID = id
            store.send(.setActiveTab(.notes))
          },
          openSettings: { store.send(.setActiveTab(.general)) },
          openIntegrations: { store.send(.setActiveTab(.integrations)) },
          openNotesPane: { store.send(.setActiveTab(.notes)) }
        )
        .navigationTitle("Home")
        .toolbar {
          ToolbarItemGroup(placement: .primaryAction) {
            Button {
              store.send(.setActiveTab(.notes))
            } label: {
              Label("Notes", systemImage: "list.bullet")
            }
            .help("Notes")
            Button {
              store.send(.setActiveTab(.history))
            } label: {
              Label("History", systemImage: "chart.bar.xaxis")
            }
            .help("History")
            Button {
              store.send(.setActiveTab(.general))
            } label: {
              Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
          }
        }
      case .general:
        GeneralSettingsTabView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission,
          accessibilityPermission: store.accessibilityPermission,
          inputMonitoringPermission: store.inputMonitoringPermission
        )
        .navigationTitle("General")
        .toolbar { backToHome }
      case .agent:
        AgentSettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle(agentTabLabel)
          .toolbar { backToHome }
      case .recording:
        RecordingSettingsTabView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission
        )
        .navigationTitle("Recording")
        .toolbar { backToHome }
      case .ai:
        AISettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("AI")
          .toolbar { backToHome }
      case .integrations:
        IntegrationsSettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Integrations")
          .toolbar { backToHome }
      case .plan:
        PlanSettingsTabView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Subscription")
          .toolbar { backToHome }
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
          .toolbar { backToHome }
      case .notes:
        NotesView()
          .navigationTitle("Notes")
          .toolbar { backToHome }
      }
    }
    // The shortcut summary in General posts this so its "Change
    // shortcuts…" row lands on the actual editor.
    .onReceive(NotificationCenter.default.publisher(for: .openRecordingSettings)) { _ in
      store.send(.setActiveTab(.recording))
    }
    // Home and History have no sidebar content — collapse the column
    // entirely there; Settings (sub-tabs) and Notes (note list) keep it.
    .onChange(of: store.state.activeTab, initial: true) { _, newTab in
      columnVisibility = (newTab == .home || newTab == .history) ? .detailOnly : .all
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
      OnboardingView(
        store: store.scope(state: \.settings, action: \.settings),
        microphonePermission: store.microphonePermission,
        accessibilityPermission: store.accessibilityPermission,
        inputMonitoringPermission: store.inputMonitoringPermission,
        onDismiss: {
          // Already marked complete inside `OnboardingView.complete`,
          // but the SwiftUI sheet binding needs us to flip its
          // `isPresented` source-of-truth, which we do by sending
          // the same action defensively.
          store.send(.settings(.markOnboardingComplete))
        }
      )
    }
    .enableInjection()
  }

  /// The agent tab shows the user's chosen agent name so the sidebar
  /// reads "Hermes" (or whatever they named it), not a generic "Agent".
  private var agentTabLabel: String {
    let name = store.hexSettings.agentName.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "Agent" : name
  }

  /// Sidebar row builder. Encodes the consistent button-as-row
  /// pattern used by every entry in the navigation list and keeps
  /// the call sites readable. Icons render in System Settings-style
  /// tinted tiles so the list scans by color as well as label.
  @ViewBuilder
  private func tabRow(_ tab: AppFeature.ActiveTab, label: String, icon: String, tint: Color) -> some View {
    Button {
      store.send(.setActiveTab(tab))
    } label: {
      Label {
        Text(label)
          .font(.system(size: 13))
      } icon: {
        Image(systemName: icon)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 22, height: 22)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(tint.gradient)
          )
      }
    }
    .buttonStyle(.plain)
    .tag(tab)
  }
}
