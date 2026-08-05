//
//  SettingsTabs.swift
//  Hex (macOS)
//
//  Wrapper views that compose the existing settings section views
//  into focused, scannable screens. The original `SettingsView`
//  stuffed eleven sections into a single Form, which made the
//  Settings sidebar tab feel like a kitchen drawer. As of 0.9.x the
//  app sidebar has separate destinations for General, Recording, AI,
//  and Integrations — each one renders one of these wrappers.
//
//  Each wrapper is intentionally tiny — just a `Form` that lists the
//  pre-existing section views. No new behavior; this is purely an
//  information-architecture pass.
//

import ComposableArchitecture
import HexCore
import Inject
import Sparkle
import SwiftUI

// MARK: - General

/// Cross-cutting settings that don't belong to a specific recording /
/// AI / integration concern: permissions surface, sound feedback, and
/// the small set of app-level toggles (open on login, dock icon).
/// Recording-time behavior and transcript-history controls used to
/// live here too — those moved to the Recording tab in the 0.10
/// settings reorganization.
struct GeneralSettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus
  let accessibilityPermission: PermissionStatus
  let inputMonitoringPermission: PermissionStatus

  var body: some View {
    Form {
      // The Status overview restated the Permissions section plus two
      // other tabs' state, so it's gone. The Keyboard Shortcuts summary
      // stays: it looks like a read-only mirror, but it's how people
      // FIND the hotkey editor (its footer names the Recording tab).
      // Removing it made the editor effectively undiscoverable.
      // Permissions still appears, but only when something needs granting.
      if microphonePermission != .granted
          || accessibilityPermission != .granted
          || inputMonitoringPermission != .granted
      {
        PermissionsSectionView(
          store: store,
          microphonePermission: microphonePermission,
          accessibilityPermission: accessibilityPermission,
          inputMonitoringPermission: inputMonitoringPermission
        )
      }
      SoundSectionView(store: store)
      GeneralSectionView(store: store)
      KeyboardShortcutReferenceView(store: store)
      CloudSyncSectionView(store: store)
      AboutSectionView(store: store)
      AdvancedSettingsToggle(summary: "Settings export, import, and reset.")
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - Plan

/// The subscription surface: Free vs Pro comparison + activation.
struct PlanSettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      PlanSectionView(store: store)
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - Agent

/// The personal agent hub: identity, learned memory, saved routines,
/// and the offline action queue (pending agent work). Everything on
/// this tab is about what the agent knows and does on the user's
/// behalf — kept separate from General so the flagship feature has a
/// front door instead of being buried between sound and dock toggles.
struct AgentSettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      AgentSectionView()
      OfflineQueueSectionView()
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - Recording

/// Comprehensive recording hub — every knob that touches the path from
/// "user pressed the hotkey" to "transcript pasted into another app":
/// model + language, microphone, hotkeys, what happens to system audio
/// during a recording, how the finished text is delivered, and the
/// transcript-history retention controls. Recording-time behavior and
/// history settings used to be split across General; the 0.10 settings
/// reorganization consolidated them here.
struct RecordingSettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus
  @AppStorage(AdvancedSettings.defaultsKey) private var showAdvanced = false

  var body: some View {
    Form {
      ModelSectionView(store: store, shouldFlash: store.shouldFlashModelSection)
      // Parakeet is multilingual + auto-detects, so the language picker
      // only makes sense for the WhisperKit family.
      if ParakeetModel(rawValue: store.hexSettings.selectedModel) == nil {
        LanguageSectionView(store: store)
      }
      if microphonePermission == .granted {
        MicrophoneSelectionSectionView(store: store)
      }
      HotKeySectionView(store: store)
      RecordingBehaviorSectionView(store: store)
      HistorySectionView(store: store)
      // Paste mechanics and word corrections are troubleshooting tools —
      // most people never need them, and the per-app delay list is long.
      if showAdvanced {
        RecordingOutputSectionView(store: store)
        WordRemappingsSection(store: store)
      }
      AdvancedSettingsToggle(summary: "Text output, clipboard behavior, and word corrections.")
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - AI

/// Everything that touches a cloud LLM, organized as a small hierarchy:
/// the master toggle on top, then **Provider** (which API + key),
/// **Default Mode** (which post-processing flavor + auto-pick-by-app),
/// **Behavior** (context, voice commands, inline edit, future
/// streaming-transcript), and the user's library of **Custom Modes**.
/// Future Pro-only AI features will cluster here.
struct AISettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      AIProcessingSectionView(store: store)
    }
    .formStyle(.grouped)
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - Integrations

/// Stand-alone tab for the integrations catalog. Kept separate from
/// AI because integrations are about *destinations* (where a
/// dictation goes — Todoist, Notion, Slack, …), while AI is about
/// *transformations* (how the text reads when it gets there).
struct IntegrationsSettingsTabView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    // Stack the Google Account panel above the per-integration catalog so
    // sign-in is the first thing the user sees on this tab. ScrollView wraps
    // both because each child uses `.formStyle(.grouped)` — without it the
    // catalog can clip under the window's bottom edge on smaller windows.
    ScrollView {
      VStack(spacing: 0) {
        GoogleAccountSectionView(store: store)
        // One unified surface: native integrations + featured MCP
        // brands render as the same kind of row ("Apps & services"),
        // with custom MCP servers below. The Agent tab keeps identity/
        // routines/memory.
        ConnectionsSectionView()
      }
    }
    .task { await store.send(.task).finish() }
    .enableInjection()
  }
}

// MARK: - Status Overview

private struct StatusOverviewView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let microphonePermission: PermissionStatus
  let accessibilityPermission: PermissionStatus

  var body: some View {
    Section {
      statusRow(
        "Microphone",
        icon: "mic.fill",
        ok: microphonePermission == .granted,
        detail: microphonePermission == .granted ? "Ready" : "Permission needed"
      )
      statusRow(
        "Accessibility",
        icon: "accessibility",
        ok: accessibilityPermission == .granted,
        detail: accessibilityPermission == .granted ? "Ready" : "Permission needed"
      )
      statusRow(
        "Transcription Model",
        icon: "cpu",
        ok: !store.hexSettings.selectedModel.isEmpty,
        detail: modelDisplayName
      )
      statusRow(
        "AI Processing",
        icon: "sparkles",
        ok: !store.hexSettings.aiProcessingEnabled || store.apiKeySaved,
        detail: aiDetail
      )
    } header: {
      Text("Status")
    }
  }

  @ViewBuilder
  private func statusRow(_ label: String, icon: String, ok: Bool, detail: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .frame(width: 16)
        .foregroundStyle(.white)
      Text(label)
      Spacer()
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
      Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(ok ? .green : .orange)
    }
  }

  private var modelDisplayName: String {
    let model = store.hexSettings.selectedModel
    if model.isEmpty { return "Not selected" }
    // Show a friendly name: strip path prefixes and model family suffixes
    let components = model.split(separator: "/")
    return String(components.last ?? Substring(model))
  }

  private var aiDetail: String {
    if !store.hexSettings.aiProcessingEnabled { return "Off" }
    if store.apiKeySaved { return "\(store.hexSettings.aiProvider.displayName) \u{2713}" }
    return "API key needed"
  }
}

// MARK: - Keyboard Shortcuts

private struct KeyboardShortcutReferenceView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Section {
      shortcutRow(
        label: "Record",
        hotkey: store.hexSettings.hotkey,
        icon: "mic.fill"
      )

      // Always list every assignable shortcut, even unassigned ones —
      // hiding the unset rows meant a user with no Cycle Mode shortcut
      // had no clue one existed, let alone where to set it.
      shortcutRow(
        label: "Cycle Mode",
        hotkey: store.hexSettings.cycleModeHotkey,
        icon: "rectangle.3.group.fill"
      )

      shortcutRow(
        label: "Paste Last",
        hotkey: store.hexSettings.pasteLastTranscriptHotkey,
        icon: "doc.on.clipboard"
      )
      Button {
        NotificationCenter.default.post(name: .openRecordingSettings, object: nil)
      } label: {
        Label("Change shortcuts\u{2026}", systemImage: "arrow.right.circle")
      }
    } header: {
      Text("Keyboard Shortcuts")
    } footer: {
      Text("Shortcuts are set in the Recording tab, under Hot Key.")
        .settingsCaption()
    }
  }

  @ViewBuilder
  private func shortcutRow(label: String, hotkey: HotKey, icon: String) -> some View {
    shortcutRow(label: label, hotkey: Optional(hotkey), icon: icon)
  }

  /// `nil` renders a muted "Not set" so unassigned shortcuts still
  /// announce that they exist.
  private func shortcutRow(label: String, hotkey: HotKey?, icon: String) -> some View {
    HStack {
      Label(label, systemImage: icon)
      Spacer()
      if let hotkey {
        Text(hotkeyDisplayString(hotkey))
          .font(.system(.body, design: .rounded).weight(.medium))
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: QuillDesign.Radius.chip))
      } else {
        Text("Not set")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func hotkeyDisplayString(_ hotkey: HotKey) -> String {
    var parts: [String] = []
    if hotkey.modifiers.isHyperkey {
      parts.append("✦")
    } else {
      parts.append(contentsOf: hotkey.modifiers.sorted.map(\.kind.symbol))
    }
    if let key = hotkey.key {
      parts.append(key.toString)
    }
    let result = parts.joined()
    return result.isEmpty ? "Not set" : result
  }
}

// MARK: - About

private struct AboutSectionView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var viewModel = CheckForUpdatesViewModel.shared
  @State private var showingChangelog = false

  var body: some View {
    Section {
      HStack {
        Label("Version", systemImage: "info.circle")
        Spacer()
        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
          .foregroundStyle(.secondary)
        Button("Check for Updates") {
          viewModel.checkForUpdates()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      HStack {
        Label("Changelog", systemImage: "doc.text")
        Spacer()
        Button("Show Changelog") {
          showingChangelog.toggle()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .sheet(isPresented: $showingChangelog) {
          ChangelogView()
        }
      }
      Button {
        store.send(.replayOnboarding)
      } label: {
        Label("Replay Tutorial", systemImage: "sparkle.magnifyingglass")
      }
      HStack {
        Label("Built by Joe Vasquez", systemImage: "person.circle")
        Spacer()
        Link("joevasquez.com", destination: URL(string: "https://joevasquez.com")!)
          .font(.caption)
      }
    } header: {
      Text("About")
    }
  }
}

// MARK: - Word Corrections (formerly Transforms tab)

/// Collapsible section wrapping the transcript-modification rules (word
/// removals & remappings) that previously lived on a standalone Transforms
/// tab. Embedded in the Recording tab so users find all recording-pipeline
/// settings in one place.
private struct WordRemappingsSection: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Section {
      DisclosureGroup {
        WordRemappingsView(store: store)
          .padding(.top, 8)
      } label: {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("Word Corrections")
              .font(.subheadline.weight(.semibold))
            Text("Remove filler words or auto-replace specific terms in every transcript")
              .settingsCaption()
          }
        } icon: {
          Image(systemName: "text.badge.plus")
        }
      }
    } header: {
      Text("Transcript Modifications")
    }
  }
}
