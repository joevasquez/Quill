//
//  NoteTargetMatcher.swift
//  HexCore
//
//  Deterministic matcher for voice-targeted note appends — "add milk to
//  my groceries note", "append call Sarah back to the follow-ups note".
//  Runs BEFORE Auto routing on the dictation path (it's more specific
//  than the action keywords: "add to" would otherwise route to the
//  agent), costs nothing, and works offline.
//
//  Only the explicit "… note" suffix triggers — "add milk to my
//  groceries list" still goes to the agent (Reminders/Todoist lists).
//

import Foundation

public enum NoteTargetMatcher {
  public struct Match: Equatable {
    /// The spoken note name (e.g. "groceries") — caller resolves it
    /// against real note titles.
    public let noteName: String
    /// What to append.
    public let content: String

    public init(noteName: String, content: String) {
      self.noteName = noteName
      self.content = content
    }
  }

  /// Patterns tried in order. Case-insensitive; content keeps the
  /// transcript's original casing.
  private static let patterns: [String] = [
    // "add <content> to/in my <name> note"
    #"^(?:add|append|put) (.+?) (?:to|in|into|on) (?:my |the )?(.+?) note[.!]?$"#,
    // "add to my <name> note[:,] <content>"
    #"^(?:add|append) to (?:my |the )?(.+?) note[,:]? (.+?)[.!]?$"#,
  ]

  /// Which capture group is the note name per pattern (the other is
  /// the content).
  private static let nameGroupIndex: [Int] = [2, 1]

  public static func match(_ transcript: String) -> Match? {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let ns = trimmed as NSString
    let fullRange = NSRange(location: 0, length: ns.length)

    for (index, pattern) in patterns.enumerated() {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let m = regex.firstMatch(in: trimmed, range: fullRange),
            m.numberOfRanges == 3
      else { continue }

      let nameGroup = nameGroupIndex[index]
      let contentGroup = nameGroup == 2 ? 1 : 2
      let name = ns.substring(with: m.range(at: nameGroup))
        .trimmingCharacters(in: .whitespaces)
      let content = ns.substring(with: m.range(at: contentGroup))
        .trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, !content.isEmpty else { continue }
      return Match(noteName: name, content: content)
    }
    return nil
  }
}
