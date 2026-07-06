import Foundation

/// Deterministic trigger-phrase matching for routines, plus detection of
/// "new routine: …" authoring commands. Runs before any LLM call — a match
/// means the Action-mode pipeline skips parsing entirely.
public enum RoutineMatcher {
  /// Lowercase, strip punctuation, collapse whitespace.
  public static func normalize(_ text: String) -> String {
    let lowered = text.lowercased()
    let stripped = lowered.unicodeScalars.map { scalar -> Character in
      if CharacterSet.punctuationCharacters.contains(scalar) { return " " }
      return Character(scalar)
    }
    return String(stripped)
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// Filler the user may wrap around a trigger phrase. "run my ship it please"
  /// still triggers the "ship it" routine.
  private static let leadingFillers = [
    "run my", "do my", "run the", "start my", "start the",
    "run", "do", "start", "execute",
  ]
  private static let trailingFillers = ["please", "now", "routine"]

  /// Returns the first routine whose trigger phrase matches the transcript.
  public static func match(transcript: String, routines: [Routine]) -> Routine? {
    let full = normalize(transcript)
    guard !full.isEmpty else { return nil }

    // Build edge-stripped variants and require an exact phrase match against
    // ANY of them — a trigger appearing mid-sentence must NOT fire (that
    // transcript is a normal command and belongs to the LLM parser). Variants
    // matter in both directions: the user may wrap the trigger in filler
    // ("run my ship it please"), or the trigger itself may contain the
    // filler words ("run my monday").
    var stripped = full
    for filler in trailingFillers {
      if stripped.hasSuffix(" " + filler) {
        stripped = String(stripped.dropLast(filler.count + 1))
      }
    }
    var candidates: Set<String> = [full, stripped]
    for base in [full, stripped] {
      for filler in leadingFillers {
        if base.hasPrefix(filler + " ") {
          candidates.insert(String(base.dropFirst(filler.count + 1)))
          break
        }
      }
    }

    for routine in routines {
      for phrase in routine.triggerPhrases {
        if candidates.contains(normalize(phrase)) { return routine }
      }
    }
    return nil
  }

  /// Detects a routine-authoring command and returns the routine description
  /// (everything after the prefix). Supports an optional leading agent name:
  /// "Hermes, new routine: when I say ship it …" → "when I say ship it …".
  public static func authoringRequest(transcript: String, agentName: String) -> String? {
    var text = normalize(transcript)
    let name = normalize(agentName)
    if !name.isEmpty, text.hasPrefix(name + " ") {
      text = String(text.dropFirst(name.count + 1))
    }
    let prefixes = ["new routine", "create a routine", "create a new routine", "make a routine", "make a new routine"]
    for prefix in prefixes {
      if text.hasPrefix(prefix + " ") {
        return String(text.dropFirst(prefix.count + 1))
      }
    }
    return nil
  }
}
