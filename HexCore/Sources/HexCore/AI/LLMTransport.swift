//
//  LLMTransport.swift
//  HexCore
//
//  Single LLM round-trip shared by both app targets. Callers resolve a
//  credential themselves (macOS: KeychainClient / GoogleOAuthClient; iOS:
//  KeychainStore / IOSGoogleOAuthClient) and pass it as a value — HexCore
//  never touches the keychain. Pro-plan users route through the Quill AI
//  proxy (server-side Anthropic key); BYOK users hit the provider directly.
//

import Foundation
import os

private let transportLogger = HexLog.aiProcessing

/// How an LLM call authenticates. Resolved by the caller per request.
public enum LLMCredential: Sendable {
  /// Bring-your-own-key: direct call to the provider's API.
  case byok(apiKey: String, provider: AIProvider)
  /// Pro plan: route through the Quill AI proxy with a Google OAuth
  /// access token. The proxy holds the Anthropic key server-side.
  case proProxy(accessToken: String)
}

public enum LLMTransportError: LocalizedError, HTTPStatusCarrying {
  case apiError(Int, String)
  case invalidResponse

  public var httpStatusCode: Int? {
    if case .apiError(let code, _) = self { return code }
    return nil
  }

  public var errorDescription: String? {
    switch self {
    case .apiError(let code, _):
      "AI service returned HTTP \(code)"
    case .invalidResponse:
      "Unexpected response from AI service"
    }
  }
}

public enum LLMTransport {
  /// Quill AI proxy — a Cloudflare Worker (`tools/cloudflare/quill-ai-proxy`).
  ///
  /// Moved off GCP Cloud Functions on 2026-08-05: project quill-495210's
  /// Artifact Registry was left unusable by the 2026-07-31 delete/undelete,
  /// so the function could no longer be redeployed. The Worker also reads Pro
  /// entitlement straight from the dashboard's D1 rather than over HTTP.
  ///
  /// The request/response contract is unchanged. Builds shipped before this
  /// change still point at the Cloud Function URL, so leave that deployment
  /// running until they have aged out.
  public static let proProxyURL = "https://quill-api.joevasquez.com"

  /// One LLM completion. `jsonResponse` opts OpenAI into
  /// `response_format: json_object` (the system prompt must mention JSON);
  /// Anthropic and the Pro proxy ignore it. `temperature` applies to
  /// OpenAI only, matching the pre-consolidation per-target behavior.
  public static func complete(
    userMessage: String,
    systemPrompt: String,
    credential: LLMCredential,
    maxTokens: Int = 1024,
    temperature: Double = 0.1,
    jsonResponse: Bool = true,
    timeout: TimeInterval = 15
  ) async throws -> String {
    switch credential {
    case .proProxy(let accessToken):
      return try await callProProxy(
        userMessage: userMessage,
        systemPrompt: systemPrompt,
        accessToken: accessToken,
        maxTokens: maxTokens
      )
    case .byok(let apiKey, let provider):
      let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      switch provider {
      case .openAI:
        return try await callOpenAI(
          userMessage: userMessage,
          systemPrompt: systemPrompt,
          apiKey: key,
          maxTokens: maxTokens,
          temperature: temperature,
          jsonResponse: jsonResponse,
          timeout: timeout
        )
      case .anthropic:
        return try await callAnthropic(
          userMessage: userMessage,
          systemPrompt: systemPrompt,
          apiKey: key,
          maxTokens: maxTokens,
          timeout: timeout
        )
      }
    }
  }

  /// Remove markdown code fences the model sometimes wraps JSON in.
  public static func stripFences(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Pro proxy

  static func callProProxy(
    userMessage: String,
    systemPrompt: String,
    accessToken: String,
    maxTokens: Int = 2048
  ) async throws -> String {
    let url = URL(string: proProxyURL)!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30

    let body: [String: Any] = [
      "systemPrompt": systemPrompt,
      "userMessage": userMessage,
      // Honored by the proxy (clamped server-side); older deployments
      // ignore it and use their built-in default.
      "maxTokens": maxTokens,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    transportLogger.info("Pro proxy call (\(userMessage.count, privacy: .public) chars)")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let http = response as? HTTPURLResponse else {
      throw LLMTransportError.invalidResponse
    }
    guard http.statusCode == 200 else {
      let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
      transportLogger.error("Pro proxy error \(http.statusCode, privacy: .public): \(errorBody, privacy: .private)")
      throw LLMTransportError.apiError(http.statusCode, errorBody)
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = json["content"] as? String
    else {
      throw LLMTransportError.invalidResponse
    }
    return content
  }

  // MARK: - OpenAI

  private static func callOpenAI(
    userMessage: String,
    systemPrompt: String,
    apiKey: String,
    maxTokens: Int,
    temperature: Double,
    jsonResponse: Bool,
    timeout: TimeInterval
  ) async throws -> String {
    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = timeout

    var body: [String: Any] = [
      "model": AIProvider.openAI.defaultModel,
      "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": userMessage],
      ],
      "temperature": temperature,
      "max_tokens": maxTokens,
    ]
    if jsonResponse {
      body["response_format"] = ["type": "json_object"]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    try ensureOK(response: response, data: data)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let choices = json?["choices"] as? [[String: Any]],
          let first = choices.first,
          let msg = first["message"] as? [String: Any],
          let content = msg["content"] as? String
    else { throw LLMTransportError.invalidResponse }
    return content
  }

  // MARK: - Anthropic

  private static func callAnthropic(
    userMessage: String,
    systemPrompt: String,
    apiKey: String,
    maxTokens: Int,
    timeout: TimeInterval
  ) async throws -> String {
    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = timeout

    let body: [String: Any] = [
      "model": AIProvider.anthropic.defaultModel,
      "system": systemPrompt,
      "messages": [["role": "user", "content": userMessage]],
      "max_tokens": maxTokens,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    try ensureOK(response: response, data: data)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let content = json?["content"] as? [[String: Any]],
          let first = content.first,
          let text = first["text"] as? String
    else { throw LLMTransportError.invalidResponse }
    return text
  }

  private static func ensureOK(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw LLMTransportError.invalidResponse
    }
    guard http.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw LLMTransportError.apiError(http.statusCode, body)
    }
  }
}
