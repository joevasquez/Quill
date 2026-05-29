import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct HotKeySectionView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Section("Hot Key") {
            let hotKey = store.hexSettings.hotkey
            let key = store.isSettingHotKey ? nil : hotKey.key
            let modifiers = store.isSettingHotKey ? store.currentModifiers : hotKey.modifiers

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recording")
                            .font(.subheadline.weight(.semibold))
                        Text("Hold this hotkey to start dictating, releasing to stop.")
                            .settingsCaption()
                    }
                } icon: {
                    Image(systemName: "mic.fill")
                }

                HStack {
                    Spacer()
                    HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingHotKey)
                        .animation(.spring(), value: key)
                        .animation(.spring(), value: modifiers)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.send(.startSettingHotKey)
                }

                if !store.isSettingHotKey,
                   hotKey.key == nil,
                   !hotKey.modifiers.isEmpty {
                    ModifierSideControls(
                        modifiers: hotKey.modifiers,
                        onSelect: { kind, side in
                            store.send(.setModifierSide(kind, side))
                        }
                    )
                    .transition(.opacity)
                }
            }

            CycleModeHotkeyRow(store: store)

            PasteLastTranscriptHotkeyRow(store: store)

            Label {
                Toggle(
                    "Enable double-tap lock",
                    isOn: Binding(
                        get: { store.hexSettings.doubleTapLockEnabled },
                        set: { store.send(.setDoubleTapLockEnabled($0)) }
                    )
                )
            } icon: {
                Image(systemName: "hand.tap")
            }

            // Double-tap only mode applies to key+modifier combinations.
            if hotKey.key != nil {
                Label {
                    Toggle(
                        "Use double-tap only",
                        isOn: Binding(
                            get: { store.hexSettings.useDoubleTapOnly },
                            set: { store.send(.setUseDoubleTapOnly($0)) }
                        )
                    )
                        .disabled(!store.hexSettings.doubleTapLockEnabled)
                } icon: {
                    Image(systemName: "hand.tap.fill")
                }
            }

            // Minimum key time (for modifier-only shortcuts)
            if store.hexSettings.hotkey.key == nil {
                Label {
                    Slider(
                        value: Binding(
                            get: { store.hexSettings.minimumKeyTime },
                            set: { store.send(.setMinimumKeyTime($0)) }
                        ),
                        in: 0.0 ... 2.0,
                        step: 0.1
                    ) {
                        Text("Ignore below \(store.hexSettings.minimumKeyTime, specifier: "%.1f")s")
                    }
                } icon: {
                    Image(systemName: "clock")
                }
            }
        }
        .enableInjection()
    }
}

private struct CycleModeHotkeyRow: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        let cycleHotkey = store.hexSettings.cycleModeHotkey

        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cycle Mode")
                        .font(.subheadline.weight(.semibold))
                    Text("Press this shortcut to cycle the HUD between Dictate, Edit, and Action.")
                        .settingsCaption()
                }
            } icon: {
                Image(systemName: "rectangle.3.group.fill")
            }

            let key = store.isSettingCycleModeHotkey ? nil : cycleHotkey?.key
            let modifiers = store.isSettingCycleModeHotkey ? store.currentCycleModeModifiers : (cycleHotkey?.modifiers ?? .init(modifiers: []))

            HStack {
                Spacer()
                ZStack {
                    HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingCycleModeHotkey)

                    if !store.isSettingCycleModeHotkey, cycleHotkey == nil {
                        Text("Not set")
                            .settingsCaption()
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.send(.startSettingCycleModeHotkey)
                }
                Spacer()
            }

            if store.isSettingCycleModeHotkey {
                Text("Use at least one modifier (⌘, ⌥, ⇧, ⌃) plus a key.")
                    .settingsCaption()
            } else if cycleHotkey != nil {
                Button {
                    store.send(.clearCycleModeHotkey)
                } label: {
                    Label("Clear shortcut", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .enableInjection()
    }
}

private struct ModifierSideControls: View {
    @ObserveInjection var inject
    var modifiers: Modifiers
    var onSelect: (Modifier.Kind, Modifier.Side) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(modifiers.kinds, id: \.self) { kind in
                if kind.supportsSideSelection {
                    let binding = Binding<Modifier.Side>(
                        get: { modifiers.side(for: kind) ?? .either },
                        set: { onSelect(kind, $0) }
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(kind.symbol) \(kind.displayName)")
                            .settingsCaption()

                        Picker("Modifier side", selection: binding) {
                            ForEach(Modifier.Side.allCases, id: \.self) { side in
                                Text(side.displayName)
                                    .tag(side)
                                    .disabled(!kind.supportsSideSelection && side != .either)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .enableInjection()
    }
}
