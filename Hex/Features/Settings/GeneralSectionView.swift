import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct GeneralSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	/// Privacy-first default: opt-in. Stored under the same UserDefaults
	/// key the live `SentryErrorMonitoring` adapter reads, so toggling
	/// here directly gates capture (after the next `configure()` call).
	@AppStorage(ErrorMonitoringSettings.crashReportingEnabledKey)
	private var crashReportingEnabled: Bool = false

	@State private var showResetConfirmation = false

	var body: some View {
		Section {
			Label {
				Toggle("Open on Login",
				       isOn: Binding(
				       	get: { store.hexSettings.openOnLogin },
				       	set: { store.send(.toggleOpenOnLogin($0)) }
				       ))
			} icon: {
				Image(systemName: "arrow.right.circle")
			}

			Label {
				Toggle(
					"Show Dock Icon",
					isOn: Binding(
						get: { store.hexSettings.showDockIcon },
						set: { store.send(.toggleShowDockIcon($0)) }
					)
				)
			} icon: {
				Image(systemName: "dock.rectangle")
			}

			Label {
				Toggle(
					"Pin HUD to Top",
					isOn: Binding(
						get: { store.hexSettings.hudPinnedToTop },
						set: { store.send(.toggleHudPinnedToTop($0)) }
					)
				)
			} icon: {
				Image(systemName: "pin")
			}

			Label {
				Picker("Display Mode", selection: Binding(
					get: { store.hexSettings.displayMode },
					set: { store.send(.setDisplayMode($0)) }
				)) {
					Text("Standard HUD").tag(DisplayMode.hud)
					Text("Orb").tag(DisplayMode.orb)
					Text("Chip").tag(DisplayMode.chip)
				}
				.pickerStyle(.segmented)
			} icon: {
				Image(systemName: "circle.circle")
			}

			Label {
				Picker("Appearance", selection: Binding(
					get: { store.hexSettings.appearance },
					set: { store.send(.setAppearance($0)) }
				)) {
					ForEach(AppAppearance.allCases, id: \.self) { option in
						Text(option.label).tag(option)
					}
				}
				.pickerStyle(.segmented)
			} icon: {
				Image(systemName: "circle.lefthalf.filled")
			}
		} header: {
			Text("App")
		} footer: {
			Text("Auto follows your Mac's system setting. The orb keeps its mode colors in both themes.")
		}

		Section {
			Label {
				VStack(alignment: .leading, spacing: 6) {
					HStack {
						Text("Quill Pro")
							.fontWeight(.medium)
						Spacer()
						if store.hexSettings.selectedPlan == "pro" {
							Text("Active")
								.font(.caption)
								.foregroundStyle(.white)
								.padding(.horizontal, 8)
								.padding(.vertical, 3)
								.background(Capsule().fill(Color.purple.gradient))
						}
					}
					Toggle(
						"Enable Pro features",
						isOn: Binding(
							get: { store.hexSettings.selectedPlan == "pro" },
							set: { enabled in
								store.send(.setSelectedPlan(enabled ? "pro" : nil))
							}
						)
					)
					if store.hexSettings.selectedPlan == "pro" {
						Text("AI Enhancement powered by Anthropic Claude — no API key needed. Requires Google sign-in.")
							.settingsCaption()
					} else {
						Text("Enable to use AI features without your own API key")
							.settingsCaption()
					}
				}
			} icon: {
				Image(systemName: "crown")
					.foregroundStyle(store.hexSettings.selectedPlan == "pro" ? .purple : .secondary)
			}
		} header: {
			Text("Plan")
		}

		Section {
			Label {
				Toggle("Send anonymous crash reports", isOn: $crashReportingEnabled)
					.onChange(of: crashReportingEnabled) { _, _ in
						// Re-run configure() so SentrySDK starts/stops to
						// match the new flag without a relaunch.
						ErrorMonitoring.configure()
					}
			} icon: {
				Image(systemName: "ladybug")
			}
		} header: {
			Text("Privacy")
		} footer: {
			Text("Off by default. When on, Quill sends crash stack traces and OS version to Sentry — never your transcripts, audio, notes, or contacts. Helps Joe diagnose problems you can't easily reproduce.")
				.settingsCaption()
		}

		Section {
			Button {
				store.send(.exportSettings)
			} label: {
				Label("Export Settings…", systemImage: "square.and.arrow.up")
			}

			Button {
				store.send(.importSettings)
			} label: {
				Label("Import Settings…", systemImage: "square.and.arrow.down")
			}

			Button(role: .destructive) {
				showResetConfirmation = true
			} label: {
				Label("Reset All Settings to Defaults", systemImage: "arrow.counterclockwise")
			}
			.alert("Reset Settings?", isPresented: $showResetConfirmation) {
				Button("Cancel", role: .cancel) {}
				Button("Reset", role: .destructive) {
					store.send(.resetToDefaults)
				}
			} message: {
				Text("This will reset all settings to their defaults. Your API keys and transcription history will be preserved.")
			}
		} header: {
			Text("Data")
		} footer: {
			Text("Export saves your current settings as JSON. Import loads settings from a file. Reset restores defaults. API keys are never included in exports.")
				.settingsCaption()
		}
		.enableInjection()
	}
}
