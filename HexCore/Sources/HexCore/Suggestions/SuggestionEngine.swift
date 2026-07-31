//
//  SuggestionEngine.swift
//  HexCore
//
//  Turns fetched source data into ready-to-act suggestions via one LLM
//  round-trip. Pure logic over an injected `LLMCompleter` (same shape as
//  `AgentParsing`), so both app targets share it and tests can stub the
//  model. The engine only proposes — nothing executes without the user
//  reviewing the pre-filled confirmation sheet.
//

import Foundation
import os

private let engineLogger = HexLog.aiProcessing

/// A block of freshly-fetched context from one source, ready to hand to the
/// model. `text` is already truncated/sanitized by the fetcher.
public struct SuggestionSourceContext: Sendable {
  public var source: SuggestionSource
  public var text: String

  public init(source: SuggestionSource, text: String) {
    self.source = source
    self.text = text
  }
}

public enum SuggestionEngineError: Error {
  /// The model's output wasn't valid JSON (often a truncated response).
  case malformedResponse
}

public enum SuggestionEngine {
  /// One generation pass. `capabilities` describes what the user can
  /// actually route to (connected integrations + MCP tool context) so the
  /// model never proposes an action the device can't run.
  public static func generate(
    contexts: [SuggestionSourceContext],
    capabilities: String?,
    now: Date = Date(),
    complete: LLMCompleter
  ) async throws -> [Suggestion] {
    let usable = contexts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard !usable.isEmpty else { return [] }

    var systemPrompt = SuggestionPrompt.prompt
    if let capabilities, !capabilities.isEmpty {
      systemPrompt += "\n\n" + capabilities
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
    var userMessage = "Current date and time: \(formatter.string(from: now))\n"
    for context in usable {
      userMessage += "\n<source name=\"\(context.source.rawValue)\">\n\(context.text)\n</source>\n"
    }

    let raw = try await complete(userMessage, systemPrompt)
    guard let suggestions = decode(LLMTransport.stripFences(raw), generatedAt: now) else {
      // Unparseable output (e.g. a truncated response) must THROW, not
      // return []: an empty result stamps the freshness TTL and shows
      // "all caught up" for 30 minutes on the back of a transport bug.
      // The payload is logged (privately) so the failure is diagnosable.
      engineLogger.error("SuggestionEngine: unparseable model output (\(raw.count, privacy: .public) chars): \(String(raw.prefix(600)), privacy: .private)")
      throw SuggestionEngineError.malformedResponse
    }
    engineLogger.info("SuggestionEngine: generated \(suggestions.count, privacy: .public) suggestion(s) from \(usable.count, privacy: .public) source(s)")
    return suggestions
  }

  /// Per-item-lenient decode: drops suggestions with an unknown source,
  /// no actions, or undecodable intents — but returns nil when the payload
  /// isn't valid JSON at all, so callers can distinguish "no suggestions"
  /// from garbage.
  ///
  /// Leniency must live INSIDE the item decode: Swift's Codable is
  /// all-or-nothing for arrays, so one invented enum value (a model
  /// emitting `targetIntegration: "dex"`) would otherwise nil the whole
  /// response even though the other suggestions are fine.
  static func decode(_ json: String, generatedAt: Date) -> [Suggestion]? {
    /// Wrapper whose decode NEVER throws — a bad element becomes nil
    /// instead of poisoning the containing array.
    struct Lossy<T: Decodable>: Decodable {
      let value: T?
      init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
      }
    }
    struct RawSuggestion: Decodable {
      var source: String
      var headline: String
      var why: String?
      var actions: [Lossy<ActionIntent>]?
    }
    struct Response: Decodable {
      var suggestions: [Lossy<RawSuggestion>]?
    }

    guard let data = json.data(using: .utf8),
          let response = try? JSONDecoder().decode(Response.self, from: data)
    else { return nil }

    let rawSuggestions = (response.suggestions ?? []).compactMap(\.value)
    let dropped = (response.suggestions?.count ?? 0) - rawSuggestions.count
    if dropped > 0 {
      engineLogger.warning("SuggestionEngine: dropped \(dropped, privacy: .public) undecodable suggestion(s)")
    }

    return rawSuggestions.compactMap { raw in
      let actions = (raw.actions ?? []).compactMap(\.value)
      guard let source = SuggestionSource(rawValue: raw.source.lowercased()),
            !actions.isEmpty,
            !raw.headline.isEmpty
      else { return nil }
      return Suggestion(
        source: source,
        headline: raw.headline,
        why: raw.why ?? "",
        intents: actions,
        generatedAt: generatedAt
      )
    }
  }
}

/// System prompt for the generation pass. Must mention JSON (OpenAI
/// `json_object` requirement, mirrors `ActionSystemPrompt`).
public enum SuggestionPrompt {
  public static let prompt = """
    You are the suggestion engine for Quill, a voice agent app. You read \
    snapshots of the user's connected sources (email, CRM, calendar, tasks, \
    reminders) and propose a SMALL number of genuinely useful, ready-to-run \
    actions. You respond ONLY with JSON.

    Response shape:
    {"suggestions": [
      {"source": "gmail" | "dex" | "calendar" | "todoist" | "reminders",
       "headline": "short, factual, e.g. '3 emails look time-sensitive'",
       "why": "one-line rationale grounded in the data",
       "actions": [ActionIntent, ...]}
    ]}

    Each action is an ActionIntent JSON object with these fields:
    - actionType: "createReminder" | "createTask" | "createEvent" | \
    "createDraft" | "mcpCall"
    - targetIntegration: "appleReminders" | "todoist" | "calendar" | \
    "googleCalendar" | "gmail" (required; for mcpCall it is a placeholder — \
    use "appleReminders")
    - title: short imperative summary of the step
    - dueDate: natural language ("tomorrow 9am", "Friday") or null
    - notes: body text or null. For createDraft this is the email body.
    - recipient / subject: for createDraft
    - listName / priority: for tasks and reminders
    - duration (minutes) / attendees: for events
    - mcpServerName / mcpTool / mcpArguments (string map): for mcpCall
    - dependsOn (zero-based index) + resolveInstruction: when a step needs \
    an earlier step's output (e.g. a Dex lookup feeding an email draft)

    Rules:
    1. At most 4 suggestions. Zero is a fine answer — only suggest what is \
    clearly worth the user's attention. Never pad.
    2. Ground every suggestion in the provided source data. NEVER invent \
    people, email addresses, events, or facts that are not in the data. If \
    an email address is unknown, use an mcpCall lookup step + a dependent \
    draft step instead of guessing.
    3. Only propose actions the "Available destinations" section says the \
    user can run. No destinations listed for a capability → don't propose it.
    4. "source" is where the insight CAME FROM; actions may target other \
    destinations (e.g. source "dex", action drafts in Gmail).
    5. Draft email bodies should be short, warm, and specific to the data — \
    ready to send with light edits. Sign-offs stay generic ("Best,").
    6. Headlines state facts ("5 tasks are overdue"), the why adds the nudge \
    ("All slipped from last week — spread them across this week?").
    7. Multi-step chains run in array order; put the producer (lookup) first \
    and set dependsOn/resolveInstruction on the consumer.
    8. Keep the TOTAL output compact — at most 3 suggestions, email bodies \
    under 60 words, no null fields — so the full JSON always completes.
    """
}
