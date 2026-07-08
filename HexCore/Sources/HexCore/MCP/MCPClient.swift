//
//  MCPClient.swift
//  HexCore
//
//  Minimal Model Context Protocol client (Streamable HTTP transport).
//  Speaks just enough MCP to make any remote MCP server a Hermes tool:
//  initialize → tools/list → tools/call. JSON-RPC 2.0 over POST; servers
//  may answer either application/json or text/event-stream — both are
//  handled. Stateful servers issue an Mcp-Session-Id header on initialize
//  which must be echoed on subsequent requests.
//

import Foundation
import os

private let mcpLogger = HexLog.app

// MARK: - Models

/// A user-configured remote MCP server. The bearer token (if any) is NOT
/// stored here — it lives in the keychain keyed by `MCPServerConfig.
/// keychainTokenKey`, same pattern as the Todoist token.
public struct MCPServerConfig: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  /// Short name the user (and the LLM) refers to the server by, e.g. "linear".
  public var name: String
  public var url: String
  public var isEnabled: Bool

  public init(id: UUID = UUID(), name: String, url: String, isEnabled: Bool = true) {
    self.id = id
    self.name = name
    self.url = url
    self.isEnabled = isEnabled
  }

  public var keychainTokenKey: String { "mcp_token_\(id.uuidString)" }
  /// Keychain key for the OAuth token blob (`MCPOAuthTokens` JSON) when the
  /// server authenticates via the MCP OAuth flow instead of a static token.
  public var oauthKeychainKey: String { "mcp_oauth_\(id.uuidString)" }
}

/// A tool advertised by an MCP server via tools/list.
public struct MCPTool: Codable, Equatable, Sendable {
  public var name: String
  public var description: String?
  /// Raw JSON Schema for the tool's arguments, re-serialized as a string
  /// so it can be embedded in the planner prompt.
  public var inputSchemaJSON: String?

  public init(name: String, description: String? = nil, inputSchemaJSON: String? = nil) {
    self.name = name
    self.description = description
    self.inputSchemaJSON = inputSchemaJSON
  }

  /// A compact, LLM-friendly summary of the tool's arguments parsed from the
  /// JSON Schema — e.g. `query (string, required), limit (integer)`. This is
  /// what goes in the planner prompt instead of the raw schema JSON: it's far
  /// smaller and reliably conveys the exact argument names, types, and which
  /// are required, so the model fills them correctly for any server. Returns
  /// nil when the schema declares no properties (tool takes no arguments).
  public var argumentSummary: String? {
    guard let json = inputSchemaJSON,
          let data = json.data(using: .utf8),
          let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let properties = schema["properties"] as? [String: Any],
          !properties.isEmpty
    else { return nil }

    let required = Set((schema["required"] as? [String]) ?? [])
    // Required args first, then alphabetical — stable and puts the essentials
    // up front.
    let names = properties.keys.sorted { a, b in
      let ra = required.contains(a), rb = required.contains(b)
      if ra != rb { return ra }
      return a < b
    }
    let parts = names.map { name -> String in
      let spec = properties[name] as? [String: Any]
      let type = (spec?["type"] as? String) ?? "string"
      var s = "\(name) (\(type)\(required.contains(name) ? ", required" : ""))"
      if let enumVals = spec?["enum"] as? [Any], enumVals.count <= 8 {
        s += " one of: " + enumVals.map { "\($0)" }.joined(separator: "|")
      }
      return s
    }
    return parts.joined(separator: ", ")
  }
}

public enum MCPError: LocalizedError {
  case invalidURL
  case httpError(Int, String)
  case rpcError(Int, String)
  case malformedResponse(String)

  public var errorDescription: String? {
    switch self {
    case .invalidURL:
      "Invalid MCP server URL"
    case .httpError(let code, _):
      switch code {
      case 401, 403:
        "Authentication failed (HTTP \(code)). This server needs a valid token — add or fix it in Settings → Agent → Tools. (Servers that require an OAuth sign-in aren't supported yet.)"
      case 404:
        "MCP server not found (HTTP 404) — check the URL in Settings → Agent → Tools."
      default:
        "MCP server returned HTTP \(code)"
      }
    case .rpcError(let code, let message):
      "MCP error \(code): \(message)"
    case .malformedResponse:
      "Malformed response from MCP server"
    }
  }
}

// MARK: - Client

/// One instance per server per session. Not an actor — each call sequence
/// (connect → list/call) is driven from a single task.
public final class MCPClient: @unchecked Sendable {
  private let serverURL: URL
  private let authToken: String?
  private var sessionID: String?
  private var nextRequestID = 1
  private let urlSession: URLSession

  public init(url: String, authToken: String? = nil, urlSession: URLSession = .shared) throws {
    guard let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true else {
      throw MCPError.invalidURL
    }
    self.serverURL = parsed
    self.authToken = authToken
    self.urlSession = urlSession
  }

  /// initialize + notifications/initialized handshake. Must be called
  /// before tools/list or tools/call.
  public func connect() async throws {
    let result = try await sendRequest(
      method: "initialize",
      params: [
        "protocolVersion": "2025-06-18",
        "capabilities": [:] as [String: Any],
        "clientInfo": ["name": "Quill", "version": "1.0"],
      ]
    )
    _ = result // server capabilities — unused in v1
    try await sendNotification(method: "notifications/initialized")
  }

  public func listTools() async throws -> [MCPTool] {
    let result = try await sendRequest(method: "tools/list", params: [:])
    guard let tools = result["tools"] as? [[String: Any]] else {
      throw MCPError.malformedResponse("tools/list result missing tools array")
    }
    return tools.compactMap { tool in
      guard let name = tool["name"] as? String else { return nil }
      var schemaJSON: String?
      if let schema = tool["inputSchema"],
         let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
        schemaJSON = String(data: data, encoding: .utf8)
      }
      return MCPTool(
        name: name,
        description: tool["description"] as? String,
        inputSchemaJSON: schemaJSON
      )
    }
  }

  /// Calls a tool and returns the concatenated text content of the result.
  public func callTool(name: String, arguments: [String: Any]) async throws -> String {
    let result = try await sendRequest(
      method: "tools/call",
      params: ["name": name, "arguments": arguments]
    )
    if let isError = result["isError"] as? Bool, isError {
      let text = Self.textContent(from: result)
      throw MCPError.rpcError(-1, text.isEmpty ? "Tool reported an error" : text)
    }
    return Self.textContent(from: result)
  }

  static func textContent(from result: [String: Any]) -> String {
    guard let content = result["content"] as? [[String: Any]] else { return "" }
    return content
      .compactMap { block -> String? in
        guard block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
      }
      .joined(separator: "\n")
  }

  // MARK: - JSON-RPC transport

  private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
    let requestID = nextRequestID
    nextRequestID += 1
    let body: [String: Any] = [
      "jsonrpc": "2.0",
      "id": requestID,
      "method": method,
      "params": params,
    ]
    let (data, response) = try await post(body)
    guard let http = response as? HTTPURLResponse else {
      throw MCPError.malformedResponse("Not an HTTP response")
    }
    if let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
      sessionID = newSession
    }
    guard (200 ..< 300).contains(http.statusCode) else {
      throw MCPError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    let json: [String: Any]
    let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
    if contentType.contains("text/event-stream") {
      guard let parsed = Self.parseSSEResponse(data: data, requestID: requestID) else {
        throw MCPError.malformedResponse("No matching JSON-RPC response in SSE stream")
      }
      json = parsed
    } else {
      guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MCPError.malformedResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
      }
      json = parsed
    }

    if let error = json["error"] as? [String: Any] {
      throw MCPError.rpcError(
        error["code"] as? Int ?? -1,
        error["message"] as? String ?? "unknown"
      )
    }
    guard let result = json["result"] as? [String: Any] else {
      throw MCPError.malformedResponse("Response missing result")
    }
    return result
  }

  private func sendNotification(method: String) async throws {
    let body: [String: Any] = ["jsonrpc": "2.0", "method": method]
    _ = try? await post(body) // notifications get no response; 202 expected
  }

  private func post(_ body: [String: Any]) async throws -> (Data, URLResponse) {
    var request = URLRequest(url: serverURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
    if let sessionID {
      request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    }
    request.timeoutInterval = 30
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return try await urlSession.data(for: request)
  }

  /// Extracts the JSON-RPC response matching `requestID` from an SSE body.
  /// Servers using the streaming side of Streamable HTTP wrap responses in
  /// `data: {...}` lines; the matching response may follow unrelated events.
  static func parseSSEResponse(data: Data, requestID: Int) -> [String: Any]? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.components(separatedBy: "\n") {
      guard line.hasPrefix("data:") else { continue }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      guard let payloadData = payload.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
      else { continue }
      if let id = json["id"] as? Int, id == requestID {
        return json
      }
    }
    return nil
  }
}
