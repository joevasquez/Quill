//
//  ConnectionsSectionView.swift
//  Quill (macOS)
//
//  THE connections surface on the Integrations tab — one "Apps &
//  services" list where native integrations (EventKit / Todoist /
//  Google) and featured MCP-backed brands from `ConnectionDirectory`
//  render as the same kind of row, so the user never learns which
//  protocol a row uses. Featured brands connect with one click
//  (creates an `MCPServerConfig` + auto-starts the browser OAuth flow
//  on the first 401); "Custom servers" below is the power-user escape
//  hatch. Absorbed the old IntegrationsSectionView and the MCP section
//  from AgentSectionView; the Agent tab keeps identity/routines/memory.
//

import Dependencies
import EventKit
import HexCore
import Inject
import Sharing
import SwiftUI

struct ConnectionsSectionView: View {
  @ObserveInjection var inject
  @Shared(.hexSettings) var hexSettings: HexSettings

  // Native integration connection state — same UserDefaults key as iOS.
  @AppStorage(IntegrationConnectionStore.userDefaultsKey)
  private var connectedData: Data = Data()
  @State private var showingTodoistSheet = false
  @State private var showingGoogleOAuthSheet = false

  @State private var mcpToolCounts: [UUID: Int] = [:]
  @State private var mcpErrors: [UUID: String] = [:]
  @State private var mcpSignedIn: [UUID: Bool] = [:]
  @State private var busyServers: Set<UUID> = []
  @State private var showAddMCPServer = false
  @State private var editingMCP: MCPEditContext?

  /// Native integrations with a working send adapter. Everything else
  /// connects through MCP.
  private static let nativeIdentifiers: [Integration.Identifier] = [
    .appleReminders, .calendar, .todoist, .gmail, .googleCalendar,
  ]

  private var nativeIntegrations: [Integration] {
    Integration.all.filter { Self.nativeIdentifiers.contains($0.identifier) }
  }

  var body: some View {
    Form {
      appsSection
      customSection
    }
    .formStyle(.grouped)
    .task { await reload() }
    .sheet(isPresented: $showAddMCPServer) {
      MCPServerSheet { name, url, token, _ in
        Task { await addMCPServer(name: name, url: url, token: token) }
      }
    }
    .sheet(item: $editingMCP) { ctx in
      MCPServerSheet(existing: ctx.server, hasStoredToken: ctx.hasToken) { name, url, token, removeToken in
        Task { await editMCPServer(ctx.server, name: name, url: url, token: token, removeToken: removeToken) }
      }
    }
    .sheet(isPresented: $showingTodoistSheet) {
      TodoistTokenSheet(onConnected: {
        var current = connected
        current.insert(.todoist)
        connectedData = IntegrationConnectionStore.encode(current)
      })
    }
    .sheet(isPresented: $showingGoogleOAuthSheet) {
      GoogleOAuthSheet(onConnected: {
        var current = connected
        current.insert(.gmail)
        current.insert(.googleCalendar)
        connectedData = IntegrationConnectionStore.encode(current)
      })
    }
    .enableInjection()
  }

  // MARK: - Apps & services (native + featured, one list)

  private var appsSection: some View {
    Section {
      ForEach(nativeIntegrations) { integration in
        nativeRow(integration)
          .padding(.vertical, 2)
      }
      ForEach(ConnectionDirectory.featured) { brand in
        featuredRow(brand)
          .padding(.vertical, 2)
      }
      if connectedFreeCount >= IntegrationLimits.freeTierMaxConnections,
         nativeIntegrations.contains(where: { !isConnected($0) && !$0.requiresPro }) {
        Text("Free plan is capped at \(IntegrationLimits.freeTierMaxConnections) connected integrations. Disconnect one to swap, or upgrade to Pro for unlimited.")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    } header: {
      Text("Apps & services")
    } footer: {
      Text("Everything here becomes voice actions — \u{201C}remind me Friday to review the launch deck\u{201D} becomes a Todoist task; \u{201C}log a note on Joe in Dex\u{201D} calls the service directly. Rows without a native adapter connect through each service\u{2019}s MCP server (usually a quick browser sign-in).")
        .settingsCaption()
    }
  }

  // MARK: - Native integration rows

  private func nativeRow(_ integration: Integration) -> some View {
    HStack(alignment: .center, spacing: 10) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(hex: integration.tintHex) ?? .secondary)
        .frame(width: 26, height: 26)
        .overlay(
          Image(systemName: integration.systemImage)
            .foregroundStyle(.white)
            .font(.system(size: 13, weight: .semibold))
        )
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(integration.name)
            .font(.subheadline.weight(.medium))
          if integration.requiresPro {
            Text("PRO")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(Capsule().fill(Color.purple))
          }
        }
        Text(isConnected(integration) ? "Connected" : integration.tagline)
          .font(.caption)
          .foregroundStyle(isConnected(integration) ? .green : .secondary)
          .lineLimit(2)
      }
      Spacer()
      Button(isConnected(integration) ? "Disconnect" : "Connect") {
        toggle(integration)
      }
      .controlSize(.small)
      .disabled(!canConnect(integration) && !isConnected(integration))
    }
  }

  private var connected: Set<Integration.Identifier> {
    IntegrationConnectionStore.decode(connectedData)
  }

  /// Free-tier cap counts only non-Pro integrations — Pro ones (Gmail,
  /// Google Calendar) come in through their own OAuth path and would
  /// otherwise squeeze out the free set after one Google sign-in.
  private var connectedFreeCount: Int {
    connected.filter { id in
      Integration.all.first(where: { $0.identifier == id })?.requiresPro == false
    }.count
  }

  private func isConnected(_ integration: Integration) -> Bool {
    connected.contains(integration.identifier)
  }

  private func canConnect(_ integration: Integration) -> Bool {
    if isConnected(integration) { return true }  // so they can still disconnect
    if integration.requiresPro { return false }
    return connectedFreeCount < IntegrationLimits.freeTierMaxConnections
  }

  private func toggle(_ integration: Integration) {
    var current = connected
    if current.contains(integration.identifier) {
      current.remove(integration.identifier)
      connectedData = IntegrationConnectionStore.encode(current)
      switch integration.identifier {
      case .todoist:
        Task {
          @Dependency(\.keychain) var keychain
          await keychain.delete(KeychainKey.todoistAPIToken)
        }
      case .gmail, .googleCalendar:
        var updated = IntegrationConnectionStore.decode(connectedData)
        updated.remove(.gmail)
        updated.remove(.googleCalendar)
        connectedData = IntegrationConnectionStore.encode(updated)
        Task {
          @Dependency(\.googleOAuth) var googleOAuth
          await googleOAuth.disconnect()
        }
      default:
        break
      }
      return
    }

    switch integration.identifier {
    case .appleReminders:
      Task {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        if granted {
          var updated = connected
          updated.insert(.appleReminders)
          connectedData = IntegrationConnectionStore.encode(updated)
        }
      }
    case .calendar:
      Task {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted {
          var updated = connected
          updated.insert(.calendar)
          connectedData = IntegrationConnectionStore.encode(updated)
        }
      }
    case .todoist:
      showingTodoistSheet = true
    case .gmail, .googleCalendar:
      // Already signed in via the Google Account section → just flip
      // the integration bit; otherwise run the OAuth sheet.
      Task {
        @Dependency(\.googleOAuth) var googleOAuth
        if await googleOAuth.isAuthorized() {
          var updated = connected
          updated.insert(integration.identifier)
          connectedData = IntegrationConnectionStore.encode(updated)
        } else {
          showingGoogleOAuthSheet = true
        }
      }
    default:
      break
    }
  }

  // MARK: - Featured brands

  /// The stored server backing a featured brand, if connected.
  private func server(for brand: ConnectionBrand) -> MCPServerConfig? {
    hexSettings.mcpServers.first {
      ConnectionDirectory.brand(forServerNamed: $0.name, url: $0.url)?.id == brand.id
    }
  }

  private func featuredRow(_ brand: ConnectionBrand) -> some View {
    let existing = server(for: brand)
    return HStack(alignment: .center, spacing: 10) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(hex: brand.tintHex) ?? .gray)
        .frame(width: 26, height: 26)
        .overlay(
          Image(systemName: brand.systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
        )
      VStack(alignment: .leading, spacing: 2) {
        Text(brand.name.capitalized)
          .font(.subheadline.weight(.medium))
        Text(featuredStatus(existing) ?? brand.tagline)
          .font(.caption)
          .foregroundStyle(featuredStatusColor(existing))
          .lineLimit(2)
      }
      Spacer()
      if let existing, busyServers.contains(existing.id) {
        ProgressView()
          .controlSize(.small)
      } else if let existing {
        Button("Refresh") { Task { await refreshServer(existing) } }
          .controlSize(.small)
        Button("Disconnect") { Task { await deleteMCPServer(existing) } }
          .controlSize(.small)
      } else {
        Button("Connect") {
          Task { await addMCPServer(name: brand.name, url: brand.mcpURL, token: "") }
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .tint(.purple)
      }
    }
  }

  private func featuredStatus(_ server: MCPServerConfig?) -> String? {
    guard let server else { return nil }
    if let error = mcpErrors[server.id] { return error }
    if let count = mcpToolCounts[server.id] {
      return "Connected · \(count) tool\(count == 1 ? "" : "s")\(mcpSignedIn[server.id] == true ? " · signed in" : "")"
    }
    return "Connected"
  }

  private func featuredStatusColor(_ server: MCPServerConfig?) -> Color {
    guard let server else { return .secondary }
    if mcpErrors[server.id] != nil { return .red }
    if mcpToolCounts[server.id] != nil { return .green }
    return .secondary
  }

  // MARK: - Custom servers

  /// Servers that don't match a featured brand.
  private var customServers: [MCPServerConfig] {
    hexSettings.mcpServers.filter {
      ConnectionDirectory.brand(forServerNamed: $0.name, url: $0.url) == nil
    }
  }

  private var customSection: some View {
    Section {
      if customServers.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "point.3.connected.trianglepath.dotted")
            .foregroundStyle(.secondary)
            .font(.caption)
          Text("No custom servers")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(customServers) { server in
          mcpServerRow(server)
        }
      }
      Button {
        showAddMCPServer = true
      } label: {
        Label("Add MCP Server", systemImage: "plus.circle")
      }
      .controlSize(.small)
    } header: {
      Text("Custom servers (MCP)")
    } footer: {
      Text("Connect any Model Context Protocol server over HTTP and its tools become things you can ask \(agentName) to do by voice. Servers that require a browser sign-in (OAuth) prompt automatically when added; others take an optional bearer token. Credentials are stored in the keychain.")
        .settingsCaption()
    }
  }

  // Extracted so the Section body stays small enough for the type-checker.
  private func mcpServerRow(_ server: MCPServerConfig) -> some View {
    MCPServerRow(
      server: server,
      toolCount: mcpToolCounts[server.id],
      error: mcpErrors[server.id],
      isSignedIn: mcpSignedIn[server.id] ?? false,
      onSignIn: { Task { await signInMCPServer(server) } },
      onToggleEnabled: { enabled in
        $hexSettings.withLock { settings in
          if let idx = settings.mcpServers.firstIndex(where: { $0.id == server.id }) {
            settings.mcpServers[idx].isEnabled = enabled
          }
        }
        if enabled { Task { await refreshServer(server) } }
      },
      onRefresh: { Task { await refreshServer(server) } },
      onEdit: { Task { await beginEditMCPServer(server) } },
      onDelete: { Task { await deleteMCPServer(server) } }
    )
  }

  // MARK: - Server management

  private func addMCPServer(name: String, url: String, token: String) async {
    let server = MCPServerConfig(name: name, url: url)
    if !token.isEmpty {
      @Dependency(\.keychain) var keychain
      try? await keychain.save(server.keychainTokenKey, token)
    }
    $hexSettings.withLock { $0.mcpServers.append(server) }
    let error = await refreshServer(server)
    // No static token + server demands auth → kick off the browser sign-in
    // automatically (matches how OAuth MCP servers expect to be added).
    if token.isEmpty, isAuthError(error) {
      await signInMCPServer(server)
    }
  }

  @discardableResult
  private func refreshServer(_ server: MCPServerConfig) async -> Error? {
    busyServers.insert(server.id)
    defer { busyServers.remove(server.id) }
    let token = await MCPOAuthClient.resolveAuthToken(for: server)
    do {
      let tools = try await MCPToolCatalog.shared.refresh(server: server, authToken: token)
      mcpToolCounts[server.id] = tools.count
      mcpErrors[server.id] = nil
      return nil
    } catch {
      mcpErrors[server.id] = error.localizedDescription
      return error
    }
  }

  /// Runs the browser OAuth flow, then refreshes the tool list.
  @MainActor
  private func signInMCPServer(_ server: MCPServerConfig) async {
    do {
      try await MCPOAuthClient.signIn(server: server)
      mcpSignedIn[server.id] = true
      mcpErrors[server.id] = nil
      await refreshServer(server)
    } catch {
      mcpErrors[server.id] = error.localizedDescription
    }
  }

  private func isAuthError(_ error: Error?) -> Bool {
    guard let mcp = error as? MCPError, case let .httpError(code, _) = mcp else { return false }
    return code == 401 || code == 403
  }

  private func deleteMCPServer(_ server: MCPServerConfig) async {
    $hexSettings.withLock { settings in
      settings.mcpServers.removeAll { $0.id == server.id }
    }
    await MCPToolCatalog.shared.remove(serverID: server.id)
    @Dependency(\.keychain) var keychain
    await keychain.delete(server.keychainTokenKey)
    await keychain.delete(server.oauthKeychainKey)
  }

  /// Opens the edit sheet, first probing the keychain so the sheet knows
  /// whether a token is already stored (it isn't shown, only replaced).
  private func beginEditMCPServer(_ server: MCPServerConfig) async {
    @Dependency(\.keychain) var keychain
    let hasToken = !(await keychain.read(server.keychainTokenKey) ?? "").isEmpty
    editingMCP = MCPEditContext(server: server, hasToken: hasToken)
  }

  private func editMCPServer(
    _ server: MCPServerConfig, name: String, url: String, token: String, removeToken: Bool
  ) async {
    $hexSettings.withLock { settings in
      if let idx = settings.mcpServers.firstIndex(where: { $0.id == server.id }) {
        settings.mcpServers[idx].name = name
        settings.mcpServers[idx].url = url
      }
    }
    @Dependency(\.keychain) var keychain
    // Token key is derived from the (unchanged) id, so it stays stable.
    if removeToken {
      await keychain.delete(server.keychainTokenKey)
    } else if !token.isEmpty {
      try? await keychain.save(server.keychainTokenKey, token)
    }
    // Re-fetch tools with the updated URL/token.
    var updated = server
    updated.name = name
    updated.url = url
    await refreshServer(updated)
  }

  private func reload() async {
    for server in hexSettings.mcpServers {
      if let entry = await MCPToolCatalog.shared.cachedTools(for: server.id) {
        mcpToolCounts[server.id] = entry.tools.count
      }
      mcpSignedIn[server.id] = await MCPOAuthClient.isSignedIn(server)
    }
  }

  private var agentName: String {
    hexSettings.agentName.isEmpty ? "Hermes" : hexSettings.agentName
  }
}

// MARK: - MCP server row + add sheet

private struct MCPServerRow: View {
  let server: MCPServerConfig
  let toolCount: Int?
  let error: String?
  let isSignedIn: Bool
  let onSignIn: () -> Void
  let onToggleEnabled: (Bool) -> Void
  let onRefresh: () -> Void
  let onEdit: () -> Void
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
              .lineLimit(2)
          } else if let toolCount {
            Text("· \(toolCount) tool\(toolCount == 1 ? "" : "s")")
              .font(.caption)
              .foregroundStyle(.green)
          } else if isSignedIn {
            Text("· signed in")
              .font(.caption)
              .foregroundStyle(.green)
          }
        }
      }
      Spacer()
      Button(action: onSignIn) {
        Image(systemName: isSignedIn ? "key.fill" : "key")
          .foregroundStyle(isSignedIn ? Color.green : Color.secondary)
      }
      .buttonStyle(.plain)
      .help(isSignedIn ? "Re-authenticate (browser sign-in)" : "Sign in with browser (OAuth)")
      Button(action: onRefresh) {
        Image(systemName: "arrow.clockwise")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Refresh tool list")
      Button(action: onEdit) {
        Image(systemName: "pencil")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Edit server")
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

/// Carries the server + whether it has a stored token into the edit sheet.
private struct MCPEditContext: Identifiable {
  let server: MCPServerConfig
  let hasToken: Bool
  var id: UUID { server.id }
}

/// Add/edit sheet for an MCP server. `existing == nil` → add mode.
/// The stored token is never displayed: in edit mode, a blank token field
/// keeps the current token, a non-blank one replaces it, and "Remove saved
/// token" clears it.
private struct MCPServerSheet: View {
  @Environment(\.dismiss) private var dismiss
  var existing: MCPServerConfig?
  var hasStoredToken: Bool = false
  /// (name, url, newToken, removeToken)
  let onSave: (String, String, String, Bool) -> Void

  @State private var name: String
  @State private var url: String
  @State private var token = ""
  @State private var removeToken = false

  init(
    existing: MCPServerConfig? = nil,
    hasStoredToken: Bool = false,
    onSave: @escaping (String, String, String, Bool) -> Void
  ) {
    self.existing = existing
    self.hasStoredToken = hasStoredToken
    self.onSave = onSave
    _name = State(initialValue: existing?.name ?? "")
    _url = State(initialValue: existing?.url ?? "")
  }

  private var isEditing: Bool { existing != nil }

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
      && URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(isEditing ? "Edit MCP Server" : "Add MCP Server")
        .font(.headline)
      Text("Any server speaking Model Context Protocol over HTTP. Its tools become voice-invocable actions.")
        .font(.caption)
        .foregroundStyle(.secondary)

      TextField("Name (how you'll say it — e.g. linear)", text: $name)
        .textFieldStyle(.roundedBorder)
      TextField("URL (https://mcp.example.com/mcp)", text: $url)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
      SecureField(
        hasStoredToken ? "Bearer token (leave blank to keep current)" : "Bearer token (optional)",
        text: $token
      )
      .textFieldStyle(.roundedBorder)
      .disabled(removeToken)
      if hasStoredToken {
        Toggle("Remove saved token", isOn: $removeToken)
          .toggleStyle(.checkbox)
          .controlSize(.small)
          .font(.caption)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(isEditing ? "Save" : "Add") {
          onSave(
            name.trimmingCharacters(in: .whitespaces),
            url.trimmingCharacters(in: .whitespaces),
            token.trimmingCharacters(in: .whitespaces),
            removeToken
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
