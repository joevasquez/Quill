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
        try await AgentParsing.resolveStep(
          intent: intent,
          priorResult: priorResult,
          request: request,
          complete: completer(for: provider)
        )
      },
      extractAnswer: { request, result, provider in
        try await AgentParsing.extractAnswer(
          request: request,
          result: result,
          complete: completer(for: provider)
        )
      },
      parseRoutine: { description, provider in
        try await AgentParsing.parseRoutine(
          description: description,
          complete: completer(for: provider)
        )
      },
      extractMemory: { transcript, provider in
        // Prefer Apple's on-device model for memory extraction: it's a
        // background, low-stakes pass and running it locally means the
        // agent learns for free without the transcript leaving the Mac.
        // Any failure (unavailable, malformed JSON) falls through to the
        // cloud path.
        if let local = await OnDeviceModel.complete(
          systemPrompt: MemoryExtractionPrompt.prompt,
          userMessage: TranscriptWrapper.wrap(transcript)
        ) {
          if let entities = AgentParsing.decodeMemoryResponse(local) {
            actionLogger.info("Memory extraction ran on-device (\(entities.count, privacy: .public) entities)")
            return entities
          }
          actionLogger.warning("On-device memory extraction returned non-JSON; falling back to cloud")
        }

        return try await AgentParsing.extractMemory(
          transcript: transcript,
          complete: completer(for: provider)
        )
      }
    )
  }
}

private func parseTranscript(_ transcript: String, provider: AIProvider, selection: String?) async throws -> MultiActionResponse {
  // Agent memory: append known people/projects/preferences so "email Mike"
  // resolves without clarifying questions. No-op when the store is empty.
  let memories = await MemoryStore.shared.loadAll()
  let memoryContext = MemoryContextBuilder.context(from: memories)

  // MCP: list the user's connected servers' tools so the LLM can emit
  // mcpCall actions. No-op when no server has a cached tool catalog.
  @Shared(.hexSettings) var hexSettings: HexSettings
  let mcpContext = await MCPToolCatalog.shared.promptContext(servers: hexSettings.mcpServers)

  return try await AgentParsing.parseMulti(
    transcript: transcript,
    selection: selection,
    memoryContext: memoryContext,
    mcpContext: mcpContext,
    complete: completer(for: provider)
  )
}

/// Builds the shared LLM round-trip for all structured-JSON agent calls.
/// Pro users route through the server-side proxy (no local API key needed)
/// — the same policy as `AIProcessingClient.process`; BYOK users hit the
/// provider directly.
private func completer(for provider: AIProvider) -> LLMCompleter {
  { userMessage, systemPrompt in
    actionLogger.info("Agent LLM call: \(userMessage.count, privacy: .public) chars via \(provider.displayName, privacy: .public)")
    let credential = try await resolveCredential(for: provider)
    return try await LLMTransport.complete(
      userMessage: userMessage,
      systemPrompt: systemPrompt,
      credential: credential
    )
  }
}

private func resolveCredential(for provider: AIProvider) async throws -> LLMCredential {
  if isActionProModeActive() {
    @Dependency(\.googleOAuth) var googleOAuth
    guard let accessToken = try? await googleOAuth.refreshIfNeeded() else {
      throw ActionParsingError.missingAPIKey(provider)
    }
    return .proProxy(accessToken: accessToken)
  }
  @Dependency(\.keychain) var keychain
  let keychainKey = provider == .openAI ? KeychainKey.openAIAPIKey : KeychainKey.anthropicAPIKey
  guard let key = await keychain.read(keychainKey), !key.isEmpty else {
    throw ActionParsingError.missingAPIKey(provider)
  }
  return .byok(apiKey: key, provider: provider)
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
