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
  @Environment(\.dismiss) private var dismiss
  @AppStorage(IntegrationConnectionStore.userDefaultsKey) private var connectedData: Data = Data()

  @State private var showingTodoistSheet = false
  @State private var showingGoogleSheet = false

  // MCP state (shared by featured + custom sections)
  @State private var servers: [MCPServerConfig] = MCPServersStorage.load()
  @State private var toolCounts: [UUID: Int] = [:]
  @State private var serverErrors: [UUID: String] = [:]
  @State private var signedIn: [UUID: Bool] = [:]
  @State private var busyServers: Set<UUID> = []
  @State private var showAddServer = false
  @State private var editingServer: MCPEditContext?

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

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(nativeIntegrations) { integration in
            ConnectionRow(
              icon: integration.systemImage,
              tintHex: integration.tintHex,
              name: integration.name,
              subtitle: integration.tagline,
              requiresPro: integration.requiresPro,
              isConnected: isConnected(integration),
              canConnect: canConnect(integration),
              onToggle: { toggle(integration) }
            )
          }
          ForEach(ConnectionDirectory.featured) { brand in
            featuredRow(brand)
          }
        } header: {
          Text("Apps & services")
        } footer: {
          Text("Dictate naturally — \"remind me Friday to review the launch deck\" becomes a task; \"log a note on Joe in Dex\" calls the service directly. Free plan includes \(IntegrationLimits.freeTierMaxConnections) integrations; Pro unlocks all.")
        }

        Section {
          if customServers.isEmpty {
            Label("No custom servers", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            ForEach(customServers) { server in
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
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
      }
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
      subtitle: statusText(for: existing) ?? brand.tagline,
      requiresPro: false,
      isConnected: existing != nil,
      canConnect: true,
      isBusy: existing.map { busyServers.contains($0.id) } ?? false,
      onToggle: {
        if let existing {
          Task { await deleteServer(existing) }
        } else {
          Task { await connectFeatured(brand) }
        }
      }
    )
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

  private func statusText(for server: MCPServerConfig?) -> String? {
    guard let server else { return nil }
    if let error = serverErrors[server.id] { return error }
    if let count = toolCounts[server.id] {
      return "\(count) tool\(count == 1 ? "" : "s")\(signedIn[server.id] == true ? " · signed in" : "")"
    }
    return "Connected"
  }

  /// One-tap connect: create the server from the directory entry, then
  /// refresh; a 401 auto-starts the browser sign-in (standard MCP OAuth).
  private func connectFeatured(_ brand: ConnectionBrand) async {
    await addServer(name: brand.name, url: brand.mcpURL, token: "")
  }

  // MARK: - Custom server rows

  private func customServerRow(_ server: MCPServerConfig) -> some View {
    HStack {
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
    // No static token + server demands auth → kick off the browser sign-in
    // automatically (matches how OAuth MCP servers expect to be added).
    if token.isEmpty, isAuthError(error) {
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
/// shouldn't be able to tell which protocol a row uses.
private struct ConnectionRow: View {
  let icon: String
  let tintHex: String
  let name: String
  let subtitle: String
  let requiresPro: Bool
  let isConnected: Bool
  let canConnect: Bool
  var isBusy: Bool = false
  let onToggle: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(hex: tintHex) ?? QuillDesign.mcpTile)
        .frame(width: 38, height: 38)
        .overlay(
          Image(systemName: icon)
            .foregroundStyle(.white)
            .font(.system(size: 18, weight: .semibold))
        )

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(name)
            .font(.body.weight(.semibold))
          if requiresPro {
            Text("PRO")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(Capsule().fill(Color.purple))
          }
        }
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      Spacer(minLength: 8)

      if isBusy {
        ProgressView()
          .controlSize(.small)
      } else {
        Button(isConnected ? "Disconnect" : "Connect", action: onToggle)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .tint(isConnected ? .red : .purple)
          .disabled(!canConnect && !isConnected)
      }
    }
    .padding(.vertical, 6)
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
