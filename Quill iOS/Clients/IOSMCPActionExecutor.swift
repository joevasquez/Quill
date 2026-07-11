//
//  IOSMCPActionExecutor.swift
//  Quill (iOS)
//
//  Executes an `.mcpCall` ActionIntent on iOS: resolves the named server
//  from `MCPServersStorage`, gets its bearer token via `IOSMCPOAuthClient`,
//  coerces the LLM's string arguments to the tool's schema types (shared
//  HexCore helpers), and drives MCPClient. Called from the confirmation
//  sheet and the offline queue replay.
//

import Foundation
import HexCore
import os

private let mcpExecLogger = HexLog.action

enum IOSMCPExecutionError: LocalizedError {
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

@MainActor
enum IOSMCPActionExecutor {
  /// Runs the call and returns the tool's text result (shown + copied by
  /// the confirmation sheet, and fed to dependent steps).
  static func execute(_ intent: ActionIntent) async throws -> String {
    guard intent.actionType == .mcpCall,
          let serverName = intent.mcpServerName,
          let toolName = intent.mcpTool
    else { throw IOSMCPExecutionError.notAnMCPIntent }

    guard let server = MCPServersStorage.load().first(where: {
      $0.isEnabled && $0.name.caseInsensitiveCompare(serverName) == .orderedSame
    }) else {
      throw IOSMCPExecutionError.unknownServer(serverName)
    }

    // OAuth access token (refreshed if needed) when the server is
    // OAuth-connected, else the static bearer token.
    let token = await IOSMCPOAuthClient.resolveAuthToken(for: server)

    // Coerce string arguments to the schema's declared types where we have
    // a cached schema; unknown properties stay strings.
    let schemaTypes = await MCPToolCatalog.shared.propertyTypes(serverID: server.id, toolName: toolName)
    let arguments = MCPToolCatalog.coerceArguments(intent.mcpArguments ?? [:], types: schemaTypes)

    mcpExecLogger.info("MCP call: \(server.name, privacy: .private)/\(toolName, privacy: .private) with \(arguments.count, privacy: .public) argument(s)")

    let client = try MCPClient(url: server.url, authToken: token)
    try await client.connect()
    let result = try await client.callTool(name: toolName, arguments: arguments)
    // Read/query tools return content the user wants to see, so keep a
    // generous slice.
    return result.isEmpty ? "Done" : String(result.prefix(4000))
  }
}
