//
//  AdvancedSettings.swift
//  Quill (macOS)
//
//  Progressive disclosure for the settings window. A large share of the
//  controls are expert knobs — per-app clipboard paste delays for VDI,
//  modifier-side pickers, word remappings, settings export/import — that
//  solve real problems for a few users while adding noise for everyone
//  else. They stay one click away instead of always-visible.
//
//  One shared preference so the choice is global: flip it once and every
//  tab reveals its advanced content.
//

import SwiftUI

enum AdvancedSettings {
  static let defaultsKey = "quill.settings.showAdvanced"
}

/// The reveal control, placed at the bottom of any tab that hides
/// advanced content.
struct AdvancedSettingsToggle: View {
  @AppStorage(AdvancedSettings.defaultsKey) private var showAdvanced = false

  /// One-line summary of what's behind the toggle, so it isn't a mystery
  /// box (e.g. "clipboard behavior, word corrections").
  var summary: String

  var body: some View {
    Section {
      Toggle(isOn: $showAdvanced.animation(.easeInOut(duration: 0.18))) {
        Label("Show advanced settings", systemImage: "gearshape.2")
      }
    } footer: {
      Text(showAdvanced ? "Applies to every tab." : summary)
        .settingsCaption()
    }
  }
}
