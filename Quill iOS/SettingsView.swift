//
//  SettingsView.swift
//  Quill (iOS)
//
//  iOS settings: transcription model, AI provider, API keys. AI mode is
//  chosen on the main screen via the chip row.
//

import HexCore
import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss

  @AppStorage(QuillIOSSettingsKey.selectedModel) private var selectedModel: String = QuillIOSSettingsKey.defaultModel
  @AppStorage(QuillIOSSettingsKey.appearance) private var appearanceRaw: String = QuillAppearance.system.rawValue
  @AppStorage(QuillIOSSettingsKey.captureAvatar) private var captureAvatarRaw: String = QuillIOSSettingsKey.defaultCaptureAvatarValue
  /// Doubles as "last mode used on the home rail" — the rail writes back
  /// here so a relaunch reopens where the user left off.
  @AppStorage(QuillIOSSettingsKey.defaultCaptureMode) private var defaultCaptureModeRaw: String = QuillIOSSettingsKey.defaultCaptureModeValue
  @AppStorage(QuillIOSSettingsKey.aiProvider) private var aiProviderRaw: String = QuillIOSSettingsKey.defaultProvider
  @AppStorage(QuillIOSSettingsKey.voiceCommandsEnabled) private var voiceCommandsEnabled: Bool = QuillIOSSettingsKey.defaultVoiceCommandsEnabled
  @AppStorage(QuillIOSSettingsKey.autoActionRouting) private var autoActionRouting: Bool = QuillIOSSettingsKey.defaultAutoActionRouting
  @AppStorage(CustomAIModesStorage.userDefaultsKey) private var customModesData: Data = Data()
  @AppStorage(IntegrationConnectionStore.userDefaultsKey) private var integrationData: Data = Data()
  @AppStorage(ErrorMonitoringSettings.crashReportingEnabledKey) private var crashReportingEnabled: Bool = false
  @AppStorage(CloudSyncConstants.cloudSyncEnabledKey) private var cloudSyncEnabled: Bool = false
  /// JSON-encoded set of built-in AI modes the user has hidden from
  /// the home-screen pill bar. Defaults to empty (everything visible).
  @AppStorage(QuillIOSSettingsKey.disabledBuiltInModes) private var disabledBuiltInModesData: Data = Data()
  @AppStorage(QuillIOSSettingsKey.suggestionsEnabled) private var suggestionsEnabled: Bool = true
  @AppStorage(QuillIOSSettingsKey.suggestionSourcePrefs) private var suggestionSourceData: Data = Data()
  @AppStorage(QuillIOSSettingsKey.selectedPlan) private var selectedPlanRaw: String = ""

  private var customModeCountLabel: String {
    let count = CustomAIModesStorage.decode(customModesData).count
    if count == 0 { return "None" }
    return count == 1 ? "1 mode" : "\(count) modes"
  }

  private var integrationCountLabel: String {
    let count = IntegrationConnectionStore.decode(integrationData).count
    let cap = IntegrationLimits.freeTierMaxConnections
    return "\(count)/\(cap)"
  }

  /// Trailing accessory for the Agent row — the user's agent name.
  private var agentNameLabel: String {
    UserDefaults.standard.string(forKey: QuillIOSSettingsKey.agentName)
      ?? QuillIOSSettingsKey.defaultAgentName
  }

  /// Trailing accessory for the Google Account row. Shows the cached email
  /// when signed in (truncated by lineLimit at the call site), or a
  /// "Connect" hint when signed out — mirrors how `integrationCountLabel`
  /// previews state without requiring a tap.
  private var googleAccountLabel: String {
    if IOSGoogleOAuthClient.isAuthorized() {
      return UserDefaults.standard.string(forKey: IOSGoogleOAuthClient.googleAccountEmailDefaultsKey) ?? "Connected"
    }
    return "Connect"
  }

  @State private var apiKeyText: String = ""
  @State private var isAPIKeyVisible: Bool = false
  @State private var apiKeySaved: Bool = false

  /// Refreshed on view appear via `.task`. Async-only state because
  /// `ActionQueueManager.snapshot()` lives on an actor.
  @State private var offlineQueueCount: Int = 0

  private var offlineQueueLabel: String {
    offlineQueueCount == 0 ? "Empty" : "\(offlineQueueCount) pending"
  }

  /// Read from the bundle rather than hardcoded — the old literal drifted
  /// from the real version on every release.
  private var appVersionString: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    return build.map { "\(short) (\($0))" } ?? short
  }

  // MARK: - Suggestions (Pro)

  private var isPro: Bool { selectedPlanRaw == "pro" }

  private func sourceBinding(_ source: SuggestionSource) -> Binding<Bool> {
    Binding(
      get: {
        SuggestionSourcePrefs.isEnabled(
          source,
          overrides: SuggestionSourcePrefs.decode(suggestionSourceData)
        )
      },
      set: { newValue in
        var overrides = SuggestionSourcePrefs.decode(suggestionSourceData)
        overrides[source.rawValue] = newValue
        suggestionSourceData = SuggestionSourcePrefs.encode(overrides)
      }
    )
  }

  @ViewBuilder
  private var suggestionsSection: some View {
    Section {
      if isPro {
        Toggle(isOn: $suggestionsEnabled) {
          HStack(spacing: 6) {
            Label("Proactive suggestions", systemImage: "lightbulb.max")
            Text("PRO")
              .quillFont(9, weight: .heavy)
              .tracking(0.4)
              .foregroundStyle(.white)
              .padding(.vertical, 1.5)
              .padding(.horizontal, 5)
              .background(RoundedRectangle(cornerRadius: QuillDesign.Radius.badge).fill(QuillDesign.brand.color()))
          }
        }
        .onChange(of: suggestionsEnabled) { _, isOn in
          // Toggling off clears the stored feed — no stale nudges
          // waiting if it's ever re-enabled.
          if !isOn { SuggestionsController.shared.clearAll() }
        }

        if suggestionsEnabled {
          ForEach(SuggestionSource.allCases) { source in
            Toggle(isOn: sourceBinding(source)) {
              Label(source.displayName, systemImage: source.systemImage)
            }
          }
        }
      } else {
        // Routes through the Quill Pro screen so upgrading is an
        // informed choice, not a silent flag flip.
        NavigationLink {
          QuillProView()
        } label: {
          Label("Upgrade to Pro", systemImage: "lock.fill")
        }
      }
    } header: {
      Text("Suggestions")
    } footer: {
      Text(
        isPro
          ? "When the app opens, Quill reads the sources you allow and offers ready-to-run actions. You always review before anything happens. Gmail and Dex are read through their connected MCP servers."
          : "Pro lets Quill watch your inbox, calendar, and contacts and offer ready-to-run actions — you always review before anything happens."
      )
    }
  }

  private let availableModels: [(id: String, name: String, size: String)] = [
    ("openai_whisper-tiny.en", "Whisper Tiny (English)", "~75 MB"),
    ("openai_whisper-tiny", "Whisper Tiny (Multilingual)", "~75 MB"),
    ("openai_whisper-base.en", "Whisper Base (English)", "~145 MB"),
    ("openai_whisper-small.en", "Whisper Small (English)", "~460 MB"),
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section {
          NavigationLink {
            QuillProView()
          } label: {
            HStack {
              Label {
                Text("Quill Pro")
              } icon: {
                Image(systemName: "crown.fill")
                  .foregroundStyle(QuillDesign.brand.color())
              }
              Spacer()
              Text(selectedPlanRaw == "pro" ? "Active" : "Free plan")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } footer: {
          Text("Built-in AI, proactive suggestions, unlimited connections.")
        }

        Section {
          Picker("Theme", selection: $appearanceRaw) {
            ForEach(QuillAppearance.allCases) { appearance in
              Text(appearance.label).tag(appearance.rawValue)
            }
          }
          .pickerStyle(.segmented)

          Picker("Avatar", selection: $captureAvatarRaw) {
            ForEach(QuillCaptureAvatarStyle.allCases) { style in
              Text(style.label).tag(style.rawValue)
            }
          }
          .pickerStyle(.segmented)
        } header: {
          Text("Appearance")
        } footer: {
          Text("Auto follows your device. Both avatars keep their mode colors in both themes. The note composer's small record button always shows the orb — the owl needs more room to stay legible.")
        }

        // Grouped into sub-screens: the root was 16 stacked sections,
        // which meant scrolling past the API key to reach the tutorial.
        Section {
          NavigationLink { captureScreen } label: {
            Label("Capture & Dictation", systemImage: "mic")
          }
          NavigationLink { aiScreen } label: {
            Label("AI & Modes", systemImage: "wand.and.stars")
          }
        }

        Section {
          NavigationLink {
            AgentSettingsView()
          } label: {
            HStack {
              Label("Agent", systemImage: "sparkles")
              Spacer()
              Text(agentNameLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          NavigationLink {
            ConnectionsView()
          } label: {
            HStack {
              Label("Connections", systemImage: "app.connected.to.app.below.fill")
              Spacer()
              Text(integrationCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } header: {
          Text("Productivity")
        } footer: {
          Text("Send dictations into Todoist, Apple Reminders, Gmail, Notion, Linear, Dex, and anything with an MCP server. Free plan includes \(IntegrationLimits.freeTierMaxConnections) — Pro unlocks all.")
        }

        Section {
          NavigationLink { suggestionsScreen } label: {
            HStack {
              Label("Suggestions", systemImage: "lightbulb.max")
              Spacer()
              Text(isPro ? (suggestionsEnabled ? "On" : "Off") : "Pro")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          NavigationLink { accountScreen } label: {
            HStack {
              Label("Account & Sync", systemImage: "icloud")
              Spacer()
              Text(googleAccountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }

        Section {
          NavigationLink { aboutScreen } label: {
            Label("About & Privacy", systemImage: "info.circle")
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .onAppear {
        loadKey()
        mirrorProviderToAppGroup(aiProviderRaw)
      }
      .onChange(of: aiProviderRaw) { _, newValue in
        apiKeyText = ""
        apiKeySaved = false
        loadKey()
        mirrorProviderToAppGroup(newValue)
      }
      .task {
        offlineQueueCount = await ActionQueueManager.shared.snapshot().count
      }
    }
  }


  


  private var currentProvider: AIProvider {
    AIProvider(rawValue: aiProviderRaw) ?? .anthropic
  }

  private var keychainKey: String {
    switch currentProvider {
    case .openAI: return KeychainKey.openAIAPIKey
    case .anthropic: return KeychainKey.anthropicAPIKey
    }
  }

  private func loadKey() {
    let (existing, status) = KeychainStore.read(account: keychainKey)
    if let existing, !existing.isEmpty {
      apiKeyText = existing
      apiKeySaved = true
    } else {
      apiKeyText = ""
      apiKeySaved = false
    }
  }

  private func saveKey() {
    let key = apiKeyText
    guard !key.isEmpty else { return }
    let status = KeychainStore.save(account: keychainKey, value: key)
    // Verify round-trip so we never show "Saved" when read would miss.
    let (roundTrip, readStatus) = KeychainStore.read(account: keychainKey)
    apiKeySaved = (status == errSecSuccess) && (roundTrip == key)
  }

  /// Mirror the active AI provider into the App Group's UserDefaults so
  /// the keyboard extension can read the user's choice (it doesn't have
  /// access to the main app's `UserDefaults.standard`). Cheap — fires
  /// only on settings open + when the user changes provider.
  private func mirrorProviderToAppGroup(_ raw: String) {
    let suite = UserDefaults(suiteName: "group.com.joevasquez.Quill")
    suite?.set(raw, forKey: QuillIOSSettingsKey.aiProvider)
  }

  // MARK: - AI Modes (built-in visibility)

  /// Built-in modes that can be toggled off — every case except `.off`
  /// (Raw is always available so the user can dictate without AI even
  /// when every other mode is hidden).
  private var builtInToggleableModes: [AIProcessingMode] {
    AIProcessingMode.allCases.filter { $0 != .off }
  }

  /// Per-mode binding — flipping it adds/removes the mode from the
  /// disabled set and persists. The pill bar in `ContentView` reads
  /// the same key and filters on render.
  private func builtInModeBinding(for mode: AIProcessingMode) -> Binding<Bool> {
    Binding(
      get: {
        !BuiltInModeVisibility.decode(disabledBuiltInModesData).contains(mode)
      },
      set: { isOn in
        var disabled = BuiltInModeVisibility.decode(disabledBuiltInModesData)
        if isOn {
          disabled.remove(mode)
        } else {
          disabled.insert(mode)
        }
        disabledBuiltInModesData = BuiltInModeVisibility.encode(disabled)
      }
    )
  }

  private func builtInModeIcon(_ mode: AIProcessingMode) -> String {
    switch mode {
    case .off: return "waveform"
    case .clean: return "sparkles"
    case .email: return "envelope"
    case .notes: return "list.bullet"
    case .message: return "bubble.left"
    case .code: return "chevron.left.forwardslash.chevron.right"
    }
  }

  private func builtInModeDescription(_ mode: AIProcessingMode) -> String {
    switch mode {
    case .off:
      return "Direct transcript — no AI processing."
    case .clean:
      return "Tighten phrasing, drop filler words, fix punctuation."
    case .email:
      return "Polished email body — greeting, sign-off, neutral tone."
    case .notes:
      return "Bullets and headings for meeting notes / structured capture."
    case .message:
      return "Casual tone for chat — Slack, iMessage, Discord."
    case .code:
      return "Tighten technical writing for code review or commit messages."
    }
  }


  // MARK: - Grouped sub-screens

  @ViewBuilder private var captureScreen: some View {
    Form {
        Section {
          Picker("Default mode", selection: $defaultCaptureModeRaw) {
            ForEach(QuillMode.homeOrder) { mode in
              Text(mode.label).tag(mode.rawValue)
            }
          }
          .pickerStyle(.segmented)
        } header: {
          Text("Capture")
        } footer: {
          Text("What a fresh capture starts in. Switching modes on the home rail updates this too, so Quill reopens in whatever you used last.")
        }
        Section("Transcription Model") {
          Picker("Model", selection: $selectedModel) {
            ForEach(availableModels, id: \.id) { model in
              VStack(alignment: .leading) {
                Text(model.name)
                Text(model.size).font(.caption).foregroundStyle(.secondary)
              }
              .tag(model.id)
            }
          }
          .pickerStyle(.navigationLink)

          Text("Models download on first use. Tiny is fastest and good enough for most voice notes.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section {
          Toggle("Inline voice commands", isOn: $voiceCommandsEnabled)
          Toggle("Auto-detect actions", isOn: $autoActionRouting)
        } header: {
          Text("Dictation")
        } footer: {
          Text("Voice commands convert phrases like \"period\" and \"new paragraph\" into punctuation as you dictate. Auto-detect actions routes dictations that sound like commands (\"remind me to…\", \"add to Todoist…\") to the agent instead of the note — the bolt button always runs actions regardless.")
        }
    }
    .navigationTitle("Capture & Dictation")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private var aiScreen: some View {
    Form {
        Section {
          Picker("Provider", selection: $aiProviderRaw) {
            ForEach(AIProvider.allCases, id: \.rawValue) { provider in
              Text(provider.displayName).tag(provider.rawValue)
            }
          }
        } header: {
          Text("AI Provider")
        } footer: {
          Text("Choose your AI mode on the main screen. The provider is used whenever a non-Raw mode is selected.")
        }
        Section {
          HStack {
            if isAPIKeyVisible {
              TextField("API Key", text: $apiKeyText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } else {
              SecureField("API Key", text: $apiKeyText)
            }
            Button {
              isAPIKeyVisible.toggle()
            } label: {
              Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
          }

          Button("Save Key") { saveKey() }
            .disabled(apiKeyText.isEmpty)

          if apiKeySaved {
            // Persistent success row — green checkmark disc + label —
            // so the saved state is a real, anchored UI element rather
            // than a transient flash floating in the white space.
            HStack(spacing: 10) {
              Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.green))
              VStack(alignment: .leading, spacing: 1) {
                Text("Saved to Keychain")
                  .font(.subheadline.weight(.semibold))
                Text("Encrypted on this device. Never sent except in API calls.")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
            .padding(.vertical, 4)
          }
        } header: {
          Text("\(currentProvider.displayName) API Key")
        } footer: {
          Text("Get an API key from \(currentProvider == .openAI ? "platform.openai.com" : "console.anthropic.com"). Stored securely in the device Keychain; never leaves your device except when you make an API call.")
        }
        Section {
          // Built-in mode toggles — turning one off hides it from the
          // pill bar on the main screen so the user only sees the
          // transformations they actually use.
          ForEach(builtInToggleableModes, id: \.rawValue) { mode in
            Toggle(isOn: builtInModeBinding(for: mode)) {
              VStack(alignment: .leading, spacing: 2) {
                // Explicit HStack rather than a Label: inside a Toggle's
                // label the icon and title were breaking onto separate
                // lines.
                HStack(spacing: 7) {
                  Image(systemName: builtInModeIcon(mode))
                    .font(.body)
                    .foregroundStyle(QuillDesign.brand.color())
                    .frame(width: 22)
                  Text(mode.displayName)
                    .font(.body)
                }
                Text(builtInModeDescription(mode))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }

          NavigationLink {
            CustomModesView()
          } label: {
            HStack {
              Label("Custom Modes", systemImage: "sparkles")
              Spacer()
              Text(customModeCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } header: {
          Text("AI Modes")
        } footer: {
          Text("Toggle the built-in modes you want in the pill bar on the home screen. Custom Modes lets you author your own — \"Clinical note\", \"VC update\", etc.")
        }
    }
    .navigationTitle("AI & Modes")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private var suggestionsScreen: some View {
    Form {
      suggestionsSection
    }
    .navigationTitle("Suggestions")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private var accountScreen: some View {
    Form {
        Section {
          NavigationLink {
            GoogleAccountView()
          } label: {
            HStack {
              Label("Google Account", systemImage: "globe")
              Spacer()
              Text(googleAccountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        } header: {
          Text("Accounts")
        } footer: {
          Text("Sign in once to enable Gmail and Google Calendar in Action mode. Optional — you can do this later or skip it entirely.")
        }
        if IOSGoogleOAuthClient.isAuthorized() {
          Section {
            Toggle(isOn: $cloudSyncEnabled) {
              Label("Sync to Cloud", systemImage: "icloud.and.arrow.up")
            }
            if cloudSyncEnabled {
              CloudSyncStatusRow()
            }
          } header: {
            Text("Cloud Sync")
          } footer: {
            Text("When on, your notes sync to Google Cloud so you can access them from your Mac and other devices. Requires a Google account.")
          }
        }
        Section {
          NavigationLink {
            OfflineQueueView()
          } label: {
            HStack {
              Label("Offline Queue", systemImage: "tray.full")
              Spacer()
              Text(offlineQueueLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } header: {
          Text("Offline")
        } footer: {
          Text("Actions you take while offline are saved here and retried automatically when you're back online.")
        }
    }
    .navigationTitle("Account & Sync")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private var aboutScreen: some View {
    Form {
        Section {
          Toggle(isOn: $crashReportingEnabled) {
            Label("Send anonymous crash reports", systemImage: "ladybug")
          }
          .onChange(of: crashReportingEnabled) { _, _ in
            // Re-run configure() so SentrySDK starts/stops to match the
            // new flag without a relaunch.
            ErrorMonitoring.configure()
          }
        } header: {
          Text("Privacy")
        } footer: {
          Text("Off by default. When on, Quill sends crash stack traces and OS version to Sentry — never your transcripts, audio, notes, photos, or contacts.")
        }
        Section {
          Button {
            // Flipping this flag triggers the
            // `.fullScreenCover` in `QuilliOSApp` to re-present
            // the onboarding flow.
            UserDefaults.standard.set(false, forKey: QuillIOSSettingsKey.hasCompletedOnboarding)
            dismiss()
          } label: {
            Label("Replay Tutorial", systemImage: "sparkle.magnifyingglass")
          }
        } footer: {
          Text("Re-runs the welcome walk-through.")
        }
        Section("About") {
          Label("Quill for iOS · v\(appVersionString)", systemImage: "info.circle")
            .font(.caption)
          Link("joevasquez.com", destination: URL(string: "https://joevasquez.com")!)
            .font(.caption)
        }
    }
    .navigationTitle("About & Privacy")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  SettingsView()

  

  

  

  

}
