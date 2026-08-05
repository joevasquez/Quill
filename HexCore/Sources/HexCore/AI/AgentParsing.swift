//
//  AgentParsing.swift
//  HexCore
//
//  Prompt assembly + response decoding for every structured-JSON agent
//  call (action parse, dependent-step resolve, answer extraction, routine
//  authoring, memory extraction). Pure logic over an injected completer —
//  each app target supplies the LLM round-trip (usually `LLMTransport`
//  with a credential it resolved) so this stays testable with stubs.
//

import Foundation
import os

private let agentLogger = HexLog.action

/// One LLM completion: (userMessage, systemPrompt) → raw model text.
public typealias LLMCompleter = @Sendable (_ userMessage: String, _ systemPrompt: String) async throws -> String

public enum AgentParsingError: LocalizedError {
  case parseFailure(String)

  public var errorDescription: String? {
    "Could not parse action from AI response"
  }
}

public enum AgentParsing {
  // MARK: - Action parse

  /// Parse a transcript into one or more `ActionIntent`s. `memoryContext`,
  /// `mcpContext` and `targetingContext` are appended to the action system
  /// prompt when present (agent memory / connected MCP servers' tools /
  /// the destinations the user pinned or left enabled for this capture).
  ///
  /// `targetingContext` goes last so it reads as the final word on where
  /// the action may land — it exists to overrule the model's own inference.
  public static func parseMulti(
    transcript: String,
    selection: String?,
    memoryContext: String?,
    mcpContext: String?,
    targetingContext: String? = nil,
    complete: LLMCompleter
  ) async throws -> MultiActionResponse {
    var systemPrompt = ActionSystemPrompt.prompt
    if let memoryContext, !memoryContext.isEmpty {
      systemPrompt += "\n\n" + memoryContext
    }
    if let mcpContext, !mcpContext.isEmpty {
      systemPrompt += "\n\n" + mcpContext
    }
    if let targetingContext, !targetingContext.isEmpty {
      systemPrompt += "\n\n" + targetingContext
    }

    let raw = try await complete(
      TranscriptWrapper.wrapWithSelection(transcript, selection: selection),
      systemPrompt
    )
    let response = try decodeMultiOrSingle(LLMTransport.stripFences(raw))
    agentLogger.info("Parsed \(response.actions.count, privacy: .public) action(s)")
    return response
  }

  /// Decode a model reply as `MultiActionResponse`, falling back to a bare
  /// single `ActionIntent` wrapped in a one-element array.
  public static func decodeMultiOrSingle(_ json: String) throws -> MultiActionResponse {
    guard let data = json.data(using: .utf8) else {
      throw AgentParsingError.parseFailure(json)
    }
    if let response = try? JSONDecoder().decode(MultiActionResponse.self, from: data) {
      return response
    }
    let intent = try JSONDecoder().decode(ActionIntent.self, from: data)
    return MultiActionResponse(actions: [intent])
  }

  // MARK: - Dependent-step resolve

  /// Between-steps resolve pass for chained actions: fills the linking
  /// field(s) named by `resolveInstruction` from the prior step's raw
  /// output and personalizes the action text. Falls back to the
  /// unresolved intent when the model's reply doesn't decode.
  public static func resolveStep(
    intent: ActionIntent,
    priorResult: String,
    request: String,
    complete: LLMCompleter
  ) async throws -> ActionIntent {
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
    let raw = try await complete(userMessage, StepResolvePrompt.prompt)
    let json = LLMTransport.stripFences(raw)
    guard let data = json.data(using: .utf8),
          let resolved = try? JSONDecoder().decode(ActionIntent.self, from: data) else {
      agentLogger.warning("Step resolve returned non-decodable JSON; using unresolved intent")
      return intent
    }
    return resolved
  }

  // MARK: - Answer extraction

  /// Extract the specific value the user asked for from a standalone MCP
  /// read/query result. Returns "" when the request wasn't a question or
  /// the value isn't present.
  public static func extractAnswer(
    request: String,
    result: String,
    complete: LLMCompleter
  ) async throws -> String {
    let raw = try await complete(
      AnswerExtractionPrompt.userMessage(request: request, result: result),
      AnswerExtractionPrompt.prompt
    )
    let json = LLMTransport.stripFences(raw)
    guard let data = json.data(using: .utf8),
          let obj = try? JSONDecoder().decode([String: String].self, from: data) else {
      return ""
    }
    return obj["answer"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  // MARK: - Routine authoring

  /// Turn a dictated routine description ("when I say ship it, …") into a
  /// named trigger + steps draft.
  public static func parseRoutine(
    description: String,
    complete: LLMCompleter
  ) async throws -> RoutineDraft {
    let raw = try await complete(
      TranscriptWrapper.wrap(description),
      RoutineAuthoringPrompt.prompt
    )
    let json = LLMTransport.stripFences(raw)
    guard let data = json.data(using: .utf8) else {
      throw AgentParsingError.parseFailure(json)
    }
    return try JSONDecoder().decode(RoutineDraft.self, from: data)
  }

  // MARK: - Memory extraction

  /// Decode a memory-extraction reply. Exposed separately so callers with
  /// an on-device model path (macOS FoundationModels) can reuse the
  /// decode before falling back to the cloud completer.
  public static func decodeMemoryResponse(_ raw: String) -> [MemoryCandidate]? {
    let cleaned = LLMTransport.stripFences(raw)
    guard let data = cleaned.data(using: .utf8),
          let response = try? JSONDecoder().decode(MemoryExtractionResponse.self, from: data) else {
      return nil
    }
    return response.entities
  }

  /// Cloud memory pass: distill durable entities (people, projects,
  /// preferences) from an Action-mode transcript.
  public static func extractMemory(
    transcript: String,
    complete: LLMCompleter
  ) async throws -> [MemoryCandidate] {
    let raw = try await complete(
      TranscriptWrapper.wrap(transcript),
      MemoryExtractionPrompt.prompt
    )
    guard let entities = decodeMemoryResponse(raw) else {
      throw AgentParsingError.parseFailure(LLMTransport.stripFences(raw))
    }
    return entities
  }
}
