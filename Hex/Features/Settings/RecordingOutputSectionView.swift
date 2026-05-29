import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Controls how a finished transcript reaches the user — clipboard
/// insertion vs. simulated keypresses, and whether to leave a copy on
/// the clipboard. Lives under the Recording tab next to the recording
/// behavior knobs; previously these were buried in the General catch-all.
struct RecordingOutputSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle(
					"Use clipboard to insert",
					isOn: Binding(
						get: { store.hexSettings.useClipboardPaste },
						set: { store.send(.setUseClipboardPaste($0)) }
					)
				)
				Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
			} icon: {
				Image(systemName: "doc.on.doc.fill")
			}

			Label {
				Toggle(
					"Copy to clipboard",
					isOn: Binding(
						get: { store.hexSettings.copyToClipboard },
						set: { store.send(.setCopyToClipboard($0)) }
					)
				)
				Text("Copy transcription text to clipboard in addition to pasting it")
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}
		} header: {
			Text("Output")
		}

		if store.hexSettings.useClipboardPaste {
			Section {
				ForEach(store.hexSettings.appPasteDelays) { rule in
					AppPasteDelayRow(
						rule: rule,
						onPickApp: { picked in
							store.send(.updateAppPasteDelay(.init(
								id: rule.id,
								bundleIdentifier: picked.bundleIdentifier,
								appName: picked.appName,
								delayMs: rule.delayMs,
								isEnabled: true
							)))
						},
						onDelayChange: { ms in
							var updated = rule
							updated.delayMs = ms
							store.send(.updateAppPasteDelay(updated))
						},
						onToggle: { enabled in
							var updated = rule
							updated.isEnabled = enabled
							store.send(.updateAppPasteDelay(updated))
						},
						onRemove: { store.send(.removeAppPasteDelay(rule.id)) }
					)
				}

				Button {
					store.send(.addAppPasteDelay)
				} label: {
					Label("Add app…", systemImage: "plus.circle")
				}
				.buttonStyle(.plain)
			} header: {
				Text("Clipboard paste delay")
			} footer: {
				Text("Add extra delay before Cmd+V for remote desktop apps (Citrix, RDP, VMware) where the clipboard syncs over the network.")
					.settingsCaption()
			}
		}
		EmptyView()
			.enableInjection()
	}
}

// MARK: - AppPasteDelayRow

struct AppPasteDelayRow: View {
	let rule: AppPasteDelay
	let onPickApp: (PickedApp) -> Void
	let onDelayChange: (Int) -> Void
	let onToggle: (Bool) -> Void
	let onRemove: () -> Void

	var body: some View {
		HStack(spacing: 10) {
			Toggle("", isOn: Binding(
				get: { rule.isEnabled },
				set: { onToggle($0) }
			))
			.labelsHidden()
			.toggleStyle(.switch)
			.controlSize(.mini)

			AppPickerButton(
				currentName: displayName,
				isEmpty: rule.bundleIdentifier.isEmpty,
				message: "Choose the app that needs a clipboard paste delay",
				onPick: onPickApp
			)

			Spacer(minLength: 8)

			Stepper(
				"\(rule.delayMs) ms",
				value: Binding(
					get: { rule.delayMs },
					set: { onDelayChange($0) }
				),
				in: 50...2000,
				step: 50
			)
			.frame(maxWidth: 130)

			Button(role: .destructive) {
				onRemove()
			} label: {
				Image(systemName: "trash")
			}
			.buttonStyle(.borderless)
			.help("Remove this app.")
		}
		.opacity(rule.isEnabled ? 1 : 0.5)
	}

	private var displayName: String {
		if !rule.appName.isEmpty { return rule.appName }
		if !rule.bundleIdentifier.isEmpty { return rule.bundleIdentifier }
		return "Pick app\u{2026}"
	}
}
