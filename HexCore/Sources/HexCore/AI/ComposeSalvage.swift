import Foundation

/// Rescues the one failure the `composeReply` action type invites.
///
/// The action planner is under a strict "reply with ONLY a JSON object"
/// contract. That holds well for "remind me to call Mike" — but "draft a
/// response to this", handed a message addressed to the user, pulls hard
/// the other way: the model answers the message directly and returns prose
/// with no JSON anywhere in it. The decode then fails at column 1 and the
/// user's command appears to do nothing.
///
/// When that happens the model has still produced exactly what was asked
/// for — it just skipped the envelope. Rather than throwing it away, wrap
/// the prose in the `composeReply` intent it should have been. This is only
/// applied when the request was compose-shaped, and a compose has no side
/// effects (the panel shows the text with Copy/Paste), so a wrong guess
/// costs the user a card they dismiss, not an action they didn't want.
public enum ComposeSalvage {
  /// Words that mean "produce text for me". Deliberately narrow: an
  /// unrelated command whose parse failed for some other reason must still
  /// surface as an error rather than as a bogus draft.
  private static let composeVerbs = [
    "draft", "write", "reply", "respond", "response", "compose",
  ]

  static func isComposeRequest(_ transcript: String) -> Bool {
    let lower = transcript.lowercased()
    return composeVerbs.contains { lower.contains($0) }
  }

  /// Ways of pointing at something on screen rather than naming it.
  private static let deicticReferences = [
    "this", "that", "these", "the highlighted", "the selection",
    "what i highlighted", "what i've highlighted", "the selected",
  ]

  /// True when the command asks for a reply to something the user is
  /// pointing at — "draft a response to **this**" — as opposed to a
  /// self-contained request like "draft an email to Mike about Q3".
  ///
  /// Two callers, one idea. Auto mode routes these to Action (they'd
  /// otherwise fall through to Dictate and paste the command, or worse hit
  /// the Edit path and overwrite the very text being replied to). And Action
  /// mode refuses one outright when no selection was captured: sending it to
  /// the model anyway yields a reply explaining that it can't see a
  /// selection, which the salvage path — unable to tell prose from prose —
  /// would then present as the user's draft.
  public static func isComposeAboutSelection(_ transcript: String) -> Bool {
    guard isComposeRequest(transcript) else { return false }
    let lower = transcript.lowercased()
    return deicticReferences.contains { lower.contains($0) }
  }

  /// A `composeReply` intent carrying `modelReply`, or nil when this reply
  /// shouldn't be salvaged.
  public static func intent(forTranscript transcript: String, modelReply: String) -> ActionIntent? {
    let reply = modelReply.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reply.isEmpty else { return nil }
    // Starts like JSON → it WAS an attempt at the contract that failed for
    // some other reason (a bad field, a truncation). Salvaging that as
    // "prose" would hand the user a card full of braces and hide a real bug.
    guard !reply.hasPrefix("{"), !reply.hasPrefix("[") else { return nil }
    guard isComposeRequest(transcript) else { return nil }
    return ActionIntent(
      actionType: .composeReply,
      title: "Drafted reply",
      notes: reply
    )
  }
}
