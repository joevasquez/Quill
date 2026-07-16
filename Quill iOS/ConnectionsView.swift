//
//  ConnectionsView.swift
//  Quill (iOS)
//
//  ONE place to connect Quill to the outside world. Native integrations
//  (EventKit / Todoist / Google) and MCP-backed services render as the
//  same kind of row — "Connect Notion" is one tap that creates an
//  `MCPServerConfig` from the curated `ConnectionDirectory` and starts
//  the browser OAuth flow. MCP is an implementation detail here; the
//  "Custom servers" section at the bottom is the power-user escape
//  hatch (add any MCP endpoint by URL).
//
//  Replaces the old IntegrationsView + the MCP section that lived in
//  AgentSettingsView (the Agent screen keeps identity/routines/memory).
//

import EventKit
import HexCore
import SwiftUI

struct ConnectionsView: View {
  @AppStorage(IntegrationConnectionStore.userDefaultsKey) private var connectedData: Data = Data()

  @State private var showingTodoistSheet = false
  @State private var showingGoogleSheet = false

  // MCP state (shared by featured + custom sections)
  @State private var servers: [MCPServerConfig] = MCPServersStorage.load()
  @State private var toolCounts: [UUID: Int] = [:]
  /// Full cached tool lists, so an expanded row can show what a server
  /// actually offers (not just the count).
  @State private var toolLists: [UUID: [MCPTool]] = [:]
  @State private var serverErrors: [UUID: String] = [:]
  @State private var signedIn: [UUID: Bool] = [:]
  @State private var busyServers: Set<UUID> = []
  @State private var showAddServer = false
  @State private var editingServer: MCPEditContext?

  /// Rows the user has expanded to inspect tools/actions. Keyed by a
  /// stable per-row string (integration rawValue / brand id / server UUID).
  @State private var expandedRows: Set<String> = []
  @State private var searchText = ""

  /// Native integrations with a working send adapter.
  private static let nativeIdentifiers: [Integration.Identifier] = [
    .appleReminders, .calendar, .todoist, .gmail, .googleCalendar,
  ]

  private var nativeIntegrations: [Integration] {
    Integration.all.filter { Self.nativeIdentifiers.contains($0.identifier) }
  }

  /// Servers that don't match a featured brand — listed under Custom.
  private var customServers: [MCPServerConfig] {
    servers.filter { ConnectionDirectory.brand(forServerNamed: $0.name, url: $0.url) == nil }
  }

  // MARK: - Search

  /// A row matches when the query hits its name OR one of its tool/action
  /// names — so "contact" finds Dex even though the row just says "Dex".
  private func matchesSearch(_ name: String, extras: [String] = []) -> Bool {
    let q = searchText.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return true }
    if name.localizedCaseInsensitiveContains(q) { return true }
    return extras.contains { $0.localizedCaseInsensitiveContains(q) }
  }

  private var visibleNativeIntegrations: [Integration] {
    nativeIntegrations.filter {
      matchesSearch($0.name, extras: Self.nativeActions($0.identifier).map(\.label))
    }
  }

  private var visibleBrands: [ConnectionBrand] {
    ConnectionDirectory.featured.filter { brand in
      let tools = server(for: brand).flatMap { toolLists[$0.id] } ?? []
      return matchesSearch(brand.name, extras: tools.map(\.name))
    }
  }

  private var visibleCustomServers: [MCPServerConfig] {
    customServers
      .filter { server in
        matchesSearch(server.name, extras: (toolLists[server.id] ?? []).map(\.name))
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    (visibleNativeIntegrations.map(AppsListItem.native)
      + visibleBrands.map(AppsListItem.brand))
      .sorted { $0.sortName.localizedCaseInsensitiveCompare($1.sortName) == .orderedAscending }
  }

  // Deliberately no NavigationStack / Done of its own: this screen is both
  // pushed (Settings → Connections) and presented as a sheet (home's
  // "+ Connect an app" chip). The presenter owns the chrome — owning it
  // here too put a second Done in the sheet's bar.
  var body: some View {
      List {
        Section {
          ForEach(visibleAppsItems) { item in
            switch item {
            case .native(let integration): nativeRow(integration)
            case .brand(let brand): featuredRow(brand)
            }
          }
        } header: {
          Text("Apps & services")
        } footer: {
          Text("Tap a row to see what it can do. Free plan includes \(IntegrationLimits.freeTierMaxConnections) integrations; Pro unlocks all.")
        }

        Section {
          if visibleCustomServers.isEmpty {
            Label(
              searchText.isEmpty ? "No custom servers" : "No matches",
              systemImage: "point.3.connected.trianglepath.dotted"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            ForEach(visibleCustomServers) { server in
              customServerRow(server)
            }
          }
          Button {
            showAddServer = true
          } label: {
            Label("Add MCP Server", systemImage: "plus.circle")
          }
        } header: {
          Text("Custom servers")
        } footer: {
          Text("Any Model Context Protocol server over HTTP becomes a set of voice actions. Servers that require a browser sign-in prompt automatically; others take an optional bearer token. Credentials stay in the keychain.")
        }
      }
      .navigationTitle("Connections")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search connections and tools")
      .task { await reloadServers() }
      .sheet(isPresented: $showingTodoistSheet) {
        TodoistTokenSheetIOS(onConnected: {
          var current = connected
          current.insert(.todoist)
          connectedData = IntegrationConnectionStore.encode(current)
        })
      }
      .sheet(isPresented: $showingGoogleSheet) {
        NavigationStack {
          GoogleAccountView()
            .toolbar {
              ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { showingGoogleSheet = false }
              }
            }
        }
      }
      .sheet(isPresented: $showAddServer) {
        MCPServerSheetIOS { name, url, token, _ in
          Task { await addServer(name: name, url: url, token: token) }
        }
      }
      .sheet(item: $editingServer) { ctx in
        MCPServerSheetIOS(existing: ctx.server, hasStoredToken: ctx.hasToken) { name, url, token, removeToken in
          Task { await editServer(ctx.server, name: name, url: url, token: token, removeToken: removeToken) }
        }
      }
  }

  // MARK: - Expansion

  private func toggleExpanded(_ key: String) {
    if expandedRows.contains(key) {
      expandedRows.remove(key)
    } else {
      expandedRows.insert(key)
    }
    UISelectionFeedbackGenerator().selectionChanged()
  }

  /// What each native integration can do in Action mode. Static — these
  /// are the adapters we ship, not a live tool list.
  static func nativeActions(_ id: Integration.Identifier) -> [(symbol: String, label: String)] {
    switch id {
    case .appleReminders:
      [("checklist", "Create reminders — due date, list, priority")]
    case .calendar:
      [("calendar.badge.plus", "Create calendar events — title, start & end, calendar")]
    case .todoist:
      [("checkmark.circle", "Create tasks — project, due date, priority")]
    case .gmail:
      [("square.and.pencil", "Draft emails — recipient, subject, body")]
    case .googleCalendar:
      [("calendar.badge.plus", "Create events — title, time, attendees")]
    default:
      []
    }
  }

  /// "dex_create_contact" → "Create contact" (the server prefix is noise
  /// when it's sitting under that server's own row). Split on both
  /// underscores and hyphens first, THEN drop the leading server word —
  /// tool names vary in separator style across servers.
  private func prettyToolName(_ raw: String, serverName: String) -> String {
    var words = raw
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(separator: " ")
      .map(String.init)
    if words.count > 1, words[0].lowercased() == serverName.lowercased() {
      words.removeFirst()
    }
    let joined = words.joined(separator: " ")
    return joined.prefix(1).uppercased() + joined.dropFirst()
  }

  /// Expanded content for an MCP-backed row: the live tool list, a
  /// loading state while it fetches, or a hint when not connected.
  @ViewBuilder
  private func mcpExpansion(server: MCPServerConfig?) -> some View {
    if let server {
      if let tools = toolLists[server.id], !tools.isEmpty {
        ForEach(tools, id: \.name) { tool in
          expansionLine(
            symbol: "wrench.and.screwdriver",
            title: prettyToolName(tool.name, serverName: server.name),
            detail: tool.description
          )
        }
      } else if busyServers.contains(server.id) {
        HStack(spacing: 8) {
          ProgressView().controlSize(.mini)
          Text("Loading tools…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
      } else if let error = serverErrors[server.id] {
        Text(error)
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Text("No tools reported. Try Refresh Tools from the long-press menu.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      Text("Connect to see this service's tools.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

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
    }
    .padding(.vertical, 2)
  }

  // MARK: - Native rows

  private func nativeRow(_ integration: Integration) -> some View {
    ConnectionRow(
      icon: integration.systemImage,
      tintHex: integration.tintHex,
      name: integration.name,
      requiresPro: integration.requiresPro,
      isConnected: isConnected(integration),
      canConnect: canConnect(integration),
      isExpanded: expandedRows.contains(integration.identifier.rawValue),
      onToggle: { toggle(integration) },
      onToggleExpanded: { toggleExpanded(integration.identifier.rawValue) }
    ) {
      ForEach(Self.nativeActions(integration.identifier), id: \.label) { action in
        expansionLine(symbol: action.symbol, title: action.label, detail: nil)
      }
    }
  }

  // MARK: - Featured MCP rows

  /// The stored server backing a featured brand, if connected.
  private func server(for brand: ConnectionBrand) -> MCPServerConfig? {
    servers.first { ConnectionDirectory.brand(forServerNamed: $0.name, url: $0.url)?.id == brand.id }
  }

  @ViewBuilder
  private func featuredRow(_ brand: ConnectionBrand) -> some View {
    let existing = server(for: brand)
    ConnectionRow(
      icon: brand.systemImage,
      tintHex: brand.tintHex,
      name: brand.name.capitalized,
      statusText: existing.flatMap { serverErrors[$0.id] },
      toolCount: existing.flatMap { toolCounts[$0.id] },
      requiresPro: false,
      isConnected: existing != nil,
      canConnect: true,
      isBusy: existing.map { busyServers.contains($0.id) } ?? false,
      isExpanded: expandedRows.contains(brand.id),
      onToggle: {
        if let existing {
          Task { await deleteServer(existing) }
        } else {
          Task { await connectFeatured(brand) }
        }
      },
      onToggleExpanded: {
        toggleExpanded(brand.id)
        // First expansion of a connected server with a cold cache: fetch.
        if expandedRows.contains(brand.id), let existing, toolLists[existing.id] == nil {
          Task { await refreshServer(existing) }
        }
      }
    ) {
      mcpExpansion(server: existing)
    }
    .contextMenu {
      if let existing {
        Button("Refresh Tools", systemImage: "arrow.clockwise") {
          Task { await refreshServer(existing) }
        }
        if signedIn[existing.id] == true {
          Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
            Task {
              await IOSMCPOAuthClient.signOut(existing)
              signedIn[existing.id] = false
            }
          }
        } else {
          Button("Sign In…", systemImage: "person.crop.circle.badge.checkmark") {
            Task { await signIn(existing) }
          }
        }
        Button("Edit…", systemImage: "pencil") {
          Task { await beginEdit(existing) }
        }
      }
    }
  }

  /// One-tap connect: create the server from the directory entry, then
  /// refresh; a 401 auto-starts the browser sign-in (standard MCP OAuth).
  private func connectFeatured(_ brand: ConnectionBrand) async {
    await addServer(name: brand.name, url: brand.mcpURL, token: "")
  }

  // MARK: - Custom server rows

  private func customServerRow(_ server: MCPServerConfig) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(expandedRows.contains(server.id.uuidString) ? 90 : 0))
        VStack(alignment: .leading, spacing: 2) {
          Text(server.name)
            .font(.body.weight(.medium))
          statusLine(server)
        }
        Spacer()
        if busyServers.contains(server.id) {
          ProgressView()
            .controlSize(.small)
        }
        Toggle("", isOn: Binding(
          get: { server.isEnabled },
          set: { enabled in setEnabled(enabled, for: server) }
        ))
        .labelsHidden()
      }
      .contentShape(Rectangle())
      .onTapGesture {
        toggleExpanded(server.id.uuidString)
        if expandedRows.contains(server.id.uuidString), toolLists[server.id] == nil {
          Task { await refreshServer(server) }
        }
      }

      if expandedRows.contains(server.id.uuidString) {
        VStack(alignment: .leading, spacing: 2) {
          mcpExpansion(server: server)
        }
        .padding(.top, 8)
        .padding(.leading, 16)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button(role: .destructive) {
        Task { await deleteServer(server) }
      } label: {
        Label("Delete", systemImage: "trash")
      }
      Button {
        Task { await beginEdit(server) }
      } label: {
        Label("Edit", systemImage: "pencil")
      }
      .tint(.blue)
    }
    .contextMenu {
      Button("Refresh Tools", systemImage: "arrow.clockwise") {
        Task { await refreshServer(server) }
      }
      if signedIn[server.id] == true {
        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
          Task {
            await IOSMCPOAuthClient.signOut(server)
            signedIn[server.id] = false
          }
        }
      } else {
        Button("Sign In…", systemImage: "person.crop.circle.badge.checkmark") {
          Task { await signIn(server) }
        }
      }
      Button("Edit…", systemImage: "pencil") {
        Task { await beginEdit(server) }
      }
      Button("Delete", systemImage: "trash", role: .destructive) {
        Task { await deleteServer(server) }
      }
    }
  }

  @ViewBuilder
  private func statusLine(_ server: MCPServerConfig) -> some View {
    if let error = serverErrors[server.id] {
      Text(error)
        .font(.caption2)
        .foregroundStyle(.orange)
        .lineLimit(2)
    } else if let count = toolCounts[server.id] {
      Text("\(count) tool\(count == 1 ? "" : "s")\(signedIn[server.id] == true ? " · signed in" : "")")
        .font(.caption2)
        .foregroundStyle(.secondary)
    } else {
      Text(server.url)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  // MARK: - MCP server management

  private func reloadServers() async {
    servers = MCPServersStorage.load()
    for server in servers {
      if let entry = await MCPToolCatalog.shared.cachedTools(for: server.id) {
        toolCounts[server.id] = entry.tools.count
        toolLists[server.id] = entry.tools
      }
      signedIn[server.id] = await IOSMCPOAuthClient.isSignedIn(server)
    }
  }

  private func persistServers() {
    MCPServersStorage.save(servers)
  }

  private func setEnabled(_ enabled: Bool, for server: MCPServerConfig) {
    if let idx = servers.firstIndex(where: { $0.id == server.id }) {
      servers[idx].isEnabled = enabled
      persistServers()
      if enabled {
        Task { await refreshServer(servers[idx]) }
      }
    }
  }

  private func addServer(name: String, url: String, token: String) async {
    let server = MCPServerConfig(name: name, url: url)
    if !token.isEmpty {
      _ = KeychainStore.save(account: server.keychainTokenKey, value: token)
    }
    servers.append(server)
    persistServers()
    let error = await refreshServer(server)
    guard token.isEmpty else { return }
    // No static token + server demands auth → kick off the browser sign-in
    // automatically (matches how OAuth MCP servers expect to be added).
    if isAuthError(error) {
      await signIn(server)
    } else if error == nil, await IOSMCPOAuthClient.advertisesOAuth(server) {
      // The catalog fetch succeeded anonymously, but the server publishes
      // OAuth metadata — some (Dex) only 401 the actual tool calls. Sign in
      // NOW so the first voice action doesn't fail with an auth error.
      await signIn(server)
    }
  }

  @discardableResult
  private func refreshServer(_ server: MCPServerConfig) async -> Error? {
    busyServers.insert(server.id)
    defer { busyServers.remove(server.id) }
    let token = await IOSMCPOAuthClient.resolveAuthToken(for: server)
    do {
      let tools = try await MCPToolCatalog.shared.refresh(server: server, authToken: token)
      toolCounts[server.id] = tools.count
      toolLists[server.id] = tools
      serverErrors[server.id] = nil
      return nil
    } catch {
      serverErrors[server.id] = error.localizedDescription
      return error
    }
  }

  private func signIn(_ server: MCPServerConfig) async {
    do {
      try await IOSMCPOAuthClient.signIn(server: server)
      signedIn[server.id] = true
      serverErrors[server.id] = nil
      await refreshServer(server)
    } catch {
      serverErrors[server.id] = error.localizedDescription
    }
  }

  private func isAuthError(_ error: Error?) -> Bool {
    guard let mcp = error as? MCPError, case let .httpError(code, _) = mcp else { return false }
    return code == 401 || code == 403
  }

  private func deleteServer(_ server: MCPServerConfig) async {
    servers.removeAll { $0.id == server.id }
    persistServers()
    await MCPToolCatalog.shared.remove(serverID: server.id)
    IOSMCPOAuthClient.deleteAllCredentials(for: server)
  }

  private func beginEdit(_ server: MCPServerConfig) async {
    let hasToken = !(KeychainStore.read(account: server.keychainTokenKey).value ?? "").isEmpty
    editingServer = MCPEditContext(server: server, hasToken: hasToken)
  }

  private func editServer(
    _ server: MCPServerConfig, name: String, url: String, token: String, removeToken: Bool
  ) async {
    if let idx = servers.firstIndex(where: { $0.id == server.id }) {
      servers[idx].name = name
      servers[idx].url = url
      persistServers()
    }
    if removeToken {
      _ = KeychainStore.delete(account: server.keychainTokenKey)
    } else if !token.isEmpty {
      _ = KeychainStore.save(account: server.keychainTokenKey, value: token)
    }
    var updated = server
    updated.name = name
    updated.url = url
    await refreshServer(updated)
  }

  // MARK: - Native integrations (unchanged logic)

  private var connected: Set<Integration.Identifier> {
    IntegrationConnectionStore.decode(connectedData)
  }

  /// The free-tier cap only counts non-Pro integrations toward the
  /// quota — Pro integrations (Gmail, Google Calendar, etc.) come in
  /// through their own OAuth path and would otherwise squeeze out the
  /// free ones.
  private var connectedFreeCount: Int {
    connected.filter { id in
      Integration.all.first(where: { $0.identifier == id })?.requiresPro == false
    }.count
  }

  private func isConnected(_ integration: Integration) -> Bool {
    // For Gmail / Google Calendar, OAuth keychain state wins over the
    // UserDefaults integration set.
    if integration.identifier == .gmail || integration.identifier == .googleCalendar {
      return IOSGoogleOAuthClient.isAuthorized()
    }
    return connected.contains(integration.identifier)
  }

  private func canConnect(_ integration: Integration) -> Bool {
    if isConnected(integration) { return true }
    if integration.requiresPro { return false }
    return connectedFreeCount < IntegrationLimits.freeTierMaxConnections
  }

  private func toggle(_ integration: Integration) {
    var current = connected

    if isConnected(integration) {
      current.remove(integration.identifier)
      // Disconnecting either Gmail or Google Calendar revokes both
      // (single sign-in covers both scopes). Mirrors the macOS toggle.
      if integration.identifier == .gmail || integration.identifier == .googleCalendar {
        current.remove(.gmail)
        current.remove(.googleCalendar)
        IOSGoogleOAuthClient.disconnect()
      }
      connectedData = IntegrationConnectionStore.encode(current)
      if integration.identifier == .todoist {
        KeychainStore.delete(account: KeychainKey.todoistAPIToken)
      }
      UISelectionFeedbackGenerator().selectionChanged()
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
      showingGoogleSheet = true
    default:
      break
    }
    UISelectionFeedbackGenerator().selectionChanged()
  }
}

// MARK: - Shared row

/// One row style for every connection — native or MCP-backed. The user
/// shouldn't be able to tell which protocol a row uses. Tight by design:
/// icon + name + Connect. Tapping the row expands it to list the tools
/// or actions the connection offers (taglines used to live here — the
/// expansion replaced them).
private struct ConnectionRow<Expansion: View>: View {
  let icon: String
  let tintHex: String
  let name: String
  /// Inline error (connection failures). nil when healthy.
  var statusText: String? = nil
  /// Tool count chip for connected MCP rows.
  var toolCount: Int? = nil
  let requiresPro: Bool
  let isConnected: Bool
  let canConnect: Bool
  var isBusy: Bool = false
  let isExpanded: Bool
  let onToggle: () -> Void
  let onToggleExpanded: () -> Void
  @ViewBuilder let expansion: () -> Expansion

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))

        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Color(hex: tintHex) ?? QuillDesign.mcpTile)
          .frame(width: 28, height: 28)
          .overlay(
            Image(systemName: icon)
              .foregroundStyle(.white)
              .font(.system(size: 13, weight: .semibold))
          )

        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(name)
              .font(.body.weight(.medium))
            if requiresPro {
              Text("PRO")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.purple))
            }
            if let toolCount {
              Text("\(toolCount)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
          }
          if let statusText {
            Text(statusText)
              .font(.caption2)
              .foregroundStyle(.orange)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 8)

        if isBusy {
          ProgressView()
            .controlSize(.small)
        } else {
          Button(isConnected ? "Disconnect" : "Connect", action: onToggle)
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(isConnected ? .red : .purple)
            .disabled(!canConnect && !isConnected)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture(perform: onToggleExpanded)

      if isExpanded {
        VStack(alignment: .leading, spacing: 2) {
          expansion()
        }
        .padding(.top, 8)
        // Light indent only — aligning under the name (48pt) wasted a
        // third of the row width on whitespace once descriptions wrapped.
        .padding(.leading, 16)
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Add/Edit MCP server sheet

struct MCPEditContext: Identifiable {
  let server: MCPServerConfig
  let hasToken: Bool
  var id: UUID { server.id }
}

struct MCPServerSheetIOS: View {
  var existing: MCPServerConfig?
  var hasStoredToken = false
  /// (name, url, token, removeToken)
  var onSave: (String, String, String, Bool) -> Void

  @Environment(\.dismiss) private var dismiss
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

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
      && URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name (e.g. dex)", text: $name)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
          TextField("https://mcp.example.com/mcp", text: $url)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        } footer: {
          Text("The short name is how you'll refer to this server by voice.")
        }

        Section {
          SecureField(hasStoredToken ? "••••••••  (stored)" : "Bearer token (optional)", text: $token)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
          if hasStoredToken {
            Toggle("Remove stored token", isOn: $removeToken)
          }
        } footer: {
          Text("Leave empty for servers that sign in with a browser (OAuth) — you'll be prompted automatically.")
        }
      }
      .navigationTitle(existing == nil ? "Add MCP Server" : "Edit MCP Server")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(existing == nil ? "Add" : "Save") {
            onSave(
              name.trimmingCharacters(in: .whitespaces),
              url.trimmingCharacters(in: .whitespaces),
              token.trimmingCharacters(in: .whitespaces),
              removeToken
            )
            dismiss()
          }
          .disabled(!canSave)
        }
      }
    }
  }
}
