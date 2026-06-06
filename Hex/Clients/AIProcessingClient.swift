//
//  AIProcessingClient.swift
//  Hex
//
//  Sends transcribed text through a cloud LLM for AI post-processing.
//

import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os

private let aiLogger = HexLog.aiProcessing

@DependencyClient
struct AIProcessingClient {
  /// Process `text` with the LLM.
  ///
  /// The last parameter is an optional override for the system prompt.
  /// When non-nil it replaces `mode.systemPrompt` — that's how user-
  /// authored custom AI modes flow through this pipeline without
  /// needing a parallel code path. When nil, the built-in mode's
  /// prompt is used as before. AppContext enrichment still applies
  /// on top of whichever prompt is chosen.
  /// - Parameters:
  ///   - text: The user message to send to the LLM.
  ///   - mode: The built-in AI processing mode (ignored when customSystemPrompt is non-nil).
  ///   - provider: Which LLM provider to use.
  ///   - context: Optional app context for prompt enrichment.
  ///   - customSystemPrompt: Optional system prompt override.
  ///   - skipTranscriptWrapping: When `true`, the message is sent as-is
  ///     without `<transcript>` tag wrapping. Used by inline edit, whose
  ///     message already has its own structure (`Instruction:` + `<selection>`).
  var process: @Sendable (String, AIProcessingMode, AIProvider, AppContext?, String?, Bool) async throws -> String
}

extension AIProcessingClient: DependencyKey {
  static var liveValue: Self {
    .init(
      process: { text, mode, provider, context, customSystemPrompt, skipTranscriptWrapping in
        // customSystemPrompt wins; when nil we use the built-in
        // mode's prompt. If both resolve to empty (mode == .off and
        // no custom prompt provided), skip the LLM entirely.
        let basePrompt = customSystemPrompt ?? mode.systemPrompt
        guard !basePrompt.isEmpty else { return text }

        @Dependency(\.keychain) var keychain

        let enrichedPrompt = buildPrompt(basePrompt: basePrompt, context: context)

        let response: String
        do {
          switch provider {
          case .openAI:
            guard let apiKey = await keychain.read(KeychainKey.openAIAPIKey),
                  !apiKey.isEmpty
            else {
              aiLogger.warning("OpenAI API key not configured; skipping AI processing")
              return text
            }
            response = try await callOpenAI(text: text, systemPrompt: enrichedPrompt, apiKey: apiKey, skipTranscriptWrapping: skipTranscriptWrapping)

          case .anthropic:
            guard let apiKey = await keychain.read(KeychainKey.anthropicAPIKey),
                  !apiKey.isEmpty
            else {
              aiLogger.warning("Anthropic API key not configured; skipping AI processing")
              return text
            }
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            response = try await callAnthropic(text: text, systemPrompt: enrichedPrompt, apiKey: trimmedKey, skipTranscriptWrapping: skipTranscriptWrapping)
          }
        } catch {
          // Capture LLM call failures (network / API / decoding) so we
          // can see real-world failure modes. Re-throw so existing
          // fallback-to-raw-transcript behavior at call sites is intact.
          captureError(
            error,
            context: ErrorContext.feature("ai")
              .tag("provider", provider.rawValue)
              .tag("mode", customSystemPrompt == nil ? mode.rawValue : "custom")
          )
          throw error
        }

        // Safety net: if the model still treated the transcript as a
        // conversation (e.g. answered a question instead of
        // punctuating it), fall back to the raw transcript so the
        // user's dictation is never replaced by a refusal.
        if TranscriptRefusalDetector.isRefusal(response) {
          aiLogger.warning(
            "AI response looks like a refusal; falling back to raw transcript. Response: \(response, privacy: .private)"
          )
          return text
        }

        return response
      }
    )
  }
}

private func buildPrompt(basePrompt: String, context: AppContext?) -> String {
  var prompt = basePrompt
  if let context, let fragment = context.promptFragment() {
    let appName = context.appName ?? "the active app"
    prompt += "\n\nContext from \(appName):\n\"\(fragment)\"\n\nUse this context to improve formatting, tone, and terminology."
  }
  return prompt
}

extension DependencyValues {
  var aiProcessing: AIProcessingClient {
    get { self[AIProcessingClient.self] }
    set { self[AIProcessingClient.self] = newValue }
  }
}

// MARK: - OpenAI

private func callOpenAI(text: String, systemPrompt: String, apiKey: String, skipTranscriptWrapping: Bool = false) async throws -> String {
  let url = URL(string: "https://api.openai.com/v1/chat/completions")!
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  request.timeoutInterval = 15

  let userMessage = skipTranscriptWrapping ? text : TranscriptWrapper.wrap(text)

  let body: [String: Any] = [
    "model": AIProvider.openAI.defaultModel,
    "messages": [
      ["role": "system", "content": systemPrompt],
      ["role": "user", "content": userMessage],
    ],
    "temperature": 0.3,
    "max_tokens": 2048,
  ]

  request.httpBody = try JSONSerialization.data(withJSONObject: body)

  aiLogger.info("Sending text to OpenAI (\(text.count) chars)")

  let (data, response) = try await URLSession.shared.data(for: request)

  guard let httpResponse = response as? HTTPURLResponse else {
    throw AIProcessingError.invalidResponse
  }

  guard httpResponse.statusCode == 200 else {
    let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
    aiLogger.error("OpenAI API error \(httpResponse.statusCode): \(errorBody, privacy: .private)")
    throw AIProcessingError.apiError(httpResponse.statusCode, errorBody)
  }

  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  guard let choices = json?["choices"] as? [[String: Any]],
        let firstChoice = choices.first,
        let message = firstChoice["message"] as? [String: Any],
        let content = message["content"] as? String
  else {
    throw AIProcessingError.unexpectedFormat
  }

  let result = stripMetaCommentary(content)
  aiLogger.info("AI processing complete (\(result.count) chars)")
  return result
}

// MARK: - Anthropic

private func callAnthropic(text: String, systemPrompt: String, apiKey: String, skipTranscriptWrapping: Bool = false) async throws -> String {
  let url = URL(string: "https://api.anthropic.com/v1/messages")!
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
  request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
  request.timeoutInterval = 15

  let userMessage = skipTranscriptWrapping ? text : TranscriptWrapper.wrap(text)

  let body: [String: Any] = [
    "model": AIProvider.anthropic.defaultModel,
    "system": systemPrompt,
    "messages": [
      ["role": "user", "content": userMessage],
    ],
    "max_tokens": 2048,
  ]

  request.httpBody = try JSONSerialization.data(withJSONObject: body)

  aiLogger.info("Sending text to Anthropic (\(text.count) chars)")

  let (data, response) = try await URLSession.shared.data(for: request)

  guard let httpResponse = response as? HTTPURLResponse else {
    throw AIProcessingError.invalidResponse
  }

  guard httpResponse.statusCode == 200 else {
    let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
    aiLogger.error("Anthropic API error \(httpResponse.statusCode): \(errorBody, privacy: .private)")
    throw AIProcessingError.apiError(httpResponse.statusCode, errorBody)
  }

  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  guard let contentArray = json?["content"] as? [[String: Any]],
        let firstContent = contentArray.first,
        let contentText = firstContent["text"] as? String
  else {
    throw AIProcessingError.unexpectedFormat
  }

  let result = stripMetaCommentary(contentText)
  aiLogger.info("AI processing complete (\(result.count) chars)")
  return result
}

// MARK: - Response Cleanup

/// Strips common LLM preamble/commentary that leaks through despite system prompt instructions.
private func stripMetaCommentary(_ text: String) -> String {
  var result = text
  // Strip common preamble lines like "Here is the corrected text:" or "Here's the cleaned version:"
  let preamblePatterns = [
    #"^(?:Here(?:'s| is) (?:the |your )?(?:corrected|cleaned|formatted|revised|updated|fixed|improved)[\w ]*(?:text|version|speech|transcription)?[:\-—]*\s*\n*)"#,
    #"^(?:The (?:corrected|cleaned|formatted) (?:text|version) is[:\-—]*\s*\n*)"#,
    #"^(?:Sure[!,.]?\s*(?:Here(?:'s| is)[\w ]*[:\-—]*)?\s*\n*)"#,
  ]
  for pattern in preamblePatterns {
    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
      let range = NSRange(result.startIndex..., in: result)
      result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
    }
  }

  // Strip trailing commentary like "(No corrections were needed.)" or "Note: ..."
  let suffixPatterns = [
    #"\n+\((?:No (?:corrections|changes)[\w ]*\.?)\)\s*$"#,
    #"\n+(?:Note|N\.B\.|NB)[:\-—].*$"#,
  ]
  for pattern in suffixPatterns {
    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
      let range = NSRange(result.startIndex..., in: result)
      result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
    }
  }

  return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Errors

enum AIProcessingError: LocalizedError {
  case invalidResponse
  case apiError(Int, String)
  case unexpectedFormat

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      "Invalid response from AI service"
    case .apiError(let code, _):
      "AI service returned error \(code)"
    case .unexpectedFormat:
      "Unexpected response format from AI service"
    }
  }
}
