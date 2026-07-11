//
//  RoutineSaveSheet.swift
//  Quill (iOS)
//
//  Confirmation sheet for a voice-authored routine ("new routine: when I
//  say ship it, …"). Shows the LLM-parsed draft — name, trigger phrase,
//  steps — and saves it to the shared `RoutineStore` on confirm. Saved
//  routines run instantly (no LLM) when their trigger is spoken in Action
//  mode; manage them in Settings → Agent.
//

import HexCore
import SwiftUI

struct RoutineSaveSheet: View {
  let draft: RoutineDraft
  var onFinish: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var triggerPhrase: String
  @State private var autoRun = false
  @State private var isSaving = false

  init(draft: RoutineDraft, onFinish: @escaping () -> Void) {
    self.draft = draft
    self.onFinish = onFinish
    _name = State(initialValue: draft.name)
    _triggerPhrase = State(initialValue: draft.triggerPhrase)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
          HStack {
            Text("When I say")
              .foregroundStyle(.secondary)
            TextField("Trigger phrase", text: $triggerPhrase)
              .textInputAutocapitalization(.never)
          }
          Toggle(isOn: $autoRun) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Run without confirming")
              Text("Skips the confirmation card when triggered")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        } header: {
          Text("New Routine")
        }

        Section {
          ForEach(Array(draft.actions.enumerated()), id: \.offset) { index, step in
            HStack(spacing: 10) {
              Text("\(index + 1)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
              VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                  .font(.system(size: 14, weight: .medium))
                Text(stepSubtitle(step))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        } header: {
          Text("Steps")
        } footer: {
          Text("Relative dates like \u{201C}Friday\u{201D} re-resolve each time the routine runs.")
        }
      }
      .navigationTitle("Save Routine")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onFinish()
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            guard !isSaving else { return }
            isSaving = true
            Task {
              await RoutineStore.shared.add(
                Routine(
                  name: name.trimmingCharacters(in: .whitespaces),
                  triggerPhrases: [triggerPhrase.trimmingCharacters(in: .whitespaces)],
                  steps: draft.actions,
                  autoRun: autoRun
                )
              )
              UINotificationFeedbackGenerator().notificationOccurred(.success)
              onFinish()
              dismiss()
            }
          }
          .disabled(
            name.trimmingCharacters(in: .whitespaces).isEmpty
              || triggerPhrase.trimmingCharacters(in: .whitespaces).isEmpty
              || draft.actions.isEmpty
          )
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func stepSubtitle(_ step: ActionIntent) -> String {
    if step.actionType == .mcpCall {
      return "\(step.mcpServerName ?? "MCP") · \(step.mcpTool ?? "tool")"
    }
    if step.actionType == .open {
      return step.urlString ?? "Open"
    }
    let integration = Integration.all.first { $0.identifier == step.targetIntegration }?.name
      ?? step.targetIntegration.rawValue
    if let due = step.dueDate, !due.isEmpty {
      return "\(integration) · \(due)"
    }
    return integration
  }
}
