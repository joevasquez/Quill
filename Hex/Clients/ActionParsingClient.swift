import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os

private let actionLogger = HexLog.action

@DependencyClient
struct ActionParsingClient {
  var parse: @Sendable (String, AIProvider) async throws -> ActionIntent
  /// The third parameter is optional selected-text context: text the user
  /// had highlighted in the frontmost app, so "add this to …" resolves.
  var parseMulti: @Sendable (String, AIProvider, String?) async throws -> MultiActionResponse
  /// Between-steps resolve pass for chained actions: given a dependent
  /// `ActionIntent`, the raw text result of the step it depends on, the user's
  /// original request (for context), and the provider, fills the linking
  /// field(s) named by the intent's `resolveInstruction` (e.g. an email
  /// address from an MCP lookup) AND personalizes the action's text (greet the
  /// contact by the looked-up name) using facts from the prior result.
  var resolveStep: @Sendable (ActionIntent, String, String, AIProvider) async throws -> ActionIntent
  /// "Answer from tool result" pass: given the user's original request and a
  /// standalone MCP read/query result, extracts the specific answer they asked
  /// for (an email, a phone number, a one-line fact) — or "" if the result
  /// doesn't contain it / the request wasn't a question.
  var extractAnswer: @Sendable (String, String, AIProvider) async throws -> String
  /// Turns a dictated routine description ("when I say ship it, …") into a
  /// named trigger + steps draft.
  var parseRoutine: @Sendable (String, AIProvider) async throws -> RoutineDraft
  /// Background memory pass: distills durable entities (people, projects,
  /// preferences) from an Action-mode transcript.
  var extractMemory: @Sendable (String, AIProvider) async throws -> [MemoryCandidate]
}

extension ActionParsingClient: DependencyKey {
  static var liveValue: Self {
    .init(
      parse: { transcript, provider in
        let response = try await parseTranscript(transcript, provider: provider, selection: nil)
        guard let intent = response.actions.first else {
          throw ActionParsingError.parseFailure("Empty actions array")
        }
        return intent
      },
      parseMulti: { transcript, provider, selection in
        try await parseTranscript(transcript, provider: provider, selection: selection)
      },
      resolveStep: { intent, priorResult, request, provider in
        guard let instruction = intent.resolveInstruction, !instruction.isEmpty else {
          return intent
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let actionData = try? encoder.encode(intent),
              let actionJSON = String(data: actionData, encoding: .utf8) else {
          return intent
        }
        let userMessage = StepResolvePrompt.userMessage(
          actionJSON: actionJSON,
          priorResult: priorResult,
          instruction: instruction,
          request: request
        )
        let json = try await completeJSON(
          userMessage: userMessage,
          systemPrompt: StepResolvePrompt.prompt,
          provider: provider
        )
        guard let data = json.data(using: .utf8),
              let resolved = try? JSONDecoder().decode(ActionIntent.self, from: data) else {
          // Resolve failed to produce a valid intent — fall back to the
          // unresolved one so the step still runs with whatever it had.
          actionLogger.warning("Step resolve returned non-decodable JSON; using unresolved intent")
          return intent
        }
        return resolved
      },
      extractAnswer: { request, result, provider in
        let json = try await completeJSON(
          userMessage: AnswerExtractionPrompt.userMessage(request: request, result: result),
          systemPrompt: AnswerExtractionPrompt.prompt,
          provider: provider
        )
        guard let data = json.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: String].self, from: data) else {
          return ""
        }
        return obj["answer"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      },
      parseRoutine: { description, provider in
        let json = try await completeJSON(
          userMessage: TranscriptWrapper.wrap(description),
          systemPrompt: RoutineAuthoringPrompt.prompt,
          provider: provider
        )
        guard let data = json.data(using: .utf8) else {
          throw ActionParsingError.parseFailure(json)
        }
        return try JSONDecoder().decode(RoutineDraft.self, from: data)
      },
      extractMemory: { transcript, provider in
        let userMessage = TranscriptWrapper.wrap(transcript)

        // Prefer Apple's on-device model for memory extraction: it's a
        // background, low-stakes pass and running it locally means the
        // agent learns for free without the transcript leaving the Mac.
        // Any failure (unavailable, malformed JSON) falls through to the
        // cloud path.
        if let local = await OnDeviceModel.complete(
          systemPrompt: MemoryExtractionPrompt.prompt,
          userMessage: userMessage
        ) {
          let cleaned = local
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if let data = cleaned.data(using: .utf8),
             let response = try? JSONDecoder().decode(MemoryExtractionResponse.self, from: data) {
            actionLogger.info("Memory extraction ran on-device (\(response.entities.count, privacy: .public) entities)")
            return response.entities
          }
          actionLogger.warning("On-device memory extraction returned non-JSON; falling back to cloud")
        }

        let json = try await completeJSON(
          userMessage: userMessage,
          systemPrompt: MemoryExtractionPrompt.prompt,
          provider: provider
        )
        guard let data = json.data(using: .utf8) else {
          throw ActionParsingError.parseFailure(json)
        }
        return try JSONDecoder().decode(MemoryExtractionResponse.self, from: data).entities
      }
    )
  }
}

private func parseTranscript(_ transcript: String, provider: AIProvider, selection: String?) async throws -> MultiActionResponse {
  // Agent memory: append known people/projects/preferences so "email Mike"
  // resolves without clarifying questions. No-op when the store is empty.
  var systemPrompt = actionSystemPrompt
  let memories = await MemoryStore.shared.loadAll()
  if let context = MemoryContextBuilder.context(from: memories) {
    systemPrompt += "\n\n" + context
  }

  // MCP: list the user's connected servers' tools so the LLM can emit
  // mcpCall actions. No-op when no server has a cached tool catalog.
  @Shared(.hexSettings) var hexSettings: HexSettings
  if let mcpContext = await MCPToolCatalog.shared.promptContext(servers: hexSettings.mcpServers) {
    systemPrompt += "\n\n" + mcpContext
  }

  let jsonString = try await completeJSON(
    userMessage: TranscriptWrapper.wrapWithSelection(transcript, selection: selection),
    systemPrompt: systemPrompt,
    provider: provider
  )

  guard let data = jsonString.data(using: .utf8) else {
    throw ActionParsingError.parseFailure(jsonString)
  }

  // Try multi-action format first, fall back to single intent wrapped in array
  if let response = try? JSONDecoder().decode(MultiActionResponse.self, from: data) {
    actionLogger.info("Parsed \(response.actions.count, privacy: .public) action(s)")
    return response
  }

  let intent = try JSONDecoder().decode(ActionIntent.self, from: data)
  actionLogger.info("Parsed action: type=\(intent.actionType.rawValue, privacy: .public) title=\(intent.title, privacy: .private)")
  return MultiActionResponse(actions: [intent])
}

/// Shared LLM round-trip for all structured-JSON agent calls. Callers pass a
/// fully-built user message (transcript wrapping + optional selection block
/// already applied). Pro users route through the server-side proxy (no local
/// API key needed) — the same policy as `AIProcessingClient.process`; BYOK
/// users hit the provider directly.
private func completeJSON(userMessage: String, systemPrompt: String, provider: AIProvider) async throws -> String {
  actionLogger.info("Agent LLM call: \(userMessage.count, privacy: .public) chars via \(provider.displayName, privacy: .public)")

  let raw: String
  if isActionProModeActive() {
    @Dependency(\.googleOAuth) var googleOAuth
    guard let accessToken = try? await googleOAuth.refreshIfNeeded() else {
      throw ActionParsingError.missingAPIKey(provider)
    }
    raw = try await ProAIProxyClient.process(
      text: userMessage,
      systemPrompt: systemPrompt,
      accessToken: accessToken,
      skipTranscriptWrapping: true
    )
  } else {
    @Dependency(\.keychain) var keychain
    let keychainKey = provider == .openAI ? KeychainKey.openAIAPIKey : KeychainKey.anthropicAPIKey
    guard let key = await keychain.read(keychainKey), !key.isEmpty else {
      throw ActionParsingError.missingAPIKey(provider)
    }
    let apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    switch provider {
    case .openAI:
      raw = try await callOpenAI(userMessage: userMessage, systemPrompt: systemPrompt, apiKey: apiKey)
    case .anthropic:
      raw = try await callAnthropic(userMessage: userMessage, systemPrompt: systemPrompt, apiKey: apiKey)
    }
  }

  return raw
    .replacingOccurrences(of: "```json", with: "")
    .replacingOccurrences(of: "```", with: "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Mirrors `isProModeActive()` in AIProcessingClient (private there).
private func isActionProModeActive() -> Bool {
  @Shared(.hexSettings) var hexSettings: HexSettings
  guard hexSettings.selectedPlan == "pro" else { return false }
  let email = UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey)
  return email?.isEmpty == false
}

extension DependencyValues {
  var actionParsing: ActionParsingClient {
    get { self[ActionParsingClient.self] }
    set { self[ActionParsingClient.self] = newValue }
  }
}

// MARK: - System Prompt

private let actionSystemPrompt = ActionSystemPrompt.prompt

// MARK: - OpenAI

private func callOpenAI(userMessage: String, systemPrompt: String, apiKey: String) async throws -> String {
  let url = URL(string: "https://api.openai.com/v1/chat/completions")!
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  request.timeoutInterval = 15

  let body: [String: Any] = [
    "model": AIProvider.openAI.defaultModel,
    "response_format": ["type": "json_object"],
    "messages": [
      ["role": "system", "content": systemPrompt],
      ["role": "user", "content": userMessage],
    ],
    "temperature": 0.1,
    "max_tokens": 1024,
  ]
  request.httpBody = try JSONSerialization.data(withJSONObject: body)

  let (data, response) = try await URLSession.shared.data(for: request)

  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    let body = String(data: data, encoding: .utf8) ?? ""
    throw ActionParsingError.apiError(code, body)
  }

  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  guard let choices = json?["choices"] as? [[String: Any]],
        let first = choices.first,
        let msg = first["message"] as? [String: Any],
        let content = msg["content"] as? String
  else { throw ActionParsingError.invalidResponse }

  return content
}

// MARK: - Anthropic

private func callAnthropic(userMessage: String, systemPrompt: String, apiKey: String) async throws -> String {
  let url = URL(string: "https://api.anthropic.com/v1/messages")!
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
  request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
  request.timeoutInterval = 15

  let body: [String: Any] = [
    "model": AIProvider.anthropic.defaultModel,
    "system": systemPrompt,
    "messages": [["role": "user", "content": userMessage]],
    "max_tokens": 1024,
  ]
  request.httpBody = try JSONSerialization.data(withJSONObject: body)

  let (data, response) = try await URLSession.shared.data(for: request)

  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    let body = String(data: data, encoding: .utf8) ?? ""
    throw ActionParsingError.apiError(code, body)
  }

  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  guard let content = json?["content"] as? [[String: Any]],
        let first = content.first,
        let text = first["text"] as? String
  else { throw ActionParsingError.invalidResponse }

  return text
}

// MARK: - Errors

enum ActionParsingError: LocalizedError {
  case missingAPIKey(AIProvider)
  case apiError(Int, String)
  case invalidResponse
  case parseFailure(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey(let p):
      "No \(p.displayName) API key — add one in Settings."
    case .apiError(let code, _):
      "Action parsing failed (HTTP \(code))"
    case .invalidResponse:
      "Invalid response from AI service"
    case .parseFailure:
      "Could not parse action from AI response"
    }
  }
}
