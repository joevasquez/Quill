import ComposableArchitecture
import HexCore
import SwiftUI

private let appLogger = HexLog.app
private let cacheLogger = HexLog.caches

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var hudPanel: HUDPanel?
	var actionPanel: ActionConfirmationPanel?
	var settingsWindow: NSWindow?
	/// Menu-bar presence: status item (feather icon, or the live Chip+Morph
	/// view in chip display mode), the app menu, and the Corner Bloom panel.
	var statusItemController: QuillStatusItemController?
	private var launchedAtLogin = false

	@Dependency(\.soundEffects) var soundEffect
	@Dependency(\.recording) var recording
	@Shared(.hexSettings) var hexSettings: HexSettings

	func applicationDidFinishLaunching(_: Notification) {
		DiagnosticsLogging.bootstrapIfNeeded()
		// Ensure Parakeet/FluidAudio caches live under Application Support, not ~/.cache
		configureLocalCaches()
		// Install the live error monitoring provider before any other code
		// can throw — captures during launch get reported. Sentry itself
		// stays inert until the user opts in via Settings → General.
		ErrorMonitoring.installLiveService(SentryErrorMonitoring())
		ErrorMonitoring.configure()
		// Install the offline action queue executor + parser + start
		// observing connectivity. The parser handles raw transcripts queued
		// when the LLM was unreachable; the executor handles already-parsed
		// intents queued when an integration adapter (Gmail, GCal, Todoist)
		// failed transiently.
		Task {
			await ActionQueueManager.shared.install(
				executor: SystemActionQueueExecutor(),
				parser: SystemActionQueueParser()
			)
		}
		if isTesting {
			appLogger.debug("Running in testing mode")
			return
		}

		Task {
			await soundEffect.preloadSounds()
			await soundEffect.setEnabled(hexSettings.soundEffectsEnabled)
		}
		launchedAtLogin = wasLaunchedAtLogin()
		appLogger.info("Application did finish launching")
		appLogger.notice("launchedAtLogin = \(self.launchedAtLogin)")

		// Set activation policy first
		updateAppMode()

		// Install the menu-bar status item (feather icon / live chip).
		statusItemController = QuillStatusItemController(
			store: HexApp.appStore,
			onOpenSettings: { [weak self] in self?.presentSettingsView() }
		)

		// Add notification observer
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: .updateAppMode,
			object: nil
		)

		// Apply the light/dark override now, and whenever it changes.
		applyAppearance()
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppearanceChange),
			name: .appearanceChanged,
			object: nil
		)

		// Sync Google integration state from OAuth keychain on launch
		syncGoogleIntegrationsFromOAuth()

		// Record app open and schedule analytics upload
		AnalyticsUploader.shared.recordAppOpen()

		// Warm the MCP tool catalog so Action-mode parsing can offer the
		// user's connected servers' tools without a blocking fetch.
		refreshMCPCatalog()

		// Start long-running app effects (global hotkeys, permissions, etc.)
		startLifecycleTasksIfNeeded()

		// Observe action confirmation requests from the transcription pipeline
		observeActionConfirmation()

		// Then present main views
		presentMainView()

		guard shouldOpenForegroundUIOnLaunch else {
			appLogger.notice("Suppressing foreground windows for login launch")
			return
		}

		presentSettingsView()
		NSApp.activate(ignoringOtherApps: true)
	}

	private var shouldOpenForegroundUIOnLaunch: Bool {
		!(launchedAtLogin && !hexSettings.showDockIcon)
	}

	@objc private func handleAppearanceChange() {
		applyAppearance()
	}

	/// Map the user's appearance override onto `NSApp.appearance`, which
	/// cascades to every window (Settings, Notes, HUD panels). `nil` hands
	/// the decision back to the system.
	private func applyAppearance() {
		let appearance: NSAppearance?
		switch hexSettings.appearance {
		case .system: appearance = nil
		case .light: appearance = NSAppearance(named: .aqua)
		case .dark: appearance = NSAppearance(named: .darkAqua)
		}
		NSApp.appearance = appearance
	}

	private func wasLaunchedAtLogin() -> Bool {
		guard let event = NSAppleEventManager.shared().currentAppleEvent else {
			return false
		}

		return event.eventID == AEEventID(kAEOpenApplication)
			&& event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
	}

	private func startLifecycleTasksIfNeeded() {
		Task { @MainActor in
			await HexApp.appStore.send(.task).finish()
		}
	}

	/// Sets XDG_CACHE_HOME so FluidAudio stores models under our app's
	/// Application Support folder, keeping everything in one place.
    private func configureLocalCaches() {
        do {
            let cache = try URL.hexApplicationSupport.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            setenv("XDG_CACHE_HOME", cache.path, 1)
            cacheLogger.info("XDG_CACHE_HOME set to \(cache.path)")
        } catch {
            cacheLogger.error("Failed to configure local caches: \(error.localizedDescription)")
        }
    }

	func presentMainView() {
		guard hudPanel == nil else { return }
		let transcriptionStore = HexApp.appStore.scope(
			state: \.transcription,
			action: \.transcription
		)
		let hudView = TranscriptionView(store: transcriptionStore)
		hudPanel = HUDPanel.hosting(hudView)
		if hexSettings.hudPinnedToTop {
			hudPanel?.setPinned(true)
		}
		hudPanel?.orderFrontRegardless()
	}

	func presentSettingsView() {
		if let settingsWindow = settingsWindow {
			settingsWindow.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let settingsView = AppView(store: HexApp.appStore)
		let settingsWindow = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 700, height: 700),
			styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		settingsWindow.titleVisibility = .visible
		settingsWindow.contentView = NSHostingView(rootView: settingsView)
		settingsWindow.isReleasedWhenClosed = false
		settingsWindow.center()
		settingsWindow.toolbarStyle = NSWindow.ToolbarStyle.unified
		settingsWindow.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		self.settingsWindow = settingsWindow
	}

	@objc private func handleAppModeUpdate() {
		Task {
			await updateAppMode()
		}
	}

	@MainActor
	private func updateAppMode() {
		appLogger.debug("showDockIcon = \(self.hexSettings.showDockIcon)")
		if self.hexSettings.showDockIcon {
			NSApp.setActivationPolicy(.regular)
		} else {
			NSApp.setActivationPolicy(.accessory)
		}
	}

	// MARK: - Google Integration Sync

	private func syncGoogleIntegrationsFromOAuth() {
		let key = IntegrationConnectionStore.userDefaultsKey
		let raw = UserDefaults.standard.data(forKey: key)
		var current = IntegrationConnectionStore.decode(raw)
		let hasGoogleEmail = UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey) != nil

		if hasGoogleEmail {
			let needsInsert = !current.contains(.gmail) || !current.contains(.googleCalendar)
			guard needsInsert else { return }
			current.insert(.gmail)
			current.insert(.googleCalendar)
			UserDefaults.standard.set(IntegrationConnectionStore.encode(current), forKey: key)
		} else {
			let needsRemove = current.contains(.gmail) || current.contains(.googleCalendar)
			guard needsRemove else { return }
			current.remove(.gmail)
			current.remove(.googleCalendar)
			UserDefaults.standard.set(IntegrationConnectionStore.encode(current), forKey: key)
		}
	}

	// MARK: - Action Confirmation

	private func observeActionConfirmation() {
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleActionConfirmation(_:)),
			name: .presentActionConfirmation,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleMultiActionConfirmation(_:)),
			name: .presentMultiActionConfirmation,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleActionExecuted),
			name: .actionConfirmationExecuted,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleActionCancelled),
			name: .actionConfirmationCancelled,
			object: nil
		)
	}

	@objc
	private func handleActionConfirmation(_ notification: Notification) {
		guard let intent = notification.userInfo?[ActionConfirmationNotification.intentKey] as? ActionIntent else {
			return
		}
		let rawTranscript = (notification.userInfo?[ActionConfirmationNotification.rawTranscriptKey] as? String) ?? ""
		Task { @MainActor [weak self] in
			self?.presentActionConfirmation(intent: intent, rawTranscript: rawTranscript)
		}
	}

	@objc
	private func handleMultiActionConfirmation(_ notification: Notification) {
		guard let intents = notification.userInfo?[ActionConfirmationNotification.intentsKey] as? [ActionIntent] else {
			return
		}
		let rawTranscript = (notification.userInfo?[ActionConfirmationNotification.rawTranscriptKey] as? String) ?? ""
		let autoExecute = (notification.userInfo?[ActionConfirmationNotification.autoExecuteKey] as? Bool) ?? false
		let sourceAppBundleID = notification.userInfo?[ActionConfirmationNotification.sourceAppBundleIDKey] as? String
		Task { @MainActor [weak self] in
			self?.presentMultiActionConfirmation(intents: intents, rawTranscript: rawTranscript, autoExecute: autoExecute, sourceAppBundleID: sourceAppBundleID)
		}
	}

	@MainActor
	func presentActionConfirmation(intent: ActionIntent, rawTranscript: String = "") {
		HexLog.action.info("Presenting action confirmation panel: \(intent.title, privacy: .private)")
		dismissActionPanel()

		let confirmationStore = Store(
			initialState: ActionConfirmationFeature.State(intent: intent, rawTranscript: rawTranscript)
		) {
			ActionConfirmationFeature()
		}

		let panel = ActionConfirmationPanel.hosting(
			ActionConfirmationView(store: confirmationStore)
		)
		panel.positionBelowStatusBar()
		panel.orderFrontRegardless()
		panel.makeKey()
		actionPanel = panel
		HexLog.action.info("Action panel ordered front at frame: \(NSStringFromRect(panel.frame), privacy: .public)")
	}

	@MainActor
	func presentMultiActionConfirmation(intents: [ActionIntent], rawTranscript: String = "", autoExecute: Bool = false, sourceAppBundleID: String? = nil) {
		HexLog.action.info("Presenting multi-action confirmation panel: \(intents.count, privacy: .public) actions")
		dismissActionPanel()

		let multiStore = Store(
			initialState: MultiActionConfirmationFeature.State(intents: intents, rawTranscript: rawTranscript, autoExecute: autoExecute, sourceAppBundleID: sourceAppBundleID)
		) {
			MultiActionConfirmationFeature()
		}

		let panel = ActionConfirmationPanel.hosting(
			MultiActionConfirmationView(store: multiStore)
		)
		panel.positionBelowStatusBar()
		panel.orderFrontRegardless()
		panel.makeKey()
		actionPanel = panel
		HexLog.action.info("Multi-action panel ordered front at frame: \(NSStringFromRect(panel.frame), privacy: .public)")
	}

	/// Best-effort tools/list against every enabled MCP server. Failures
	/// are logged and skipped — a dead server just contributes no tools.
	private func refreshMCPCatalog() {
		let servers = hexSettings.mcpServers.filter(\.isEnabled)
		guard !servers.isEmpty else { return }
		Task {
			for server in servers {
				let token = await MCPOAuthClient.resolveAuthToken(for: server)
				do {
					try await MCPToolCatalog.shared.refresh(server: server, authToken: token)
				} catch {
					HexLog.app.warning("MCP catalog refresh failed for \(server.name, privacy: .private): \(error.localizedDescription, privacy: .public)")
				}
			}
		}
	}

	@objc
	private func handleActionExecuted() {
		Task { @MainActor [weak self] in
			HexApp.appStore.send(.transcription(.actionExecuted))
			self?.dismissActionPanel()
		}
	}

	@objc
	private func handleActionCancelled() {
		Task { @MainActor [weak self] in
			HexApp.appStore.send(.transcription(.actionCancelled))
			self?.dismissActionPanel()
		}
	}

	@MainActor
	private func dismissActionPanel() {
		actionPanel?.orderOut(nil)
		actionPanel = nil
	}

	// MARK: - App lifecycle

	func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		presentSettingsView()
		return true
	}

	func applicationWillTerminate(_: Notification) {
		// Flush the note cache synchronously — the debounced write may be
		// mid-flight, and a Task here wouldn't outlive termination.
		MainActor.assumeIsolated {
			MacCloudSync.shared.persistLocalCacheNow()
		}
		Task {
			await recording.cleanup()
		}
	}
}
