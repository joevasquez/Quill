//
//  ActionRun.swift
//  HexCore
//
//  The record of one Action-mode execution: what was asked, what the
//  planner produced, and what each step actually did — including the raw
//  MCP tool result and the before/after of a dependent step's resolve
//  pass. This is the debugging surface for "why didn't the lookup pull
//  the email?", so it deliberately keeps the raw text a step returned
//  rather than only the formatted summary the confirmation panel shows.
//
//  Everything here is local-only (an `action-runs.json` file in
//  Application Support). It is never synced — traces quote the user's
//  transcripts and their connected services' responses.
//

import Foundation

/// One end-to-end Action run.
public struct ActionRun: Codable, Equatable, Identifiable, Sendable {
  /// How the run was started. Distinguishes a dictated command from one
  /// typed into Home, a routine firing, or a suggestion being accepted.
  public enum Trigger: String, Codable, Sendable {
    case voice
    case typed
    case routine
    case suggestion

    public var displayName: String {
      switch self {
      case .voice: "Dictated"
      case .typed: "Typed"
      case .routine: "Routine"
      case .suggestion: "Suggestion"
      }
    }

    public var systemImage: String {
      switch self {
      case .voice: "mic.fill"
      case .typed: "keyboard"
      case .routine: "arrow.triangle.2.circlepath"
      case .suggestion: "lightbulb.max.fill"
      }
    }
  }

  public enum Status: String, Codable, Sendable {
    case succeeded
    case partial
    case failed
    case queued
  }

  public let id: UUID
  public var startedAt: Date
  public var finishedAt: Date
  public var trigger: Trigger
  /// The user's original request — the transcript, or the typed command.
  public var request: String
  public var steps: [ActionStepTrace]

  public init(
    id: UUID = UUID(),
    startedAt: Date,
    finishedAt: Date,
    trigger: Trigger,
    request: String,
    steps: [ActionStepTrace]
  ) {
    self.id = id
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.trigger = trigger
    self.request = request
    self.steps = steps
  }

  /// Rolled up from the steps — `partial` when some worked and some didn't,
  /// so a chain that half-completed doesn't read as a clean success.
  public var status: Status {
    let failed = steps.filter { $0.status == .failed || $0.status == .skipped }.count
    let queued = steps.filter { $0.status == .queued }.count
    let ok = steps.filter { $0.status == .succeeded }.count
    if failed == 0, queued == 0 { return .succeeded }
    if failed == 0, ok == 0 { return .queued }
    if ok == 0, queued == 0 { return .failed }
    return .partial
  }

  public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

  /// One-line summary for the list row: "Dex · Gmail" etc.
  public var targetSummary: String {
    var seen: [String] = []
    for step in steps where !seen.contains(step.targetName) {
      seen.append(step.targetName)
    }
    return seen.joined(separator: " · ")
  }
}

/// One step within a run. Carries both what was *planned* and what actually
/// happened, so a bad plan (the usual cause of a surprising result) is
/// distinguishable from a failing service.
public struct ActionStepTrace: Codable, Equatable, Identifiable, Sendable {
  public enum Status: String, Codable, Sendable {
    case succeeded
    case failed
    case queued
    /// A dependent step that never ran because its dependency produced
    /// nothing to consume.
    case skipped
  }

  public let id: UUID
  /// Position in the plan, so a chain reads in order even after edits.
  public var index: Int
  public var title: String
  /// Display name of where this step went — "Dex", "Gmail", "Apple Reminders".
  public var targetName: String
  /// Raw `ActionIntent.ActionType` value.
  public var actionType: String
  public var status: Status
  public var startedAt: Date?
  public var finishedAt: Date?

  /// Index of the step this one consumed, when chained.
  public var dependsOnIndex: Int?
  /// The planner's instruction for the resolve pass.
  public var resolveInstruction: String?

  /// The intent as it went into execution (after any panel edits, before
  /// the resolve pass), pretty-printed.
  public var plannedIntentJSON: String
  /// The intent after the resolve pass filled/personalized it. nil when the
  /// step had no dependency, or the resolve pass didn't run.
  public var resolvedIntentJSON: String?

  public var mcpServer: String?
  public var mcpTool: String?
  public var mcpArguments: [String: String]?

  /// The raw text the step returned — the MCP tool's response, or the
  /// created item's id. This is what a dependent step actually consumed,
  /// which is exactly what you need to see when the chain misbehaves.
  public var rawResult: String?
  public var errorMessage: String?

  public init(
    id: UUID = UUID(),
    index: Int,
    title: String,
    targetName: String,
    actionType: String,
    status: Status,
    startedAt: Date? = nil,
    finishedAt: Date? = nil,
    dependsOnIndex: Int? = nil,
    resolveInstruction: String? = nil,
    plannedIntentJSON: String,
    resolvedIntentJSON: String? = nil,
    mcpServer: String? = nil,
    mcpTool: String? = nil,
    mcpArguments: [String: String]? = nil,
    rawResult: String? = nil,
    errorMessage: String? = nil
  ) {
    self.id = id
    self.index = index
    self.title = title
    self.targetName = targetName
    self.actionType = actionType
    self.status = status
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.dependsOnIndex = dependsOnIndex
    self.resolveInstruction = resolveInstruction
    self.plannedIntentJSON = plannedIntentJSON
    self.resolvedIntentJSON = resolvedIntentJSON
    self.mcpServer = mcpServer
    self.mcpTool = mcpTool
    self.mcpArguments = mcpArguments
    self.rawResult = rawResult
    self.errorMessage = errorMessage
  }

  public var duration: TimeInterval? {
    guard let startedAt, let finishedAt else { return nil }
    return finishedAt.timeIntervalSince(startedAt)
  }
}

// MARK: - Intent → JSON

public extension ActionIntent {
  /// Pretty-printed JSON of this intent, for the trace viewer. Returns a
  /// short placeholder rather than throwing — a trace is diagnostic, and
  /// failing to render one must never break an action.
  var traceJSON: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(self),
          let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }
}
