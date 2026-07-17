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
  /// Full cached tool lists, so an expanded row can show what a server
  /// actually offers (not just the count).
  @State private var mcpToolLists: [UUID: [MCPTool]] = [:]
  @State private var mcpErrors: [UUID: String] = [:]
  @State private var mcpSignedIn: [UUID: Bool] = [:]
  @State private var busyServers: Set<UUID> = []
  @State private var showAddMCPServer = false
  @State private var editingMCP: MCPEditContext?

  /// Rows the user has expanded to inspect tools/actions. Keyed by a
  /// stable per-row string (integration rawValue / brand id / server UUID).
  @State private var expandedRows: Set<String> = []
  @State private var searchText = ""

  /// Native integrations with a working send adapter. Everything else
  /// connects through MCP.
  private static let nativeIdentifiers: [Integration.Identifier] = [
    .appleReminders, .calendar, .todoist, .gmail, .googleCalendar,
  ]

  private var nativeIntegrations: [Integration] {
    Integration.all.filter { Self.nativeIdentifiers.contains($0.identifier) }
  }

  // MARK: - Search + merged alphabetical list (mirrors iOS ConnectionsView)

  /// A row matches when the query hits its name OR one of its tool/action
  /// names — so "contact" finds Dex even though the row just says "Dex".
  private func matchesSearch(_ name: String, extras: [String] = []) -> Bool {
    let q = searchText.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return true }
    if name.localizedCaseInsensitiveContains(q) { return true }
    return extras.contains { $0.localizedCaseInsensitiveContains(q) }
  }

  /// Natives and featured brands interleaved into ONE alphabetical list —
  /// the user shouldn't have to know which protocol a row uses to guess
  /// where it sorts.
  private enum AppsListItem: Identifiable {
    case native(Integration)
    case brand(ConnectionBrand)

    var id: String {
      switch self {
      case .native(let i): "native-\(i.identifier.rawValue)"
      case .brand(let b): "brand-\(b.id)"
      }
    }

    var sortName: String {
      switch self {
      case .native(let i): i.name
      case .brand(let b): b.name
      }
    }
  }

  private var visibleAppsItems: [AppsListItem] {
    let natives = nativeIntegrations
      .filter { matchesSearch($0.name, extras: ConnectionCapabilities.native($0.identifier).map(\.label)) }
      .map(AppsListItem.native)
    let brands = ConnectionDirectory.featured
      .filter { brand in
        let tools = server(for: brand).flatMap { mcpToolLists[$0.id] } ?? []
        return matchesSearch(brand.name, extras: tools.map(\.name))
      }
      .map(AppsListItem.brand)
    return (natives + brands)
      .sorted { $0.sortName.localizedCaseInsensitiveCompare($1.sortName) == .orderedAscending }
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
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.caption)
        TextField("Search connections and tools", text: $searchText)
          .textFieldStyle(.plain)
        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      ForEach(visibleAppsItems) { item in
        switch item {
        case .native(let integration): nativeRow(integration).padding(.vertical, 2)
        case .brand(let brand): featuredRow(brand).padding(.vertical, 2)
        }
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
      Text("Click a row to see what it can do. Everything here becomes voice actions — rows without a native adapter connect through each service\u{2019}s MCP server (usually a quick browser sign-in).")
        .settingsCaption()
    }
  }

  // MARK: - Row expansion

  private func toggleExpanded(_ key: String) {
    if expandedRows.contains(key) {
      expandedRows.remove(key)
    } else {
      expandedRows.insert(key)
    }
  }

  /// One capability/tool line inside an expanded row.
  private func expansionLine(symbol: String, title: String, detail: String?) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption.weight(.medium))
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
  }

  /// Expanded content for an MCP-backed row: the live tool list, a
  /// loading state while it fetches, or a hint when not connected.
  @ViewBuilder
  private func mcpExpansion(server: MCPServerConfig?) -> some View {
    if let server {
      if let tools = mcpToolLists[server.id], !tools.isEmpty {
        ForEach(tools, id: \.name) { tool in
          expansionLine(
            symbol: "wrench.and.screwdriver",
            title: ConnectionCapabilities.prettyToolName(tool.name, serverName: server.name),
            detail: tool.description
          )
        }
      } else if busyServers.contains(server.id) {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text("Loading tools…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let error = mcpErrors[server.id] {
        Text(error)
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Text("No tools reported. Use Refresh to re-fetch.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      Text("Connect to see this service's tools.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func chevron(_ expanded: Bool) -> some View {
    Image(systemName: "chevron.right")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.tertiary)
      .rotationEffect(.degrees(expanded ? 90 : 0))
  }

  // MARK: - Native integration rows

  private func nativeRow(_ integration: Integration) -> some View {
    let key = integration.identifier.rawValue
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 8) {
        chevron(expandedRows.contains(key))
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color(hex: integration.tintHex) ?? .secondary)
          .frame(width: 24, height: 24)
          .overlay(
            Image(systemName: integration.systemImage)
              .foregroundStyle(.white)
              .font(.system(size: 12, weight: .semibold))
          )
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
        if isConnected(integration) {
          Image(systemName: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        }
        Spacer()
        Button(isConnected(integration) ? "Disconnect" : "Connect") {
          toggle(integration)
        }
        .controlSize(.small)
        .disabled(!canConnect(integration) && !isConnected(integration))
      }
      .contentShape(Rectangle())
      .onTapGesture { toggleExpanded(key) }

      if expandedRows.contains(key) {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(ConnectionCapabilities.native(integration.identifier)) { capability in
            expansionLine(symbol: capability.symbol, title: capability.label, detail: nil)
          }
        }
        .padding(.top, 6)
        .padding(.leading, 16)
      }
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
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 8) {
        chevron(expandedRows.contains(brand.id))
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color(hex: brand.tintHex) ?? .gray)
          .frame(width: 24, height: 24)
          .overlay(
            Image(systemName: brand.systemImage)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.white)
          )
        Text(brand.name.capitalized)
          .font(.subheadline.weight(.medium))
        if let existing, let count = mcpToolCounts[existing.id] {
          Text("\(count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        if let existing, let error = mcpErrors[existing.id] {
          Text(error)
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(1)
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
      .contentShape(Rectangle())
      .onTapGesture {
        toggleExpanded(brand.id)
        // First expansion of a connected server with a cold cache: fetch.
        if expandedRows.contains(brand.id), let existing, mcpToolLists[existing.id] == nil {
          Task { await refreshServer(existing) }
        }
      }

      if expandedRows.contains(brand.id) {
        VStack(alignment: .leading, spacing: 2) {
          mcpExpansion(server: existing)
        }
        .padding(.top, 6)
        .padding(.leading, 16)
      }
    }
  }

  // MARK: - Custom servers

  /// Servers that don't match a featured brand.
  private var customServers: [MCPServerConfig] {
    hexSettings.mcpServers
      .filter { ConnectionDirectory.brand(forServerNamed: $0.name, url: $0.url) == nil }
      .filter { matchesSearch($0.name, extras: (mcpToolLists[$0.id] ?? []).map(\.name)) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    let key = server.id.uuidString
    return VStack(alignment: .leading, spacing: 0) {
      MCPServerRow(
        server: server,
        toolCount: mcpToolCounts[server.id],
        error: mcpErrors[server.id],
        isSignedIn: mcpSignedIn[server.id] ?? false,
        isExpanded: expandedRows.contains(key),
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
      .contentShape(Rectangle())
      .onTapGesture {
        toggleExpanded(key)
        if expandedRows.contains(key), mcpToolLists[server.id] == nil {
          Task { await refreshServer(server) }
        }
      }

      if expandedRows.contains(key) {
        VStack(alignment: .leading, spacing: 2) {
          mcpExpansion(server: server)
        }
        .padding(.top, 6)
        .padding(.leading, 16)
      }
    }
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
    guard token.isEmpty else { return }
    // No static token + server demands auth → kick off the browser sign-in
    // automatically (matches how OAuth MCP servers expect to be added).
    if isAuthError(error) {
      await signInMCPServer(server)
    } else if error == nil, await MCPOAuthClient.advertisesOAuth(server) {
      // The catalog fetch succeeded anonymously, but the server publishes
      // OAuth metadata — some (Dex) only 401 the actual tool calls. Sign in
      // NOW so the first voice action doesn't fail with an auth error.
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
      mcpToolLists[server.id] = tools
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
        mcpToolLists[server.id] = entry.tools
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
  var isExpanded: Bool = false
  let onSignIn: () -> Void
  let onToggleEnabled: (Bool) -> Void
  let onRefresh: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
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
