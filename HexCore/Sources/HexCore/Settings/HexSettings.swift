#if os(macOS)
import Foundation

public enum RecordingAudioBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	case pauseMedia
	case mute
	case doNothing
}

public enum DisplayMode: String, Codable, CaseIterable, Equatable, Sendable {
	case hud
	case orb
	/// "Chip + Morph" — a compact frosted chip that shows the Quill
	/// feather at rest and morphs into a mode-hued orb while capturing,
	/// with a Corner Bloom transcript card. Designed to be minimal/quiet.
	case chip
}

/// App-wide light/dark override. `system` follows the OS. The AppKit
/// `NSAppearance` mapping lives in the app target (HexCore can't import
/// AppKit cross-platform). Mirrors the iOS `QuillAppearance` control.
public enum AppAppearance: String, Codable, CaseIterable, Equatable, Sendable {
	case system = ""
	case light
	case dark

	public var label: String {
		switch self {
		case .system: return "Auto"
		case .light: return "Light"
		case .dark: return "Dark"
		}
	}
}

/// User-configurable settings saved to disk.
public struct HexSettings: Codable, Equatable, Sendable {
	public static let defaultPasteLastTranscriptHotkey = HotKey(key: .v, modifiers: [.option, .shift])
	public static let baseSoundEffectsVolume: Double = HexCoreConstants.baseSoundEffectsVolume
	public static let defaultWordRemovals: [WordRemoval] = [
		.init(pattern: "uh+"),
		.init(pattern: "um+"),
		.init(pattern: "er+"),
		.init(pattern: "hm+")
	]

	public static var defaultPasteLastTranscriptHotkeyDescription: String {
		let modifiers = defaultPasteLastTranscriptHotkey.modifiers.sorted.map { $0.stringValue }.joined()
		let key = defaultPasteLastTranscriptHotkey.key?.toString ?? ""
		return modifiers + key
	}

	public var soundEffectsEnabled: Bool
	public var soundEffectsVolume: Double
	public var hotkey: HotKey
	public var openOnLogin: Bool
	public var showDockIcon: Bool
	public var selectedModel: String
	public var useClipboardPaste: Bool
	public var preventSystemSleep: Bool
	public var recordingAudioBehavior: RecordingAudioBehavior
	public var minimumKeyTime: Double
	public var copyToClipboard: Bool
	public var superFastModeEnabled: Bool
	public var useDoubleTapOnly: Bool
	public var doubleTapLockEnabled: Bool
	public var outputLanguage: String?
	public var selectedMicrophoneID: String?
	public var saveTranscriptionHistory: Bool
	public var maxHistoryEntries: Int?
	public var pasteLastTranscriptHotkey: HotKey?
	public var cycleModeHotkey: HotKey?
	public var hasCompletedModelBootstrap: Bool
	public var hasCompletedStorageMigration: Bool
	public var wordRemovalsEnabled: Bool
	public var wordRemovals: [WordRemoval]
	public var wordRemappings: [WordRemapping]

	// AI Processing
	public var aiProcessingEnabled: Bool
	public var aiProcessingMode: AIProcessingMode
	public var aiProvider: AIProvider
	public var contextAwareAutoMode: Bool
	public var appModeRules: [AppModeRule]
	public var voiceCommandsEnabled: Bool
	public var contextEnrichmentEnabled: Bool
	public var liveTranscriptEnabled: Bool
	/// User-defined AI post-processing modes. Complement the built-in
	/// `AIProcessingMode` cases — e.g. "Clinical note", "VC update",
	/// "Code review email". See `CustomAIMode` for the data shape.
	public var customAIModes: [CustomAIMode]
	/// When on, if text is already selected in the focused app when
	/// the user starts dictating, the dictation is treated as an
	/// *instruction* ("tighten 20%", "translate to Spanish") and the
	/// selected text is edited in-place via the LLM instead of being
	/// appended. Off by default — changes the dictation behavior
	/// enough that users should opt in.
	public var inlineEditEnabled: Bool
	/// Set to `true` once the user finishes (or skips through) the
	/// first-launch onboarding walk-through. Resetting it to `false`
	/// from Settings → General → "Replay Tutorial" re-enters the flow.
	public var hasCompletedOnboarding: Bool
	public var selectedPlan: String?
	public var cloudSyncEnabled: Bool
	public var hudPinnedToTop: Bool
	public var displayMode: DisplayMode
	public var appearance: AppAppearance
	public var appPasteDelays: [AppPasteDelay]
	/// The user-chosen name for their personal agent ("Hermes" by default).
	/// Used in Action-mode copy, the confirmation panel, and Settings.
	public var agentName: String
	/// User-connected MCP (Model Context Protocol) servers — each one's
	/// tools become invocable by the agent in Action mode. Auth tokens
	/// live in the keychain, not here.
	public var mcpServers: [MCPServerConfig]
	/// When on, Action-mode dictations feed a background memory-extraction
	/// pass so the agent learns people/projects/preferences over time.
	public var agentMemoryEnabled: Bool

	private mutating func normalizeDoubleTapSettings() {
		if !doubleTapLockEnabled {
			useDoubleTapOnly = false
		}
	}

	public init(
		soundEffectsEnabled: Bool = true,
		soundEffectsVolume: Double = HexSettings.baseSoundEffectsVolume,
		hotkey: HotKey = .init(key: nil, modifiers: [.option]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		selectedModel: String = ParakeetModel.multilingualV3.identifier,
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		recordingAudioBehavior: RecordingAudioBehavior = .doNothing,
		minimumKeyTime: Double = HexCoreConstants.defaultMinimumKeyTime,
		// Default changed from `false` → `true` in 0.8.5: leaving the
		// transcription in the clipboard is safer than restoring the
		// user's previous clipboard (which races the target app's
		// paste handler and can result in pasting sensitive content
		// like API keys when a paste completes late).
		copyToClipboard: Bool = true,
		superFastModeEnabled: Bool = false,
		useDoubleTapOnly: Bool = false,
		doubleTapLockEnabled: Bool = true,
		outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
		saveTranscriptionHistory: Bool = true,
		maxHistoryEntries: Int? = nil,
		pasteLastTranscriptHotkey: HotKey? = HexSettings.defaultPasteLastTranscriptHotkey,
		cycleModeHotkey: HotKey? = nil,
		hasCompletedModelBootstrap: Bool = false,
		hasCompletedStorageMigration: Bool = false,
		wordRemovalsEnabled: Bool = false,
		wordRemovals: [WordRemoval] = HexSettings.defaultWordRemovals,
		wordRemappings: [WordRemapping] = [],
		aiProcessingEnabled: Bool = false,
		aiProcessingMode: AIProcessingMode = .off,
		aiProvider: AIProvider = .openAI,
		contextAwareAutoMode: Bool = false,
		appModeRules: [AppModeRule] = [],
		voiceCommandsEnabled: Bool = false,
		contextEnrichmentEnabled: Bool = false,
		liveTranscriptEnabled: Bool = false,
		customAIModes: [CustomAIMode] = [],
		inlineEditEnabled: Bool = true,
		hasCompletedOnboarding: Bool = false,
		selectedPlan: String? = nil,
		cloudSyncEnabled: Bool = false,
		hudPinnedToTop: Bool = false,
		displayMode: DisplayMode = .hud,
		appearance: AppAppearance = .system,
		appPasteDelays: [AppPasteDelay] = AppPasteDelay.defaults,
		agentName: String = "Hermes",
		mcpServers: [MCPServerConfig] = [],
		agentMemoryEnabled: Bool = true
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.soundEffectsVolume = soundEffectsVolume
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.recordingAudioBehavior = recordingAudioBehavior
		self.minimumKeyTime = minimumKeyTime
		self.copyToClipboard = copyToClipboard
		self.superFastModeEnabled = superFastModeEnabled
		self.useDoubleTapOnly = useDoubleTapOnly
		self.doubleTapLockEnabled = doubleTapLockEnabled
		self.outputLanguage = outputLanguage
		self.selectedMicrophoneID = selectedMicrophoneID
		self.saveTranscriptionHistory = saveTranscriptionHistory
		self.maxHistoryEntries = maxHistoryEntries
		self.pasteLastTranscriptHotkey = pasteLastTranscriptHotkey
		self.cycleModeHotkey = cycleModeHotkey
		self.hasCompletedModelBootstrap = hasCompletedModelBootstrap
		self.hasCompletedStorageMigration = hasCompletedStorageMigration
		self.wordRemovalsEnabled = wordRemovalsEnabled
		self.wordRemovals = wordRemovals
		self.wordRemappings = wordRemappings
		self.aiProcessingEnabled = aiProcessingEnabled
		self.aiProcessingMode = aiProcessingMode
		self.aiProvider = aiProvider
		self.contextAwareAutoMode = contextAwareAutoMode
		self.appModeRules = appModeRules
		self.voiceCommandsEnabled = voiceCommandsEnabled
		self.contextEnrichmentEnabled = contextEnrichmentEnabled
		self.liveTranscriptEnabled = liveTranscriptEnabled
		self.customAIModes = customAIModes
		self.inlineEditEnabled = inlineEditEnabled
		self.hasCompletedOnboarding = hasCompletedOnboarding
		self.selectedPlan = selectedPlan
		self.cloudSyncEnabled = cloudSyncEnabled
		self.hudPinnedToTop = hudPinnedToTop
		self.displayMode = displayMode
		self.appearance = appearance
		self.appPasteDelays = appPasteDelays
		self.agentName = agentName
		self.mcpServers = mcpServers
		self.agentMemoryEnabled = agentMemoryEnabled
		normalizeDoubleTapSettings()
	}

	public init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.decode(into: &self, from: container)
		}
		normalizeDoubleTapSettings()
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.encode(self, into: &container)
		}
	}
}

// MARK: - Schema

private enum HexSettingKey: String, CodingKey, CaseIterable {
	case soundEffectsEnabled
	case soundEffectsVolume
	case hotkey
	case openOnLogin
	case showDockIcon
	case selectedModel
	case useClipboardPaste
	case preventSystemSleep
	case recordingAudioBehavior
	case pauseMediaOnRecord // Legacy
	case minimumKeyTime
	case copyToClipboard
	case superFastModeEnabled
	case useDoubleTapOnly
	case doubleTapLockEnabled
	case outputLanguage
	case selectedMicrophoneID
	case saveTranscriptionHistory
	case maxHistoryEntries
	case pasteLastTranscriptHotkey
	case cycleModeHotkey
	case hasCompletedModelBootstrap
	case hasCompletedStorageMigration
	case wordRemovalsEnabled
	case wordRemovals
	case wordRemappings
	case aiProcessingEnabled
	case aiProcessingMode
	case aiProvider
	case contextAwareAutoMode
	case appModeRules
	case voiceCommandsEnabled
	case contextEnrichmentEnabled
	case liveTranscriptEnabled
	case customAIModes
	case inlineEditEnabled
	case hasCompletedOnboarding
	case selectedPlan
	case cloudSyncEnabled
	case hudPinnedToTop
	case displayMode
	case appearance
	case appPasteDelays
	case agentName
	case mcpServers
	case agentMemoryEnabled
}

private struct SettingsField<Value: Codable & Sendable> {
	let key: HexSettingKey
	let keyPath: WritableKeyPath<HexSettings, Value>
	let defaultValue: Value
	let decodeStrategy: (KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value
	let encodeStrategy: (inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void

	init(
		_ key: HexSettingKey,
		keyPath: WritableKeyPath<HexSettings, Value>,
		default defaultValue: Value,
		decode: ((KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value)? = nil,
		encode: ((inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void)? = nil
	) {
		self.key = key
		self.keyPath = keyPath
		self.defaultValue = defaultValue
		self.decodeStrategy = decode ?? { container, key, defaultValue in
			try container.decodeIfPresent(Value.self, forKey: key) ?? defaultValue
		}
		self.encodeStrategy = encode ?? { container, key, value in
			try container.encode(value, forKey: key)
		}
	}

	func eraseToAny() -> AnySettingsField {
		AnySettingsField(
			key: key,
			decode: { container, settings in
				let value = try decodeStrategy(container, key, defaultValue)
				settings[keyPath: keyPath] = value
			},
			encode: { settings, container in
				let value = settings[keyPath: keyPath]
				try encodeStrategy(&container, key, value)
			}
		)
	}
}

private struct AnySettingsField {
	let key: HexSettingKey
	let decode: (KeyedDecodingContainer<HexSettingKey>, inout HexSettings) throws -> Void
	let encode: (HexSettings, inout KeyedEncodingContainer<HexSettingKey>) throws -> Void

	func decode(into settings: inout HexSettings, from container: KeyedDecodingContainer<HexSettingKey>) throws {
		try decode(container, &settings)
	}

	func encode(_ settings: HexSettings, into container: inout KeyedEncodingContainer<HexSettingKey>) throws {
		try encode(settings, &container)
	}
}

private enum HexSettingsSchema {
	static let defaults = HexSettings()

	nonisolated(unsafe) static let fields: [AnySettingsField] = [
		SettingsField(.soundEffectsEnabled, keyPath: \.soundEffectsEnabled, default: defaults.soundEffectsEnabled).eraseToAny(),
		SettingsField(.soundEffectsVolume, keyPath: \.soundEffectsVolume, default: defaults.soundEffectsVolume).eraseToAny(),
		SettingsField(.hotkey, keyPath: \.hotkey, default: defaults.hotkey).eraseToAny(),
		SettingsField(.openOnLogin, keyPath: \.openOnLogin, default: defaults.openOnLogin).eraseToAny(),
		SettingsField(.showDockIcon, keyPath: \.showDockIcon, default: defaults.showDockIcon).eraseToAny(),
		SettingsField(.selectedModel, keyPath: \.selectedModel, default: defaults.selectedModel).eraseToAny(),
		SettingsField(.useClipboardPaste, keyPath: \.useClipboardPaste, default: defaults.useClipboardPaste).eraseToAny(),
		SettingsField(.preventSystemSleep, keyPath: \.preventSystemSleep, default: defaults.preventSystemSleep).eraseToAny(),
		SettingsField(
			.recordingAudioBehavior,
			keyPath: \.recordingAudioBehavior,
			default: defaults.recordingAudioBehavior,
			decode: { container, key, defaultValue in
				if let value = try container.decodeIfPresent(RecordingAudioBehavior.self, forKey: key) {
					return value
				}
				if let legacyPause = try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) {
					return legacyPause ? .pauseMedia : .doNothing
				}
				return defaultValue
			}
		).eraseToAny(),
		SettingsField(.minimumKeyTime, keyPath: \.minimumKeyTime, default: defaults.minimumKeyTime).eraseToAny(),
		SettingsField(.copyToClipboard, keyPath: \.copyToClipboard, default: defaults.copyToClipboard).eraseToAny(),
		SettingsField(.superFastModeEnabled, keyPath: \.superFastModeEnabled, default: defaults.superFastModeEnabled).eraseToAny(),
		SettingsField(.useDoubleTapOnly, keyPath: \.useDoubleTapOnly, default: defaults.useDoubleTapOnly).eraseToAny(),
		SettingsField(.doubleTapLockEnabled, keyPath: \.doubleTapLockEnabled, default: defaults.doubleTapLockEnabled).eraseToAny(),
		SettingsField(
			.outputLanguage,
			keyPath: \.outputLanguage,
			default: defaults.outputLanguage,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.selectedMicrophoneID,
			keyPath: \.selectedMicrophoneID,
			default: defaults.selectedMicrophoneID,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.saveTranscriptionHistory, keyPath: \.saveTranscriptionHistory, default: defaults.saveTranscriptionHistory).eraseToAny(),
		SettingsField(
			.maxHistoryEntries,
			keyPath: \.maxHistoryEntries,
			default: defaults.maxHistoryEntries,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.pasteLastTranscriptHotkey,
			keyPath: \.pasteLastTranscriptHotkey,
			default: defaults.pasteLastTranscriptHotkey,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.cycleModeHotkey,
			keyPath: \.cycleModeHotkey,
			default: defaults.cycleModeHotkey,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.hasCompletedModelBootstrap, keyPath: \.hasCompletedModelBootstrap, default: defaults.hasCompletedModelBootstrap).eraseToAny(),
		SettingsField(.hasCompletedStorageMigration, keyPath: \.hasCompletedStorageMigration, default: defaults.hasCompletedStorageMigration).eraseToAny(),
		SettingsField(.wordRemovalsEnabled, keyPath: \.wordRemovalsEnabled, default: defaults.wordRemovalsEnabled).eraseToAny(),
		SettingsField(
			.wordRemovals,
			keyPath: \.wordRemovals,
			default: defaults.wordRemovals
		).eraseToAny(),
		SettingsField(
			.wordRemappings,
			keyPath: \.wordRemappings,
			default: defaults.wordRemappings
		).eraseToAny(),
		SettingsField(.aiProcessingEnabled, keyPath: \.aiProcessingEnabled, default: defaults.aiProcessingEnabled).eraseToAny(),
		SettingsField(.aiProcessingMode, keyPath: \.aiProcessingMode, default: defaults.aiProcessingMode).eraseToAny(),
		SettingsField(.aiProvider, keyPath: \.aiProvider, default: defaults.aiProvider).eraseToAny(),
		SettingsField(.contextAwareAutoMode, keyPath: \.contextAwareAutoMode, default: defaults.contextAwareAutoMode).eraseToAny(),
		SettingsField(.appModeRules, keyPath: \.appModeRules, default: defaults.appModeRules).eraseToAny(),
		SettingsField(.voiceCommandsEnabled, keyPath: \.voiceCommandsEnabled, default: defaults.voiceCommandsEnabled).eraseToAny(),
		SettingsField(.contextEnrichmentEnabled, keyPath: \.contextEnrichmentEnabled, default: defaults.contextEnrichmentEnabled).eraseToAny(),
		SettingsField(.liveTranscriptEnabled, keyPath: \.liveTranscriptEnabled, default: defaults.liveTranscriptEnabled).eraseToAny(),
		SettingsField(.customAIModes, keyPath: \.customAIModes, default: defaults.customAIModes).eraseToAny(),
		SettingsField(.inlineEditEnabled, keyPath: \.inlineEditEnabled, default: defaults.inlineEditEnabled).eraseToAny(),
		SettingsField(.hasCompletedOnboarding, keyPath: \.hasCompletedOnboarding, default: defaults.hasCompletedOnboarding).eraseToAny(),
		SettingsField(.selectedPlan, keyPath: \.selectedPlan, default: defaults.selectedPlan).eraseToAny(),
		SettingsField(.cloudSyncEnabled, keyPath: \.cloudSyncEnabled, default: defaults.cloudSyncEnabled).eraseToAny(),
		SettingsField(.hudPinnedToTop, keyPath: \.hudPinnedToTop, default: defaults.hudPinnedToTop).eraseToAny(),
		SettingsField(.displayMode, keyPath: \.displayMode, default: defaults.displayMode).eraseToAny(),
		SettingsField(.appearance, keyPath: \.appearance, default: defaults.appearance).eraseToAny(),
		SettingsField(.appPasteDelays, keyPath: \.appPasteDelays, default: defaults.appPasteDelays).eraseToAny(),
		SettingsField(.agentName, keyPath: \.agentName, default: defaults.agentName).eraseToAny(),
		SettingsField(.mcpServers, keyPath: \.mcpServers, default: defaults.mcpServers).eraseToAny(),
		SettingsField(.agentMemoryEnabled, keyPath: \.agentMemoryEnabled, default: defaults.agentMemoryEnabled).eraseToAny(),
	]
}

#endif
