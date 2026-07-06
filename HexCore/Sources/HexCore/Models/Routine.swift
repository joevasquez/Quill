import Foundation

/// A saved, named workflow the user can trigger with a spoken phrase.
///
/// Routines are the fast path of the agent: when a dictated Action-mode
/// transcript matches a `triggerPhrases` entry (see `RoutineMatcher`), the
/// stored `steps` go straight to the confirmation panel — no LLM call, no
/// network, works offline. Natural-language `dueDate` strings inside steps
/// (e.g. "Friday", "tomorrow at 9am") are re-resolved at run time, so a
/// routine saved on Monday still means "next Friday" when run in June.
public struct Routine: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  /// Spoken triggers, e.g. ["ship it", "run my release routine"]. Matched
  /// case- and punctuation-insensitively against the whole transcript.
  public var triggerPhrases: [String]
  public var steps: [ActionIntent]
  /// Trust ladder: `false` (default) shows the confirmation panel;
  /// `true` executes immediately on trigger.
  public var autoRun: Bool
  public var createdAt: Date
  public var lastRunAt: Date?
  public var runCount: Int

  public init(
    id: UUID = UUID(),
    name: String,
    triggerPhrases: [String],
    steps: [ActionIntent],
    autoRun: Bool = false,
    createdAt: Date = Date(),
    lastRunAt: Date? = nil,
    runCount: Int = 0
  ) {
    self.id = id
    self.name = name
    self.triggerPhrases = triggerPhrases
    self.steps = steps
    self.autoRun = autoRun
    self.createdAt = createdAt
    self.lastRunAt = lastRunAt
    self.runCount = runCount
  }
}

/// What the routine-authoring LLM call returns for a "new routine: …"
/// dictation, before the user confirms and it becomes a `Routine`.
public struct RoutineDraft: Codable, Equatable, Sendable {
  public var name: String
  public var triggerPhrase: String
  public var actions: [ActionIntent]

  public init(name: String, triggerPhrase: String, actions: [ActionIntent]) {
    self.name = name
    self.triggerPhrase = triggerPhrase
    self.actions = actions
  }
}
