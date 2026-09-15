import ComposableArchitecture
import HexCore
import SwiftUI

struct AppearanceSectionView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Section {
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
      Text("Theme")
    } footer: {
      Text("Auto follows your Mac's system appearance. Recording mode colors remain recognizable in every theme.")
        .settingsCaption()
    }

    Section {
      Label {
        Picker("Style", selection: Binding(
          get: { store.hexSettings.displayMode },
          set: { store.send(.setDisplayMode($0)) }
        )) {
          ForEach(DisplayMode.allCases, id: \.self) { option in
            Text(option.label).tag(option)
          }
        }
        .pickerStyle(.menu)
      } icon: {
        Image(systemName: "circle.circle")
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
    } header: {
      Text("Recording Indicator")
    } footer: {
      Text("Choose how Quill appears while listening. Pinning keeps the floating indicator at the top of the screen.")
        .settingsCaption()
    }
  }
}
