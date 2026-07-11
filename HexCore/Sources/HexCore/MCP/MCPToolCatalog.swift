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

  /// property name → declared JSON Schema type ("integer", "number",
  /// "boolean", "string", …) from the cached tools/list entry. Used to
  /// coerce the LLM's string arguments before a tools/call.
  public func propertyTypes(serverID: UUID, toolName: String) -> [String: String] {
    guard let entry = entries[serverID],
          let tool = entry.tools.first(where: { $0.name == toolName }),
          let schemaJSON = tool.inputSchemaJSON,
          let data = schemaJSON.data(using: .utf8),
          let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let properties = schema["properties"] as? [String: Any]
    else { return [:] }

    var types: [String: String] = [:]
    for (name, spec) in properties {
      if let spec = spec as? [String: Any], let type = spec["type"] as? String {
        types[name] = type
      }
    }
    return types
  }

  /// Coerce the planner's string arguments to the schema's declared types.
  /// Unknown properties stay strings.
  public static func coerceArguments(_ stringArgs: [String: String], types: [String: String]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in stringArgs {
      switch types[key] {
      case "integer":
        result[key] = Int(value) ?? value
      case "number":
        result[key] = Double(value) ?? value
      case "boolean":
        result[key] = (value as NSString).boolValue
      default:
        result[key] = value
      }
    }
    return result
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
          line += " — \(description.prefix(240))"
        }
        // Argument names/types/required flags (parsed from the schema) so the
        // model fills the right keys. Reliable regardless of schema size.
        if let args = tool.argumentSummary {
          line += " | arguments: \(args)"
        } else {
          line += " | arguments: none"
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
    - "mcpArguments": an object of argument name → value. Use the EXACT argument names listed for the tool (in "arguments:" above), and ALWAYS include every argument marked "required" — infer a sensible value from the request when the user didn't state one explicitly (e.g. for a search tool's required "query", use the name or terms the user mentioned). Values are strings; numbers/booleans as strings are acceptable. Omit optional arguments the user didn't mention.
    - "title": a short human-readable description of what this call does (shown on the confirmation card)
    Prefer a native integration (todoist, appleReminders, calendar, gmail) when one fits; use MCP tools when the user names the server/tool or the request clearly maps to one.
    """
  }
}
