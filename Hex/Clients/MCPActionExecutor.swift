//
//  MCPActionExecutor.swift
//  Quill (macOS)
//
//  Executes an `.mcpCall` ActionIntent: resolves the named server from
//  settings, reads its bearer token from the keychain, coerces the LLM's
//  string arguments to the tool's schema types, and drives MCPClient.
//  Called from the confirmation panel and the offline queue replay.
//

import ComposableArchitecture
import Dependencies
import Foundation
import HexCore
import os

private let mcpExecLogger = HexLog.action

enum MCPExecutionError: LocalizedError {
  case notAnMCPIntent
  case unknownServer(String)

  var errorDescription: String? {
    switch self {
    case .notAnMCPIntent:
      "Not an MCP action"
    case .unknownServer(let name):
      "No connected MCP server named \u{201C}\(name)\u{201D} — check Settings → Agent"
    }
  }
}

enum MCPActionExecutor {
  /// Runs the call and returns the tool's text result (used as the
  /// created-item id/summary by the confirmation panel).
  static func execute(_ intent: ActionIntent) async throws -> String {
    guard intent.actionType == .mcpCall,
          let serverName = intent.mcpServerName,
          let toolName = intent.mcpTool
    else { throw MCPExecutionError.notAnMCPIntent }

    @Shared(.hexSettings) var hexSettings: HexSettings
    guard let server = hexSettings.mcpServers.first(where: {
      $0.isEnabled && $0.name.caseInsensitiveCompare(serverName) == .orderedSame
    }) else {
      throw MCPExecutionError.unknownServer(serverName)
    }

    // OAuth access token (refreshed if needed) when the server is
    // OAuth-connected, else the static bearer token.
    let token = await MCPOAuthClient.resolveAuthToken(for: server)

    // Coerce string arguments to the schema's declared types where we have
    // a cached schema; unknown properties stay strings.
    let schemaTypes = await propertyTypes(serverID: server.id, toolName: toolName)
    let arguments = coerce(intent.mcpArguments ?? [:], types: schemaTypes)

    mcpExecLogger.info("MCP call: \(server.name, privacy: .private)/\(toolName, privacy: .private) with \(arguments.count, privacy: .public) argument(s)")

    let client = try MCPClient(url: server.url, authToken: token)
    try await client.connect()
    let result = try await client.callTool(name: toolName, arguments: arguments)
    return result.isEmpty ? "Done" : String(result.prefix(500))
  }

  /// property name → declared JSON Schema type ("integer", "number",
  /// "boolean", "string", …) from the cached tools/list entry.
  private static func propertyTypes(serverID: UUID, toolName: String) async -> [String: String] {
    guard let entry = await MCPToolCatalog.shared.cachedTools(for: serverID),
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

  static func coerce(_ stringArgs: [String: String], types: [String: String]) -> [String: Any] {
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
}
