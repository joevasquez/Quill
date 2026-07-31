//
//  QuillIOSSettings.swift
//  Quill (iOS)
//
//  Settings keys used via @AppStorage in views. Values persist to UserDefaults.
//

import Foundation
import HexCore
import SwiftUI

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

  /// The `QuillMode` a fresh capture starts in. The live mode is transient
  /// (the rail can change it per-capture); this is only the seed.
  static let defaultCaptureMode = "quill.defaultCaptureMode"

  /// Theme override. Empty string = follow the device.
  static let appearance = "quill.appearance"

  /// JSON-encoded `[String: Int]` of Edit-command usage counts, so the
  /// commands the user actually reaches for float to the front of the
  /// chip row.
  static let editCommandUsage = "quill.editCommandUsage"

  /// Master toggle for proactive suggestions (Pro). On by default — the
  /// feature is additionally gated on the Pro plan, so the toggle only
  /// matters once Pro is active.
  static let suggestionsEnabled = "quill.suggestionsEnabled"
  /// JSON-encoded `[String: Bool]` of per-source opt-in OVERRIDES keyed by
  /// `SuggestionSource.rawValue`. Absent key → the source's
  /// `enabledByDefault` (everything on except Reminders).
  static let suggestionSourcePrefs = "quill.suggestionSources"

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
  /// Auto is the default: it's the mode that decides for you, and it wears
  /// the brand colour.
  static let defaultCaptureModeValue = QuillMode.auto.rawValue
}

/// The user's theme choice. The control is three-way even though the design
/// handoff drew a two-way Light/Dark toggle — its own footer says "Auto
/// follows your device", and following the device is the right default.
enum QuillAppearance: String, CaseIterable, Identifiable {
  case system = ""
  case light
  case dark

  var id: String { rawValue }

  var label: String {
    switch self {
    case .system: "Auto"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  /// `nil` hands the decision back to the system.
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

/// Per-command usage counts for the Edit chip row, persisted as JSON in
/// UserDefaults. Kept tiny and local — it's a convenience, not a profile.
enum EditCommandUsage {
  static func decode(_ data: Data) -> [String: Int] {
    guard !data.isEmpty,
          let counts = try? JSONDecoder().decode([String: Int].self, from: data)
    else { return [:] }
    return counts
  }

  static func encode(_ counts: [String: Int]) -> Data {
    (try? JSONEncoder().encode(counts)) ?? Data()
  }

  /// The `limit` most-used commands, most-used first. Ties break
  /// alphabetically so the row doesn't reshuffle on every render.
  static func mostUsed(_ counts: [String: Int], limit: Int = 3) -> [String] {
    counts
      .sorted { a, b in
        a.value == b.value ? a.key < b.key : a.value > b.value
      }
      .prefix(limit)
      .map(\.key)
  }
}

/// Per-source opt-in overrides for proactive suggestions, persisted as
/// JSON `[String: Bool]` under `QuillIOSSettingsKey.suggestionSourcePrefs`.
/// Only overrides are stored — a missing key falls back to the source's
/// `enabledByDefault`.
enum SuggestionSourcePrefs {
  static func decode(_ data: Data) -> [String: Bool] {
    guard !data.isEmpty,
          let overrides = try? JSONDecoder().decode([String: Bool].self, from: data)
    else { return [:] }
    return overrides
  }

  static func encode(_ overrides: [String: Bool]) -> Data {
    (try? JSONEncoder().encode(overrides)) ?? Data()
  }

  static func isEnabled(_ source: SuggestionSource, overrides: [String: Bool]) -> Bool {
    overrides[source.rawValue] ?? source.enabledByDefault
  }
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
