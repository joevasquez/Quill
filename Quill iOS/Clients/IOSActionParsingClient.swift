//
//  IOSActionParsingClient.swift
//  Quill (iOS)
//
//  Thin iOS wrapper over the shared `AgentParsing` core in HexCore. It
//  resolves a credential (Pro proxy when the user is on the Pro plan and
//  signed into Google, else BYOK via `KeychainStore`) and delegates prompt
//  assembly + decoding to HexCore, so iOS and macOS parse identically.
//

import Foundation
import HexCore

@MainActor
enum IOSActionParsingClient {
  static func parse(
    transcript: String,
    provider: AIProvider
  ) async throws -> ActionIntent {
    // Used by the offline queue's replay parser — include the MCP tool
    // context so a queued "look up X in dex" still parses to an mcpCall.
    let mcpContext = await MCPToolCatalog.shared.promptContext(
      servers: MCPServersStorage.load()
    )
    let response = try await parseMulti(
      transcript: transcript,
      provider: provider,
      mcpContext: mcpContext
    )
    guard let intent = response.actions.first else {
      throw TextAIError.invalidResponse
    }
    return intent
  }

  /// Parse a transcript into one or more intents. `memoryContext` /
  /// `mcpContext` are appended to the system prompt when provided
  /// (agent memory + connected MCP servers). `targeting` restricts where
  /// the action may land — destinations the user pinned with an `@`
  /// mention, or the set left enabled on the Act chip row.
  static func parseMulti(
    transcript: String,
    provider: AIProvider,
    memoryContext: String? = nil,
    mcpContext: String? = nil,
    targeting: ActTargeting = .unrestricted
  ) async throws -> MultiActionResponse {
    try await AgentParsing.parseMulti(
      transcript: transcript,
      selection: nil,
      memoryContext: memoryContext,
      mcpContext: mcpContext,
      targetingContext: targeting.promptContext,
      complete: completer(for: provider)
    )
  }

  static func resolveStep(
    intent: ActionIntent,
    priorResult: String,
    request: String,
    provider: AIProvider
  ) async throws -> ActionIntent {
    try await AgentParsing.resolveStep(
      intent: intent,
      priorResult: priorResult,
      request: request,
      complete: completer(for: provider)
    )
  }

  static func extractAnswer(
    request: String,
    result: String,
    provider: AIProvider
  ) async throws -> String {
    try await AgentParsing.extractAnswer(
      request: request,
      result: result,
      complete: completer(for: provider)
    )
  }

  static func parseRoutine(
    description: String,
    provider: AIProvider
  ) async throws -> RoutineDraft {
    try await AgentParsing.parseRoutine(
      description: description,
      complete: completer(for: provider)
    )
  }

  static func extractMemory(
    transcript: String,
    provider: AIProvider
  ) async throws -> [MemoryCandidate] {
    // Prefer the on-device model: memory extraction is a background,
    // low-stakes pass, and running it locally means the agent learns
    // for free without the transcript leaving the phone (parity with
    // macOS). Malformed output or unavailability falls through to cloud.
    if let local = await IOSOnDeviceModel.complete(
      systemPrompt: MemoryExtractionPrompt.prompt,
      userMessage: TranscriptWrapper.wrap(transcript)
    ), let entities = AgentParsing.decodeMemoryResponse(local) {
      return entities
    }
    return try await AgentParsing.extractMemory(
      transcript: transcript,
      complete: completer(for: provider)
    )
  }

  // MARK: - Credential resolution

  /// Pro plan + Google signed in → server-side proxy (no local key).
  /// Otherwise BYOK from the keychain.
  static func resolveCredential(for provider: AIProvider) async throws -> LLMCredential {
    if UserDefaults.standard.string(forKey: QuillIOSSettingsKey.selectedPlan) == "pro",
       IOSGoogleOAuthClient.isAuthorized(),
       let accessToken = try? await IOSGoogleOAuthClient.refreshIfNeeded() {
      return .proProxy(accessToken: accessToken)
    }

    let account: String
    switch provider {
    case .anthropic: account = KeychainKey.anthropicAPIKey
    case .openAI: account = KeychainKey.openAIAPIKey
    }
    let (key, _) = KeychainStore.read(account: account)
    guard let key, !key.isEmpty else {
      throw TextAIError.missingAPIKey(provider)
    }
    return .byok(apiKey: key, provider: provider)
  }

  private static func completer(for provider: AIProvider) -> LLMCompleter {
    { userMessage, systemPrompt in
      let credential = try await resolveCredential(for: provider)
      return try await LLMTransport.complete(
        userMessage: userMessage,
        systemPrompt: systemPrompt,
        credential: credential,
        // Matches macOS: a `composeReply` carries a full drafted reply
        // inside the action JSON, which overruns the terse 1024 default and
        // fails the decode mid-string. A ceiling, not a spend.
        maxTokens: 4096
      )
    }
  }
}
