//
//  AIProcessingSectionView.swift
//  Hex
//

import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

// MARK: - Custom mode editor (shared between inline and standalone use)

struct CustomModeEditorMac: View {
  @Environment(\.dismiss) private var dismiss
  let initial: CustomAIMode?
  let onSave: (CustomAIMode) -> Void

  @State private var name: String
  @State private var prompt: String
  @State private var icon: String

  init(initial: CustomAIMode?, onSave: @escaping (CustomAIMode) -> Void) {
    self.initial = initial
    self.onSave = onSave
    _name = State(initialValue: initial?.name ?? "")
    _prompt = State(initialValue: initial?.systemPrompt ?? "")
    _icon = State(initialValue: initial?.icon ?? "sparkles")
  }

  private let iconChoices = [
    "sparkles", "stethoscope", "briefcase", "doc.text",
    "list.bullet.clipboard", "envelope", "bubble.left.and.bubble.right",
    "chevron.left.forwardslash.chevron.right", "heart.text.square",
    "books.vertical", "brain", "wand.and.stars",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(initial == nil ? "New Custom Mode" : "Edit Custom Mode")
        .font(.title2.weight(.semibold))

      Form {
        TextField("Name", text: $name, prompt: Text("e.g. Clinical note, VC update"))
        Picker("Icon", selection: $icon) {
          ForEach(iconChoices, id: \.self) { name in
            Label(name, systemImage: name).tag(name)
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Transformation prompt")
            .font(.caption.weight(.semibold))
          TextEditor(text: $prompt)
            .frame(minHeight: 160)
            .font(.body)
            .border(Color.secondary.opacity(0.3))
          Text("Quill wraps your prompt in the standard safety preamble. Describe only the transformation you want — e.g. \"Rewrite as a clinical progress note in SOAP format. Preserve dates, medications, and dosages. Use past tense.\"")
            .settingsCaption()
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(minWidth: 540, minHeight: 420)
  }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func save() {
    let mode = CustomAIMode(
      id: initial?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      systemPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
      icon: icon,
      createdAt: initial?.createdAt ?? Date()
    )
    onSave(mode)
    dismiss()
  }
}

/// Renders the AI tab's grouped sections: the master toggle on top,
/// then Provider / Default Mode / Behavior subsections — each in its
/// own labeled `Section` so the AI tab reads as a scannable settings
/// hierarchy instead of a single long flat list.
struct AIProcessingSectionView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var apiKeyText: String = ""
  @State private var isAPIKeyVisible: Bool = false
  @State private var saveTask: Task<Void, Never>?
  @State private var editingCustomMode: CustomAIMode?
  @State private var showingNewCustomMode = false

  var body: some View {
    // Master toggle — always visible at the top of the tab.
    Section {
      Label {
        Toggle(
          "Enable AI Enhancement",
          isOn: Binding(
            get: { store.hexSettings.aiProcessingEnabled },
            set: { store.send(.setAIProcessingEnabled($0)) }
          )
        )
        Text("Process transcriptions through an AI model before pasting")
          .settingsCaption()
      } icon: {
        Image(systemName: "sparkles")
      }
    } header: {
      Text("AI Enhancement")
    }
    .enableInjection()

    if store.hexSettings.aiProcessingEnabled {
      providerSection
      formattingModesSection
      perAppOverridesSection
      behaviorSection
    }
  }

  // MARK: - Provider

  /// Where the AI request actually goes (OpenAI / Anthropic / …) plus
  /// the credential to authenticate it. Kept compact so users with the
  /// key already saved don't see a tall block.
  @ViewBuilder private var providerSection: some View {
    Section {
      Label {
        HStack {
          Text("AI Provider")
          Spacer()
          Picker("", selection: Binding(
            get: { store.hexSettings.aiProvider },
            set: { newProvider in
              store.send(.setAIProvider(newProvider))
              apiKeyText = ""
              store.send(.loadAPIKey(newProvider))
            }
          )) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
              Text(provider.displayName).tag(provider)
            }
          }
          .pickerStyle(.menu)
        }
      } icon: {
        Image(systemName: "cloud")
      }

      Label {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            if isAPIKeyVisible {
              TextField("API Key", text: $apiKeyText)
                .textFieldStyle(.roundedBorder)
            } else {
              SecureField("API Key", text: $apiKeyText)
                .textFieldStyle(.roundedBorder)
            }
            Button {
              isAPIKeyVisible.toggle()
            } label: {
              Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
          }
          if store.apiKeySaved {
            Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.green)
              .transition(.opacity)
          } else {
            Text("Your API key is stored securely in the macOS Keychain")
              .settingsCaption()
          }
        }
      } icon: {
        Image(systemName: "key")
      }
      .onAppear {
        // Populate the text field from the already-loaded key (loaded
        // once in SettingsFeature.task). Only re-read from keychain if
        // the provider changed and the cached key is stale.
        if !store.loadedAPIKey.isEmpty && apiKeyText.isEmpty {
          apiKeyText = store.loadedAPIKey
        } else if apiKeyText.isEmpty {
          store.send(.loadAPIKey(store.hexSettings.aiProvider))
        }
      }
      .onChange(of: store.loadedAPIKey) { _, newValue in
        if !newValue.isEmpty && apiKeyText.isEmpty {
          apiKeyText = newValue
        }
      }
      .onChange(of: apiKeyText) { _, newValue in
        autoSaveAPIKey(newValue)
      }
    } header: {
      Text("Provider")
    }
  }

  // MARK: - Formatting Modes

  /// Unified section covering both built-in modes (clean, email, notes,
  /// message, code) and user-authored custom modes. The default-mode
  /// picker sits on top, followed by the auto-select toggle, then the
  /// user's custom modes library with edit / delete / create controls.
  @ViewBuilder private var formattingModesSection: some View {
    Section {
      Label {
        HStack {
          Text("Default Mode")
          Spacer()
          Picker("", selection: Binding(
            get: { store.hexSettings.aiProcessingMode },
            set: { store.send(.setAIProcessingMode($0)) }
          )) {
            ForEach(AIProcessingMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .pickerStyle(.menu)
        }
      } icon: {
        Image(systemName: "text.badge.star")
      }

      if store.hexSettings.aiProcessingMode != .off {
        Text(store.hexSettings.aiProcessingMode.description)
          .settingsCaption()
          .padding(.leading, 32)
      }

      Label {
        Toggle(
          "Auto-select mode by app",
          isOn: Binding(
            get: { store.hexSettings.contextAwareAutoMode },
            set: { store.send(.setContextAwareAutoMode($0)) }
          )
        )
        Text("Automatically choose AI mode based on the active application (e.g., Mail → Email, Slack → Message)")
          .settingsCaption()
      } icon: {
        Image(systemName: "app.badge")
      }

      // Custom modes inline
      let modes = store.hexSettings.customAIModes
      if !modes.isEmpty {
        Divider()
        ForEach(modes) { mode in
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: mode.icon)
              .foregroundStyle(.purple)
              .frame(width: 22, height: 22)
              .background(Circle().fill(Color.purple.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
              Text(mode.displayName)
                .font(.body.weight(.semibold))
              Text(mode.systemPrompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
            Button("Edit") { editingCustomMode = mode }
              .controlSize(.small)
            Button(role: .destructive) {
              store.send(.removeCustomAIMode(mode.id))
            } label: {
              Image(systemName: "trash")
            }
            .controlSize(.small)
          }
          .padding(.vertical, 4)
        }
      }

      Button {
        showingNewCustomMode = true
      } label: {
        Label("New Custom Mode…", systemImage: "plus.circle")
      }
      .controlSize(.small)
    } header: {
      Text("Formatting Modes")
    } footer: {
      Text("Custom modes appear alongside built-ins in the mode picker. Quill wraps your prompt in the standard safety preamble automatically.")
        .settingsCaption()
    }
    .sheet(isPresented: $showingNewCustomMode) {
      CustomModeEditorMac(initial: nil) { newMode in
        store.send(.addCustomAIMode(newMode))
      }
    }
    .sheet(item: $editingCustomMode) { mode in
      CustomModeEditorMac(initial: mode) { updated in
        store.send(.updateCustomAIMode(updated))
      }
    }
  }

  // MARK: - Per-app overrides

  /// User-managed list of "when I'm in <App>, use <Mode>" rules.
  /// Sits below the built-in "Auto-select mode by app" toggle and
  /// the default-mode picker — overrides win over both. Each rule is
  /// rendered as a row with an app picker (NSOpenPanel-driven) and
  /// a mode picker. Empty list shows a helpful empty-state row.
  @ViewBuilder private var perAppOverridesSection: some View {
    Section {
      if store.hexSettings.appModeRules.isEmpty {
        Label {
          VStack(alignment: .leading, spacing: 4) {
            Text("No per-app overrides yet")
              .foregroundStyle(.secondary)
            Text("Add a rule below to use a different AI mode in specific apps. Overrides beat both the default and the auto-select toggle.")
              .settingsCaption()
          }
        } icon: {
          Image(systemName: "app.dashed")
        }
      } else {
        ForEach(store.hexSettings.appModeRules) { rule in
          AppModeRuleRow(
            rule: rule,
            onPickApp: { picked in
              store.send(.updateAppModeRule(.init(
                id: rule.id,
                bundleIdentifier: picked.bundleIdentifier,
                appName: picked.appName,
                mode: rule.mode
              )))
            },
            onModeChange: { mode in
              store.send(.updateAppModeRule(.init(
                id: rule.id,
                bundleIdentifier: rule.bundleIdentifier,
                appName: rule.appName,
                mode: mode
              )))
            },
            onRemove: { store.send(.removeAppModeRule(rule.id)) }
          )
        }
      }

      Button {
        store.send(.addAppModeRule)
      } label: {
        Label("Add rule…", systemImage: "plus.circle")
      }
      .buttonStyle(.plain)
    } header: {
      Text("Per-app overrides")
    } footer: {
      Text("Pick an app and the AI mode Quill should use whenever you dictate while it's frontmost.")
        .settingsCaption()
    }
  }

  // MARK: - Behavior

  /// Cross-cutting AI behavior knobs that don't pick a mode or a
  /// provider — context awareness, voice commands, inline edit, and
  /// the placeholder for the streaming-transcript feature.
  @ViewBuilder private var behaviorSection: some View {
    Section {
      Label {
        Toggle(
          "Use app context to enrich results",
          isOn: Binding(
            get: { store.hexSettings.contextEnrichmentEnabled },
            set: { store.send(.setContextEnrichmentEnabled($0)) }
          )
        )
        Text("Read selected/surrounding text from the active app to improve AI formatting and tone (requires Accessibility permission)")
          .settingsCaption()
      } icon: {
        Image(systemName: "text.magnifyingglass")
      }

      Label {
        Toggle(
          "Voice Commands",
          isOn: Binding(
            get: { store.hexSettings.voiceCommandsEnabled },
            set: { store.send(.setVoiceCommandsEnabled($0)) }
          )
        )
        if store.hexSettings.voiceCommandsEnabled {
          Text("Inline: \"period\", \"comma\", \"question mark\", \"colon\", \"new paragraph\", \"new line\" become punctuation / breaks mid-sentence. Standalone: say \"select all\", \"undo\", or \"redo\" alone to trigger the editor command.")
            .settingsCaption()
        }
      } icon: {
        Image(systemName: "mic.badge.plus")
      }

      Label {
        Toggle(
          "Inline Edit (edit selected text with voice)",
          isOn: Binding(
            get: { store.hexSettings.inlineEditEnabled },
            set: { store.send(.setInlineEditEnabled($0)) }
          )
        )
        if store.hexSettings.inlineEditEnabled {
          Text("When text is selected in the focused app, your next dictation is treated as an edit instruction and applied to the selection. Try: \"tighten 20%\", \"make it warmer\", \"convert to bullets\", \"translate to Spanish\".")
            .settingsCaption()
        } else {
          Text("Off: all dictations paste as new content (current behavior).")
            .settingsCaption()
        }
      } icon: {
        Image(systemName: "text.cursor")
      }

    } header: {
      Text("Behavior")
    }
  }

  // MARK: - Auto-save

  private func autoSaveAPIKey(_ key: String) {
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      store.send(.saveAPIKey(key, forProvider: store.hexSettings.aiProvider))
    }
  }
}

// MARK: - AppModeRuleRow

/// Single row in the per-app overrides list. Pick app via NSOpenPanel
/// (so users can target apps by clicking them in /Applications instead
/// of typing bundle identifiers), pick mode via a menu, remove with a
/// red trash button. Kept as a separate view so the row layout doesn't
/// crowd the section view above it.
struct AppModeRuleRow: View {
  let rule: AppModeRule
  let onPickApp: (PickedApp) -> Void
  let onModeChange: (AIProcessingMode) -> Void
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      AppPickerButton(
        currentName: displayName,
        isEmpty: rule.bundleIdentifier.isEmpty,
        message: "Choose the app this rule should apply to",
        onPick: onPickApp
      )

      Spacer(minLength: 8)

      Picker(
        "",
        selection: Binding(
          get: { rule.mode },
          set: { onModeChange($0) }
        )
      ) {
        ForEach(AIProcessingMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(maxWidth: 140)

      Button(role: .destructive) {
        onRemove()
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Remove this rule.")
    }
  }

  private var displayName: String {
    if !rule.appName.isEmpty { return rule.appName }
    if !rule.bundleIdentifier.isEmpty { return rule.bundleIdentifier }
    return "Pick app\u{2026}"
  }
}
