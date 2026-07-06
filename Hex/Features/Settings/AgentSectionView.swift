//
//  AgentSectionView.swift
//  Quill (macOS)
//
//  Settings → General sections for the personal agent: identity (name),
//  saved routines, and the memory the agent has learned from dictations.
//  Store-less like OfflineQueueSectionView — RoutineStore / MemoryStore are
//  HexCore actors polled on appear and after user mutations; settings writes
//  go straight through @Shared(.hexSettings).
//

import Dependencies
import HexCore
import Inject
import Sharing
import SwiftUI

struct AgentSectionView: View {
  @ObserveInjection var inject
  @Shared(.hexSettings) var hexSettings: HexSettings

  @State private var routines: [Routine] = []
  @State private var memories: [MemoryEntity] = []
  @State private var mcpToolCounts: [UUID: Int] = [:]
  @State private var mcpErrors: [UUID: String] = [:]
  @State private var showAddMCPServer = false

  var body: some View {
    Group {
      heroSection
      identitySection
      routinesSection
      mcpSection
      memorySection
    }
    .task { await reload() }
    .sheet(isPresented: $showAddMCPServer) {
      MCPServerSheet { name, url, token in
        Task { await addMCPServer(name: name, url: url, token: token) }
      }
    }
    .enableInjection()
  }

  // MARK: - MCP servers

  private var mcpSection: some View {
    Section {
      if hexSettings.mcpServers.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "point.3.connected.trianglepath.dotted")
            .foregroundStyle(.secondary)
            .font(.caption)
          Text("No MCP servers connected")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(hexSettings.mcpServers) { server in
          MCPServerRow(
            server: server,
            toolCount: mcpToolCounts[server.id],
            error: mcpErrors[server.id],
            onToggleEnabled: { enabled in
              $hexSettings.withLock { settings in
                if let idx = settings.mcpServers.firstIndex(where: { $0.id == server.id }) {
                  settings.mcpServers[idx].isEnabled = enabled
                }
              }
              if enabled { Task { await refreshServer(server) } }
            },
            onRefresh: { Task { await refreshServer(server) } },
            onDelete: { Task { await deleteMCPServer(server) } }
          )
        }
      }
      Button {
        showAddMCPServer = true
      } label: {
        Label("Add MCP Server", systemImage: "plus.circle")
      }
      .controlSize(.small)
    } header: {
      Text("Tools (MCP)")
    } footer: {
      Text("Connect any Model Context Protocol server over HTTP and its tools become things you can ask \(agentName) to do by voice. Auth tokens are stored in the keychain.")
        .settingsCaption()
    }
  }

  private func addMCPServer(name: String, url: String, token: String) async {
    let server = MCPServerConfig(name: name, url: url)
    if !token.isEmpty {
      @Dependency(\.keychain) var keychain
      try? await keychain.save(server.keychainTokenKey, token)
    }
    $hexSettings.withLock { $0.mcpServers.append(server) }
    await refreshServer(server)
  }

  private func refreshServer(_ server: MCPServerConfig) async {
    @Dependency(\.keychain) var keychain
    let token = await keychain.read(server.keychainTokenKey)
    do {
      let tools = try await MCPToolCatalog.shared.refresh(server: server, authToken: token)
      mcpToolCounts[server.id] = tools.count
      mcpErrors[server.id] = nil
    } catch {
      mcpErrors[server.id] = error.localizedDescription
    }
  }

  private func deleteMCPServer(_ server: MCPServerConfig) async {
    $hexSettings.withLock { settings in
      settings.mcpServers.removeAll { $0.id == server.id }
    }
    await MCPToolCatalog.shared.remove(serverID: server.id)
    @Dependency(\.keychain) var keychain
    await keychain.delete(server.keychainTokenKey)
  }

  // MARK: - Hero

  /// Big friendly header: gradient avatar, the agent's name, and live
  /// counts. Gives the tab an identity beyond a stack of form rows.
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
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(agentName)
            .font(.title2.weight(.semibold))
          Text("Your personal voice agent")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack(spacing: 10) {
            statChip(count: routines.count, singular: "routine", icon: "waveform")
            statChip(count: memories.count, singular: "memory", plural: "memories", icon: "brain")
          }
          .padding(.top, 4)
        }
        Spacer()
      }
      .padding(.vertical, 6)
    }
  }

  private func statChip(count: Int, singular: String, plural: String? = nil, icon: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .semibold))
      Text("\(count) \(count == 1 ? singular : (plural ?? singular + "s"))")
        .font(.caption2.weight(.medium))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Color.primary.opacity(0.06), in: Capsule())
  }

  private func reload() async {
    routines = await RoutineStore.shared.loadAll()
    memories = await MemoryStore.shared.loadAll()
      .sorted { $0.lastSeenAt > $1.lastSeenAt }
    for server in hexSettings.mcpServers {
      if let entry = await MCPToolCatalog.shared.cachedTools(for: server.id) {
        mcpToolCounts[server.id] = entry.tools.count
      }
    }
  }

  // MARK: - Identity

  private var identitySection: some View {
    Section {
      Label {
        HStack {
          Text("Agent Name")
          Spacer()
          TextField(
            "Hermes",
            text: Binding(
              get: { hexSettings.agentName },
              set: { newValue in $hexSettings.withLock { $0.agentName = newValue } }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 160)
          .multilineTextAlignment(.trailing)
        }
      } icon: {
        Image(systemName: "sparkles")
      }

      Label {
        Toggle(
          "Learn from my dictations",
          isOn: Binding(
            get: { hexSettings.agentMemoryEnabled },
            set: { newValue in $hexSettings.withLock { $0.agentMemoryEnabled = newValue } }
          )
        )
      } icon: {
        Image(systemName: "brain")
      }
    } header: {
      Text("Identity")
    } footer: {
      Text("\(agentName) remembers people, projects, and preferences from your Action-mode dictations — stored only on this Mac — so commands like \u{201C}email Mike\u{201D} resolve without questions.")
        .settingsCaption()
    }
  }

  // MARK: - Routines

  private var routinesSection: some View {
    Section {
      if routines.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "waveform.badge.plus")
            .foregroundStyle(.secondary)
            .font(.caption)
          Text("No routines yet")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(routines) { routine in
          RoutineRow(
            routine: routine,
            onToggleAutoRun: { enabled in
              Task {
                var updated = routine
                updated.autoRun = enabled
                await RoutineStore.shared.update(updated)
                await reload()
              }
            },
            onDelete: {
              Task {
                await RoutineStore.shared.remove(id: routine.id)
                await reload()
              }
            }
          )
        }
      }
    } header: {
      Text("Routines")
    } footer: {
      Text("Create one by voice in Action mode: \u{201C}New routine: when I say ship it, create my release checklist in Todoist and email the team.\u{201D} Saying the trigger phrase later runs the steps instantly — no AI call. Auto-run skips the confirmation panel.")
        .settingsCaption()
    }
  }

  // MARK: - Memory

  private var memorySection: some View {
    Section {
      if memories.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "brain")
            .foregroundStyle(.secondary)
            .font(.caption)
          Text("Nothing learned yet")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(memories) { entity in
          MemoryRow(entity: entity) {
            Task {
              await MemoryStore.shared.remove(id: entity.id)
              await reload()
            }
          }
        }
        Button(role: .destructive) {
          Task {
            await MemoryStore.shared.clear()
            await reload()
          }
        } label: {
          Label("Forget everything", systemImage: "trash")
        }
        .controlSize(.small)
      }
    } header: {
      Text("What \(agentName) Knows")
    } footer: {
      Text("Every memory is visible here and deletable. Nothing leaves this Mac.")
        .settingsCaption()
    }
  }

  private var agentName: String {
    hexSettings.agentName.isEmpty ? "Hermes" : hexSettings.agentName
  }
}

// MARK: - Rows

private struct RoutineRow: View {
  let routine: Routine
  let onToggleAutoRun: (Bool) -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(routine.name)
          .font(.subheadline.weight(.medium))
        HStack(spacing: 6) {
          Text("\u{201C}\(routine.triggerPhrases.first ?? "")\u{201D}")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("·")
            .foregroundStyle(.tertiary)
          Text("\(routine.steps.count) step\(routine.steps.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
          if routine.runCount > 0 {
            Text("·")
              .foregroundStyle(.tertiary)
            Text("run \(routine.runCount)×")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer()
      Toggle(
        "Auto-run",
        isOn: Binding(get: { routine.autoRun }, set: onToggleAutoRun)
      )
      .toggleStyle(.checkbox)
      .font(.caption)
      Button(action: onDelete) {
        Image(systemName: "trash")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Delete routine")
    }
  }
}

private struct MemoryRow: View {
  let entity: MemoryEntity
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(entity.name)
          .font(.subheadline)
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
      Button(action: onDelete) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .help("Forget this")
    }
  }

  private var icon: String {
    switch entity.kind {
    case .person: "person.crop.circle"
    case .project: "folder"
    case .preference: "slider.horizontal.3"
    case .place: "mappin.circle"
    case .other: "questionmark.circle"
    }
  }

  private var subtitle: String {
    var parts: [String] = []
    if !entity.aliases.isEmpty {
      parts.append("aka \(entity.aliases.joined(separator: ", "))")
    }
    parts.append(contentsOf: entity.details.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
    return parts.joined(separator: " · ")
  }
}

// MARK: - MCP server row + add sheet

private struct MCPServerRow: View {
  let server: MCPServerConfig
  let toolCount: Int?
  let error: String?
  let onToggleEnabled: (Bool) -> Void
  let onRefresh: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .foregroundStyle(server.isEnabled ? Color.purple : Color.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(server.name)
          .font(.subheadline.weight(.medium))
        HStack(spacing: 6) {
          Text(server.url)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let error {
            Text("· \(error)")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(1)
          } else if let toolCount {
            Text("· \(toolCount) tool\(toolCount == 1 ? "" : "s")")
              .font(.caption)
              .foregroundStyle(.green)
          }
        }
      }
      Spacer()
      Button(action: onRefresh) {
        Image(systemName: "arrow.clockwise")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Refresh tool list")
      Toggle("", isOn: Binding(get: { server.isEnabled }, set: onToggleEnabled))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
      Button(action: onDelete) {
        Image(systemName: "trash")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Remove server")
    }
  }
}

private struct MCPServerSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onAdd: (String, String, String) -> Void

  @State private var name = ""
  @State private var url = ""
  @State private var token = ""

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
      && URL(string: url)?.scheme?.hasPrefix("http") == true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add MCP Server")
        .font(.headline)
      Text("Any server speaking Model Context Protocol over HTTP. Its tools become voice-invocable actions.")
        .font(.caption)
        .foregroundStyle(.secondary)

      TextField("Name (how you'll say it — e.g. linear)", text: $name)
        .textFieldStyle(.roundedBorder)
      TextField("URL (https://mcp.example.com/mcp)", text: $url)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
      SecureField("Bearer token (optional)", text: $token)
        .textFieldStyle(.roundedBorder)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") {
          onAdd(
            name.trimmingCharacters(in: .whitespaces),
            url.trimmingCharacters(in: .whitespaces),
            token.trimmingCharacters(in: .whitespaces)
          )
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isValid)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}
