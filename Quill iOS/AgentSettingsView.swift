//
//  AgentSettingsView.swift
//  Quill (iOS)
//
//  The Agent sub-screen of Settings — the iOS counterpart of macOS's
//  Agent tab: identity (name), saved routines, and the local memory the
//  agent has built up. Tool/service connections live in
//  `ConnectionsView` (Settings → Productivity → Connections), where
//  native integrations and MCP servers share one surface.
//

import HexCore
import SwiftUI

struct AgentSettingsView: View {
  @AppStorage(QuillIOSSettingsKey.agentName) private var agentName = QuillIOSSettingsKey.defaultAgentName
  @AppStorage(QuillIOSSettingsKey.agentMemoryEnabled) private var memoryEnabled = QuillIOSSettingsKey.defaultAgentMemoryEnabled

  @State private var routines: [Routine] = []
  @State private var memories: [MemoryEntity] = []
  @State private var showForgetAllConfirm = false

  var body: some View {
    Form {
      heroSection
      routinesSection
      memorySection
    }
    .navigationTitle("Agent")
    .navigationBarTitleDisplayMode(.inline)
    .task { await reload() }
  }

  // MARK: - Hero

  private var heroSection: some View {
    Section {
      HStack(spacing: 16) {
        ZStack {
          Circle()
            .fill(
              LinearGradient(
                colors: [Color(hue: 0.85, saturation: 0.55, brightness: 0.95),
                         Color(hue: 0.69, saturation: 0.65, brightness: 0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(width: 56, height: 56)
            .shadow(color: Color.purple.opacity(0.35), radius: 8, y: 3)
          Image(systemName: "sparkles")
            .quillFont(24, weight: .semibold)
            .foregroundStyle(.white)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(agentName)
            .font(.title2.weight(.semibold))
          Text("Your personal voice agent")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.vertical, 6)

      HStack {
        Text("Agent Name")
        Spacer()
        TextField("Hermes", text: $agentName)
          .multilineTextAlignment(.trailing)
          .autocorrectionDisabled()
      }
    } footer: {
      Text("Speak commands with the mic (hold it to force an action): \"Add milk to my groceries list\", \"Email Mike the meeting notes\". Connect tools under Settings → Connections.")
    }
  }

  // MARK: - Routines

  private var routinesSection: some View {
    Section {
      if routines.isEmpty {
        Label("No routines yet", systemImage: "waveform")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(routines) { routine in
          routineRow(routine)
        }
      }
    } header: {
      Text("Routines")
    } footer: {
      Text("Say \u{201C}New routine: when I say ship it, add a Todoist task and email the team\u{201D} while using the action button to create one. Speaking a trigger phrase runs its steps instantly — no AI call needed.")
    }
  }

  private func routineRow(_ routine: Routine) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(routine.name)
          .font(.body.weight(.medium))
        Text("\u{201C}\(routine.triggerPhrases.first ?? "")\u{201D} · \(routine.steps.count) step\(routine.steps.count == 1 ? "" : "s")\(routine.runCount > 0 ? " · run \(routine.runCount)×" : "")")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Toggle("", isOn: Binding(
        get: { routine.autoRun },
        set: { enabled in
          var updated = routine
          updated.autoRun = enabled
          Task {
            await RoutineStore.shared.update(updated)
            routines = await RoutineStore.shared.loadAll()
          }
        }
      ))
      .labelsHidden()
      .tint(.purple)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        Task {
          await RoutineStore.shared.remove(id: routine.id)
          routines = await RoutineStore.shared.loadAll()
        }
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }

  // MARK: - Memory

  private var memorySection: some View {
    Section {
      Toggle(isOn: $memoryEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Learn from my dictations")
          Text("Remembers people, projects, and preferences")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      if memoryEnabled {
        if memories.isEmpty {
          Label("Nothing learned yet", systemImage: "brain")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(memories) { memory in
            memoryRow(memory)
          }
          Button(role: .destructive) {
            showForgetAllConfirm = true
          } label: {
            Label("Forget Everything", systemImage: "trash")
          }
        }
      }
    } header: {
      Text("What \(agentName) Knows")
    } footer: {
      Text("Everything \(agentName) has learned stays on this device — nothing syncs to the cloud. Delete any memory with a swipe.")
    }
    .confirmationDialog(
      "Forget everything \(agentName) has learned?",
      isPresented: $showForgetAllConfirm,
      titleVisibility: .visible
    ) {
      Button("Forget Everything", role: .destructive) {
        Task {
          await MemoryStore.shared.clear()
          memories = []
        }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func memoryRow(_ memory: MemoryEntity) -> some View {
    HStack(spacing: 10) {
      Image(systemName: memoryIcon(memory.kind))
        .quillFont(13)
        .foregroundStyle(.purple)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(memory.name)
          .quillFont(14, weight: .medium)
        if !memorySubtitle(memory).isEmpty {
          Text(memorySubtitle(memory))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        Task {
          await MemoryStore.shared.remove(id: memory.id)
          memories = await MemoryStore.shared.loadAll()
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
        }
      } label: {
        Label("Forget", systemImage: "trash")
      }
    }
  }

  private func memoryIcon(_ kind: MemoryEntity.Kind) -> String {
    switch kind {
    case .person: "person.fill"
    case .project: "folder.fill"
    case .preference: "slider.horizontal.3"
    case .place: "mappin.circle.fill"
    case .other: "circle.hexagongrid.fill"
    }
  }

  private func memorySubtitle(_ memory: MemoryEntity) -> String {
    var parts: [String] = []
    if !memory.aliases.isEmpty {
      parts.append(memory.aliases.joined(separator: ", "))
    }
    let details = memory.details.map { "\($0.key): \($0.value)" }.sorted()
    parts.append(contentsOf: details)
    return parts.joined(separator: " · ")
  }

  private func reload() async {
    routines = await RoutineStore.shared.loadAll()
    memories = await MemoryStore.shared.loadAll()
      .sorted { $0.lastSeenAt > $1.lastSeenAt }
  }
}
