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
    let lowered = transcript.lowercased()
    if ComposeSalvage.isComposeAboutSelection(transcript) { return .action }
    if matchesActionKeywords(lowered) { return .action }
    if matchesEditKeywords(lowered) { return .edit }
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
    let lowered = transcript.lowercased()
    // "Draft a response to this" is an Action (a compose), and it is checked
    // before everything else for two reasons: it needs no integrations, so
    // the `hasIntegrations` gate below would wrongly skip it; and with a
    // selection present it would otherwise reach the Edit path, which
    // REPLACES the selection — overwriting the very message being replied to.
    if ComposeSalvage.isComposeAboutSelection(transcript) { return .action }
    // Action keywords are checked first — they're more specific
    // ("remind me", "add to todoist") than edit keywords, and they
    // don't depend on a text selection being present.
    if hasIntegrations, matchesActionKeywords(lowered) { return .action }
    // Edit requires a selection — without one the user clearly
    // isn't trying to transform existing text.
    if hasSelection, matchesEditKeywords(lowered) { return .edit }
    return .dictate
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
    // Reminders
    "remind me", "set a reminder", "set reminder",
    "reminder to", "reminder for",
    // Calendar
    "schedule", "add to calendar", "calendar event",
    "create an event", "create event", "new event",
    "set up a meeting", "set a meeting",
    // Email / messaging
    "send email", "send an email", "email to",
    "draft an email", "draft email", "compose",
    "send a message", "message to",
    // Integration names (strongest signal)
    "todoist", "apple reminders",
    "gmail", "google calendar",
    "notion", "things", "slack", "linear",
  ]

  private static func matchesEditKeywords(_ text: String) -> Bool {
    editKeywords.contains { text.contains($0) }
  }

  private static func matchesActionKeywords(_ text: String) -> Bool {
    actionKeywords.contains { text.contains($0) }
  }
}
