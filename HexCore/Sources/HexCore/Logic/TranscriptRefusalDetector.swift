import Foundation

/// Wraps raw transcript text in the `<transcript>` tags that the
/// ``AIProcessingMode`` system prompt references, and detects when a
/// cloud LLM has still treated the transcript as a conversational
/// prompt (e.g. "I am a text post-processor, I cannot join calls…")
/// and refused to transform it.
///
/// Wrapping is the primary defense — tag-wrapped content is reliably
/// interpreted as data by Claude and GPT models. The refusal detector
/// is a safety net: when wrapping isn't enough (smaller models can
/// still break under pressure), we return the raw transcript instead
/// of the model's refusal so the user's dictation is never lost.
public enum TranscriptWrapper {
  /// Wrap `text` in the `<transcript>` tags the system prompt tells
  /// the model to look for. Prefaced with a short re-statement of the
  /// task so the model sees both the instruction and the framing every
  /// time.
  public static func wrap(_ text: String) -> String {
    """
    Apply the transformation from the system prompt to the text between the <transcript> tags. Return ONLY the transformed text — no tags, no preamble, no refusals.

    <transcript>
    \(text)
    </transcript>
    """
  }

  /// Like `wrap`, but appends a `<selection>` block carrying text the user
  /// had highlighted in the frontmost app when they spoke. Used by Action
  /// mode so commands like "add this to my Kearney list" can resolve
  /// "this". A nil/empty selection degrades to plain `wrap`.
  public static func wrapWithSelection(_ text: String, selection: String?) -> String {
    guard let selection, !selection.isEmpty else { return wrap(text) }
    return wrap(text) + """


    The user had the following text highlighted in the frontmost app when they spoke:

    <selection>
    \(selection)
    </selection>
    """
  }
}

public enum TranscriptRefusalDetector {
  /// Phrases that mark the start of a refusal / self-description by
  /// the model rather than a transformed transcript. Matched as
  /// whole-phrase prefixes followed by a word boundary (space, comma,
  /// period, etc.) so "I am a speaker" doesn't match "i am a" but
  /// "I am a language model" does. All comparisons are case-insensitive.
  private static let refusalPrefixes: [String] = [
    // Self-identification refusals
    "i am a",
    "i'm a",
    "i am an",
    "i'm an",
    "as an ai",
    "as a text",
    "as a language model",
    "my purpose is",
    "my role is",
    // Capability refusals
    "i cannot",
    "i can't",
    "i am unable",
    "i'm unable",
    "i am not able",
    "i'm not able",
    "i don't have",
    "i do not have",
    // Apologies
    "i apologize",
    "i'm sorry",
    "i am sorry",
    "sorry, i",
    "sorry but",
    // Conversational hedging / meta-commentary
    "i notice",
    "i see that",
    "i'd like to",
    "i would like to",
    "let me clarify",
    "this is ambiguous",
    "this input is ambiguous",
    "the instruction is ambiguous",
    "i need clarification",
    "i need more context",
    // Asking the user for content (the model is having a
    // conversation instead of transforming text)
    "could you please provide",
    "could you please share",
    "could you provide",
    "could you share",
    "could you clarify",
    "please provide",
    "please share",
    "please paste",
    "please clarify",
    "please direct",
    "please send",
    "i'd be happy to",
    "i would be happy to",
    "happy to help once",
    "once you share",
    "once you provide",
    "to clarify,",
    "to clarify:",
    // Generic "I'll wait for content"
    "i'll wait",
    "i will wait",
  ]

  /// Returns true if `response` starts with one of the known refusal
  /// phrases. Callers should fall back to the raw transcript when
  /// this fires.
  ///
  /// Matches the prefix only when it ends at a natural boundary — a
  /// space, comma, period, colon, etc. — so an innocent sentence
  /// starting with the same characters doesn't trigger a false
  /// positive. "I am a speaker" → no match; "I am a text processor…"
  /// → match.
  public static func isRefusal(_ response: String) -> Bool {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let head = String(trimmed.prefix(100)).lowercased()
    return refusalPrefixes.contains { prefix in
      guard head.hasPrefix(prefix) else { return false }
      // Character immediately after the prefix must be a word boundary
      // (anything that isn't a letter or digit — includes end of string).
      let boundaryIndex = head.index(head.startIndex, offsetBy: prefix.count)
      guard boundaryIndex < head.endIndex else { return true }
      let next = head[boundaryIndex]
      return !next.isLetter && !next.isNumber
    }
  }
}
