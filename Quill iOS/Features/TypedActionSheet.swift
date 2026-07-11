//
//  TypedActionSheet.swift
//  Quill (iOS)
//
//  Type-a-command entry point — the quiet-room sibling of the mic.
//  Whatever is typed runs through the exact same agent pipeline as a
//  spoken action (routine triggers, memory, MCP tools, confirmation
//  sheet). Opened from the keyboard button in the FAB fan.
//

import HexCore
import SwiftUI

struct TypedActionSheet: View {
  /// Called with the command text; the owner runs it through the agent.
  var onSubmit: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @FocusState private var focused: Bool
  @AppStorage(QuillIOSSettingsKey.agentName) private var agentName = QuillIOSSettingsKey.defaultAgentName

  private var canRun: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          ZStack {
            Circle()
              .fill(QuillDesign.actionAccent.opacity(0.18))
              .frame(width: 34, height: 34)
            Image(systemName: "keyboard")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(QuillDesign.actionAccent)
          }
          VStack(alignment: .leading, spacing: 1) {
            Text("Tell \(agentName) what to do")
              .font(.system(size: 15, weight: .semibold))
            Text("Same as speaking — just quieter")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }

        TextField(
          "Remind me to send the deck tomorrow at 9…",
          text: $text,
          axis: .vertical
        )
        .lineLimit(3...6)
        .focused($focused)
        .textFieldStyle(.plain)
        .font(.system(size: 15))
        .padding(12)
        .quillCard()
        .submitLabel(.go)
        .onSubmit { run() }

        Button(action: run) {
          Label("Run", systemImage: "bolt.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(canRun ? QuillDesign.actionAccent : QuillDesign.actionAccent.opacity(0.4))
            )
        }
        .disabled(!canRun)

        Spacer(minLength: 0)
      }
      .padding(18)
      .navigationTitle("Type a Command")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .onAppear { focused = true }
    }
    .presentationDetents([.height(280), .medium])
    .presentationDragIndicator(.visible)
  }

  private func run() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    dismiss()
    onSubmit(trimmed)
  }
}
