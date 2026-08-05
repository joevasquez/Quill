//
//  CustomModesSectionView.swift
//  Hex (macOS)
//
//  Settings UI for managing user-authored AI post-processing modes.
//  Custom modes are now displayed inline in the Formatting Modes section
//  of the AI tab (see AIProcessingSectionView). This file is retained
//  for backward compatibility but the standalone section view is no
//  longer used in the settings hierarchy.
//

import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct CustomModesSectionView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  @State private var editing: CustomAIMode?
  @State private var showingNew = false

  var body: some View {
    Form {
      Section {
        let modes = store.hexSettings.customAIModes
        if modes.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("No custom modes yet.")
              .foregroundStyle(.secondary)
            Text("Create a mode to pair a name with a prompt — for the long tail of transforms Quill doesn't ship by default (Clinical note, VC update, Code review email, etc.).")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        } else {
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
              Button("Edit") { editing = mode }
                .controlSize(.small)
              Button(role: .destructive) {
                store.send(.removeCustomAIMode(mode.id))
              } label: {
                Image(systemName: "trash")
              }
              .controlSize(.small)
              .accessibilityLabel("Delete mode \(mode.name)")
            }
            .padding(.vertical, 4)
          }
        }

        Button {
          showingNew = true
        } label: {
          Label("New Mode…", systemImage: "plus.circle")
        }
        .controlSize(.small)
      } header: {
        Text("Custom AI Modes")
      } footer: {
        Text("Custom modes appear alongside built-ins in the mode picker. Quill wraps your prompt in the standard safety preamble automatically.")
          .settingsCaption()
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showingNew) {
      CustomModeEditorMac(initial: nil) { newMode in
        store.send(.addCustomAIMode(newMode))
      }
    }
    .sheet(item: $editing) { mode in
      CustomModeEditorMac(initial: mode) { updated in
        store.send(.updateCustomAIMode(updated))
      }
    }
    .enableInjection()
  }
}
