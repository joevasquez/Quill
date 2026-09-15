import Foundation

/// Splits long transcript transformations into bounded requests without
/// dropping content. Callers format each chunk independently and preserve the
/// raw chunk whenever a model response is unusable.
public enum LongTextChunker {
  public static func chunks(_ text: String, maxCharacters: Int = 4_000) -> [String] {
    guard maxCharacters > 0 else { return [text] }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxCharacters else { return trimmed.isEmpty ? [] : [trimmed] }

    var result: [String] = []
    var remainder = trimmed[...]
    while remainder.count > maxCharacters {
      let limit = remainder.index(remainder.startIndex, offsetBy: maxCharacters)
      let prefix = remainder[remainder.startIndex..<limit]
      let boundary = preferredBoundary(in: prefix) ?? limit
      let chunk = remainder[remainder.startIndex..<boundary]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !chunk.isEmpty { result.append(chunk) }
      remainder = remainder[boundary...].drop(while: \.isWhitespace)
    }

    let tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { result.append(tail) }
    return result
  }

  private static func preferredBoundary(in text: Substring) -> String.Index? {
    let minimum = text.index(text.startIndex, offsetBy: max(1, text.count / 2))
    for separator in ["\n\n", "\n", ". ", "? ", "! ", " "] {
      if let range = text.range(of: separator, options: .backwards), range.upperBound >= minimum {
        return range.upperBound
      }
    }
    return nil
  }
}

/// Compares the user's elapsed recording time with the playable file. A small
/// callback/start-stop allowance is expected; a large shortfall is data loss.
public enum RecordingCaptureAudit {
  public enum Result: Equatable, Sendable { case complete, truncated }

  public static func evaluate(elapsed: TimeInterval, captured: TimeInterval) -> Result {
    guard elapsed > 5 else { return .complete }
    let allowedShortfall = max(5, elapsed * 0.05)
    return elapsed - captured <= allowedShortfall ? .complete : .truncated
  }
}
