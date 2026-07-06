//
//  MCPToolCatalog.swift
//  HexCore
//
//  Caches each MCP server's tool list so Action-mode parsing can embed
//  available tools in the planner prompt without a network round-trip per
//  dictation. Refreshed on demand (settings changes, app launch) and
//  opportunistically after a successful call.
//

import Foundation
import os

private let catalogLogger = HexLog.app

public actor MCPToolCatalog {
  public static let shared = MCPToolCatalog()

  public struct Entry: Sendable {
    public let server: MCPServerConfig
    public let tools: [MCPTool]
    public let fetchedAt: Date
  }

  private var entries: [UUID: Entry] = [:]
  private let maxAge: TimeInterval = 15 * 60

  public init() {}

  /// Cached tools for a server; nil if never fetched or stale.
  public func cachedTools(for serverID: UUID) -> Entry? {
    guard let entry = entries[serverID] else { return nil }
    guard Date().timeIntervalSince(entry.fetchedAt) < maxAge else { return nil }
    return entry
  }

  /// Fetch (or refresh) a server's tool list. Returns the tools on success.
  @discardableResult
  public func refresh(server: MCPServerConfig, authToken: String?) async throws -> [MCPTool] {
    let client = try MCPClient(url: server.url, authToken: authToken)
    try await client.connect()
    let tools = try await client.listTools()
    entries[server.id] = Entry(server: server, tools: tools, fetchedAt: Date())
    catalogLogger.info("MCP catalog: \(server.name, privacy: .private) advertises \(tools.count, privacy: .public) tool(s)")
    return tools
  }

  public func remove(serverID: UUID) {
    entries[serverID] = nil
  }

  /// Renders the cached catalog as a prompt section for the action parser.
  /// Returns nil when no enabled server has cached tools — the prompt stays
  /// unchanged and the LLM never invents MCP calls.
  public func promptContext(servers: [MCPServerConfig]) -> String? {
    let enabled = servers.filter(\.isEnabled)
    guard !enabled.isEmpty else { return nil }

    var lines: [String] = []
    for server in enabled {
      guard let entry = entries[server.id], !entry.tools.isEmpty else { continue }
      for tool in entry.tools {
        var line = "- server: \(server.name), tool: \(tool.name)"
        if let description = tool.description, !description.isEmpty {
          line += " — \(description.prefix(200))"
        }
        if let schema = tool.inputSchemaJSON, schema.count < 600 {
          line += " (arguments schema: \(schema))"
        }
        lines.append(line)
      }
    }
    guard !lines.isEmpty else { return nil }

    return """
    MCP tools available (Model Context Protocol servers the user has connected):
    \(lines.joined(separator: "\n"))

    To invoke an MCP tool, emit an action with:
    - "actionType": "mcpCall"
    - "targetIntegration": "appleReminders" (required by the schema; ignored for MCP calls)
    - "mcpServerName": the server name exactly as listed above
    - "mcpTool": the tool name exactly as listed above
    - "mcpArguments": an object of argument name → value (strings, numbers, booleans as strings are acceptable) matching the tool's schema; omit optional arguments the user didn't mention
    - "title": a short human-readable description of what this call does (shown on the confirmation card)
    Prefer a native integration (todoist, appleReminders, calendar, gmail) when one fits; use MCP tools when the user names the server/tool or the request clearly maps to one.
    """
  }
}
