//
//  QuillIOSSettings.swift
//  Quill (iOS)
//
//  Settings keys used via @AppStorage in views. Values persist to UserDefaults.
//

import Foundation
import HexCore

enum QuillIOSSettingsKey {
  static let selectedModel = "quill.selectedModel"
  static let aiProcessingMode = "quill.aiProcessingMode"
  static let aiProvider = "quill.aiProvider"
  /// When true, inline phrases like "period", "comma", "new paragraph",
  /// etc. are substituted into punctuation / line breaks before AI
  /// post-processing runs. Mirrors the macOS `voiceCommandsEnabled`
  /// HexSettings flag.
  static let voiceCommandsEnabled = "quill.voiceCommandsEnabled"
  /// Set to `true` once the user finishes (or skips through) the
  /// first-launch walk-through in `OnboardingView`. Toggle back to
  /// `false` from Settings → Productivity → Replay Tutorial to
  /// re-enter the flow.
  static let hasCompletedOnboarding = "quill.hasCompletedOnboarding"
  static let selectedPlan = "quill.selectedPlan"

  /// JSON-encoded `[String]` of `AIProcessingMode.rawValue`s the user
  /// has hidden from the home-screen pill bar. Off (raw transcript) is
  /// always shown — only built-in transformations are toggleable.
  /// Empty array (the default) means everything is visible.
  static let disabledBuiltInModes = "quill.disabledBuiltInModes"

  /// User-renameable agent name ("Hermes" by default) — mirrors macOS
  /// `HexSettings.agentName`.
  static let agentName = "quill.agentName"
  /// When true, a background memory-extraction pass runs after every
  /// successful Action parse so "email Mike" resolves without questions.
  /// Mirrors macOS `HexSettings.agentMemoryEnabled`.
  static let agentMemoryEnabled = "quill.agentMemoryEnabled"
  /// When true (default), mic-button dictations that sound like commands
  /// ("remind me…", "add to todoist…") are routed to the agent's action
  /// pipeline instead of the note — the iOS counterpart of macOS Auto
  /// mode. The bolt FAB always forces Action regardless.
  static let autoActionRouting = "quill.autoActionRouting"

  // Defaults
  static let defaultModel = "openai_whisper-tiny.en"  // Ships small, English-focused
  // AI defaults to .off so users see raw transcripts until they pick a mode.
  static let defaultMode = "off"
  static let defaultProvider = "anthropic"
  /// On by default — most users dictate naturally and expect "period"
  /// to become a `.` rather than the literal word.
  static let defaultVoiceCommandsEnabled = true
  static let defaultAgentName = "Hermes"
  static let defaultAgentMemoryEnabled = true
  static let defaultAutoActionRouting = true
}

extension AIProvider {
  /// True when the user has saved an API key for this provider in the
  /// device Keychain. Used by `QuillModeDropdown` to decide which modes
  /// to grey out and by callers that want to short-circuit before
  /// actually invoking the LLM.
  var hasAPIKey: Bool {
    let account: String
    switch self {
    case .anthropic: account = KeychainKey.anthropicAPIKey
    case .openAI: account = KeychainKey.openAIAPIKey
    }
    let (key, _) = KeychainStore.read(account: account)
    guard let key, !key.isEmpty else { return false }
    return true
  }
}

extension AIProcessingMode {
  /// User-facing label for the iOS app. We show "Direct" instead of the
  /// platform-neutral "Off" / "Raw" — clearer about what the mode does
  /// (no transformation; dictation goes straight through) without
  /// implying a state ("recording is off").
  var iosDisplayName: String {
    self == .off ? "Direct" : displayName
  }

  /// SF Symbol used in the iOS pill / dropdown row.
  var iosIconName: String {
    switch self {
    case .off: return "waveform"
    case .clean: return "sparkles"
    case .email: return "envelope"
    case .notes: return "list.bullet"
    case .message: return "bubble.left"
    case .code: return "chevron.left.forwardslash.chevron.right"
    }
  }

  /// Whether this mode requires an LLM API call to function. `.off` is
  /// the only mode that doesn't — used by the dropdown to gate non-Off
  /// modes when the user hasn't configured an API key yet.
  var requiresAPIKey: Bool { self != .off }
}

/// Encodes / decodes the set of built-in AI modes the user has hidden
/// from the home-screen pill bar. Stored as JSON `[String]` in
/// UserDefaults under `QuillIOSSettingsKey.disabledBuiltInModes`.
///
/// Only built-in `AIProcessingMode` cases other than `.off` are
/// toggleable — Off is always shown so the user can fall back to a
/// raw transcript without rummaging in Settings.
enum BuiltInModeVisibility {
  static func decode(_ data: Data) -> Set<AIProcessingMode> {
    guard !data.isEmpty,
          let raw = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return Set(raw.compactMap { AIProcessingMode(rawValue: $0) })
  }

  static func encode(_ modes: Set<AIProcessingMode>) -> Data {
    (try? JSONEncoder().encode(modes.map(\.rawValue))) ?? Data()
  }
}
