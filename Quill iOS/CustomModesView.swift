//
//  CustomModesView.swift
//  Quill (iOS)
//
//  Settings sub-screen for managing user-authored AI post-processing
//  modes. Each mode pairs a name with a system prompt; the prompt is
//  wrapped in the shared safety preamble (see
//  `CustomAIMode.fullSystemPrompt`) and sent to the LLM whenever the
//  user selects this mode in the chip row.
//
//  Storage is a JSON-encoded `[CustomAIMode]` blob in UserDefaults
//  under `CustomAIModesStorage.userDefaultsKey` — we keep a bound
//  `@AppStorage` wrapper in the view so edits are persisted instantly
//  and other views (the mode chip row in ContentView) see the change
//  via their own @AppStorage observer on the same key.
//

import HexCore
import SwiftUI

struct CustomModesView: View {
  @AppStorage(CustomAIModesStorage.userDefaultsKey) private var storedModesData: Data = Data()

  @State private var editingMode: CustomAIMode?
  @State private var showingCreate = false

  private var modes: [CustomAIMode] {
    CustomAIModesStorage.decode(storedModesData)
  }

  // Deliberately no NavigationStack / Done of its own: this screen is both
  // pushed (Settings → Formatting) and presented as a sheet (home's
  // "+ Add" format chip). The presenter owns the chrome — owning it here
  // too put a second Done in the sheet's bar.
  var body: some View {
      Group {
        if modes.isEmpty {
          ContentUnavailableView {
            Label("No Custom Modes", systemImage: "sparkles")
          } description: {
            Text("Create modes for the long tail of transforms Quill doesn't ship by default — \"Clinical note\", \"VC update\", \"Code review email\".")
          } actions: {
            Button("Create Mode", systemImage: "plus") {
              showingCreate = true
            }
            .buttonStyle(.borderedProminent)
          }
        } else {
          List {
            Section {
              ForEach(modes) { mode in
                Button {
                  editingMode = mode
                } label: {
                  HStack(alignment: .top, spacing: 12) {
                    Image(systemName: mode.icon)
                      .foregroundStyle(.purple)
                      .frame(width: 28, height: 28)
                      .background(Circle().fill(Color.purple.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 4) {
                      Text(mode.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                      Text(mode.systemPrompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                      .foregroundStyle(.tertiary)
                      .font(.caption.weight(.semibold))
                  }
                }
                .buttonStyle(.plain)
              }
              .onDelete { offsets in
                var current = modes
                current.remove(atOffsets: offsets)
                storedModesData = CustomAIModesStorage.encode(current)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
              }
            } header: {
              Text("Your Modes")
            } footer: {
              Text("Tap a mode to edit. Swipe left to delete. Custom modes appear alongside built-ins in the mode picker on the main screen.")
            }
          }
          .listStyle(.insetGrouped)
        }
      }
      .navigationTitle("Custom Modes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showingCreate = true
          } label: {
            Image(systemName: "plus")
          }
        }
      }
      .sheet(isPresented: $showingCreate) {
        CustomModeEditor(initial: nil) { newMode in
          var current = modes
          current.append(newMode)
          storedModesData = CustomAIModesStorage.encode(current)
        }
      }
      .sheet(item: $editingMode) { mode in
        CustomModeEditor(initial: mode) { updated in
          var current = modes
          if let idx = current.firstIndex(where: { $0.id == updated.id }) {
            current[idx] = updated
            storedModesData = CustomAIModesStorage.encode(current)
          }
        }
      }
  }
}

// MARK: - Editor

/// Sheet used both for "new mode" and "edit existing mode". `initial`
/// is nil when creating, populated when editing.
private struct CustomModeEditor: View {
  @Environment(\.dismiss) private var dismiss
  let initial: CustomAIMode?
  let onSave: (CustomAIMode) -> Void

  @State private var name: String
  @State private var systemPrompt: String
  @State private var icon: String

  init(initial: CustomAIMode?, onSave: @escaping (CustomAIMode) -> Void) {
    self.initial = initial
    self.onSave = onSave
    _name = State(initialValue: initial?.name ?? "")
    _systemPrompt = State(initialValue: initial?.systemPrompt ?? "")
    _icon = State(initialValue: initial?.icon ?? "sparkles")
  }

  private let iconChoices: [String] = [
    "sparkles", "stethoscope", "briefcase", "doc.text",
    "list.bullet.clipboard", "envelope", "bubble.left.and.bubble.right",
    "chevron.left.forwardslash.chevron.right", "heart.text.square",
    "books.vertical", "brain", "wand.and.stars",
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Mode name", text: $name)
            .textInputAutocapitalization(.words)
          HStack {
            Text("Icon")
            Spacer()
            Menu {
              ForEach(iconChoices, id: \.self) { choice in
                Button {
                  icon = choice
                } label: {
                  Label(choice, systemImage: choice)
                }
              }
            } label: {
              Image(systemName: icon)
                .foregroundStyle(.purple)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.purple.opacity(0.12)))
            }
          }
        } header: {
          Text("Identity")
        } footer: {
          Text("Short, memorable names work best — they appear as chips above the record button.")
        }

        Section {
          TextEditor(text: $systemPrompt)
            .frame(minHeight: 180)
            .font(.body)
        } header: {
          Text("Transformation Prompt")
        } footer: {
          Text("Describe what you want the AI to do, e.g. \"Rewrite as a clinical progress note in SOAP format. Preserve dates, medications, and dosages exactly. Use past tense.\" Quill wraps your prompt in the standard safety preamble — you don't need to repeat those rules.")
        }
      }
      .navigationTitle(initial == nil ? "New Mode" : "Edit Mode")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Save") {
            save()
          }
          .disabled(!canSave)
        }
      }
    }
  }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func save() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let mode = CustomAIMode(
      id: initial?.id ?? UUID(),
      name: trimmedName,
      systemPrompt: trimmedPrompt,
      icon: icon,
      createdAt: initial?.createdAt ?? Date()
    )
    onSave(mode)
    dismiss()
  }
}
