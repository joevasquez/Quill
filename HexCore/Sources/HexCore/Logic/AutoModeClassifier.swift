//
//  AutoModeClassifier.swift
//  HexCore
//
//  Keyword-based intent classifier for Auto mode. Scans the transcript
//  (partial or final) and returns the most likely mode: Edit, Action,
//  or Dictate. Stateless and deterministic — easy to unit-test. Shared
//  by macOS (4-way HUD mode cycle) and iOS (Dictate-vs-Action routing,
//  where `hasSelection` is always false).
//

import Foundation

public enum AutoModeClassifier {

  // MARK: - Live classification (partial transcript, during recording)

  /// Lightweight scan for a live badge. No selection info available
  /// yet — just keyword analysis on the partial text.
  public static func classifyPartial(_ transcript: String) -> TranscriptionMode {
    let normalized = normalize(transcript)
    if ComposeSalvage.isComposeAboutSelection(transcript) { return .action }
    if matchesActionKeywords(normalized) { return .action }
    if matchesEditKeywords(normalized) { return .edit }
    return .dictate
  }

  // MARK: - Final resolution (full transcript + context, at stop time)

  /// Decides the effective mode with all signals available:
  /// the full transcript, whether a text selection was captured,
  /// and whether any action integrations are connected.
  public static func resolve(
    transcript: String,
    hasSelection: Bool,
    hasIntegrations: Bool
  ) -> TranscriptionMode {
    let normalized = normalize(transcript)
    // "Draft a response to this" is an Action (a compose), and it is checked
    // before everything else for two reasons: it needs no integrations, so
    // the `hasIntegrations` gate below would wrongly skip it; and with a
    // selection present it would otherwise reach the Edit path, which
    // REPLACES the selection — overwriting the very message being replied to.
    if ComposeSalvage.isComposeAboutSelection(transcript) { return .action }
    // Action keywords are checked first — they're more specific
    // ("remind me", "add to todoist") than edit keywords, and they
    // don't depend on a text selection being present.
    if hasIntegrations, matchesActionKeywords(normalized) { return .action }
    // Edit requires a selection — without one the user clearly
    // isn't trying to transform existing text.
    if hasSelection, matchesEditKeywords(normalized) { return .edit }
    return .dictate
  }

  // MARK: - Matching

  /// Lowercases, strips punctuation, and collapses to space-delimited words
  /// with a leading and trailing space, so a keyword padded the same way
  /// matches only on whole-word boundaries.
  ///
  /// This replaced a bare `contains`, which matched keywords *inside* other
  /// words: "things" hit the ordinary word "things", "fix" hit "prefix" and
  /// "fixed", "compose" hit "composer" and "decompose". A sentence as plain
  /// as "I need to fix the schedule for things next week" routed to Action.
  static func normalize(_ text: String) -> String {
    let words = text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    return " " + words.joined(separator: " ") + " "
  }

  /// `normalized` must come from `normalize`; keywords are stored lowercase
  /// and punctuation-free so they can be padded the same way.
  private static func matches(_ normalized: String, _ keywords: [String]) -> Bool {
    keywords.contains { normalized.contains(" \($0) ") }
  }

  // MARK: - Keyword lists

  private static let editKeywords: [String] = [
    // Imperative verbs implying text transformation
    "shorten", "lengthen", "rewrite", "translate",
    "fix", "proofread", "tighten", "expand",
    "summarize", "rephrase", "simplify", "formalize",
    "condense", "paraphrase",
    // Adjective-based instructions
    "make it", "make this", "make more",
    "more professional", "more casual", "more concise",
    "more formal", "more friendly",
    // Common edit phrases
    "clean up", "clean this up",
    "fix grammar", "fix the grammar",
    "fix spelling", "fix the spelling",
    "change the tone", "change tone",
    "convert to", "format as",
    "add bullet", "bullet points",
  ]

  private static let actionKeywords: [String] = [
    // Task creation
    "add to", "add a task", "add task",
    "create a task", "create task", "new task",
    // Reminders. `remind` and `reminder` are bare on purpose: the old list
    // enumerated phrasings ("remind me", "reminder to", "reminder for") and
    // missed the ones nobody thought of — "add a reminder I need to go to
    // the beach tomorrow" matched none of them and landed in a note.
    // Enumerating a natural-language surface never converges; the noun and
    // the verb do. It costs the occasional false positive on prose that
    // mentions a reminder, which is the cheap direction to be wrong in:
    // Action only opens a confirmation panel, and both platforms can now
    // re-route a wrong guess without the user speaking again.
    "remind", "reminder",
    // Calendar. "schedule" is handled separately — see below.
    "add to calendar", "calendar event",
    "create an event", "create event", "new event",
    "set up a meeting", "set a meeting",
    // Email / messaging
    "send email", "send an email", "email to",
    "draft an email", "draft email", "compose",
    "send a message", "message to",
    // Integration names (strongest signal). "things" is qualified — bare, it
    // matches the ordinary English word, which is not a routing signal.
    "todoist", "apple reminders",
    "gmail", "google calendar",
    "notion", "things app", "slack", "linear",
  ]

  private static func matchesEditKeywords(_ normalized: String) -> Bool {
    matches(normalized, editKeywords)
  }

  private static func matchesActionKeywords(_ normalized: String) -> Bool {
    matches(normalized, actionKeywords) || matchesNounAmbiguousAction(normalized)
  }

  /// Words that are a command as a verb but ordinary prose as a noun:
  /// "schedule lunch with Mike" vs "fix the schedule". Word boundaries can't
  /// separate those — it's the same word — so these match only when a
  /// determiner isn't sitting in front of them.
  private static let nounAmbiguousActionKeywords = ["schedule"]

  private static let determiners = [
    "the", "a", "an", "my", "our", "your", "his", "her", "their",
    "this", "that", "whole", "entire",
  ]

  private static func matchesNounAmbiguousAction(_ normalized: String) -> Bool {
    nounAmbiguousActionKeywords.contains { word in
      guard normalized.contains(" \(word) ") else { return false }
      // Any determiner use suppresses the whole utterance rather than just
      // that occurrence. Coarse, but the failure is a dictation staying a
      // dictation, which the re-route makes cheap to correct.
      return !determiners.contains { normalized.contains(" \($0) \(word) ") }
    }
  }
}
