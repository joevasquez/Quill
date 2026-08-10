//
//  SelectionInstruction.swift
//  HexCore
//
//  Recognises "do something to the thing I'm pointing at" by its SHAPE
//  rather than by its vocabulary.
//
//  The keyword list in AutoModeClassifier kept failing one phrasing at a
//  time — "convert to" didn't match "convert THIS INTO bullets", and the fix
//  for that wouldn't have matched "turn this into a table" or "reword this"
//  either. Enumerating a natural-language surface never converges
//  (Lesson #24), so this asks a grammatical question instead: does the
//  utterance open with a verb, and does it point at something?
//
//  That pattern — imperative + deictic — is the same one ComposeSalvage uses
//  for "draft a response to this". This is the edit-side twin, and unlike a
//  verb list it covers verbs nobody thought to write down.
//

import Foundation
import NaturalLanguage

public enum SelectionInstruction {

  /// True when the transcript reads as an instruction aimed at the user's
  /// selection: an imperative opener plus a word pointing at it.
  ///
  /// Callers must already know a selection exists — this only judges the
  /// sentence, never the context.
  ///
  ///     "Convert this into bullets"  → true
  ///     "Reword this"                → true
  ///     "Please tighten this up"     → true
  ///     "I talked to him about this" → false  (opens with a pronoun)
  ///     "Today we discussed this"    → false  (opens with a noun)
  ///     "Send this to Mike"          → false  (dispatch verb, not a transform)
  public static func isEditInstruction(_ transcript: String) -> Bool {
    guard let verb = leadingImperativeVerb(transcript) else { return false }
    guard !dispatchVerbs.contains(verb) else { return false }
    return containsDeictic(transcript)
  }

  // MARK: - Imperative opener

  /// The opening verb, lowercased, or nil when the utterance doesn't start
  /// like a command.
  ///
  /// Leading interjections and adverbs are skipped so "Please convert this"
  /// and "Now clean this up" still read as imperatives. Pronouns, nouns, and
  /// determiners are NOT skipped — they're exactly what distinguishes prose
  /// ("**I** talked to him about this", "**Today** we discussed this") from a
  /// command, and skipping them would find the verb in any sentence at all.
  static func leadingImperativeVerb(_ transcript: String) -> String? {
    let tagger = NLTagger(tagSchemes: [.lexicalClass])
    tagger.string = transcript

    var result: String?
    var skipsRemaining = maxLeadingSkips
    tagger.enumerateTags(
      in: transcript.startIndex..<transcript.endIndex,
      unit: .word,
      scheme: .lexicalClass,
      options: [.omitWhitespace, .omitPunctuation]
    ) { tag, range in
      switch tag {
      case .verb:
        result = transcript[range].lowercased()
        return false
      case .interjection, .adverb, .conjunction:
        // Politeness and filler — keep looking, but not far.
        skipsRemaining -= 1
        return skipsRemaining >= 0
      default:
        return false
      }
    }
    return result
  }

  /// How many filler words may precede the verb. Two covers "Please just
  /// shorten this"; more would start finding verbs deep inside prose.
  private static let maxLeadingSkips = 2

  /// Verbs that mean "put this somewhere else" rather than "change this
  /// text". Without the exclusion, "Send this to Mike" reads as an edit and
  /// would rewrite the user's selection instead of being left alone.
  ///
  /// This is the bounded list, and deliberately the one worth maintaining:
  /// ways to say "dispatch" are far fewer than ways to say "transform".
  private static let dispatchVerbs: Set<String> = [
    "send", "share", "email", "mail", "forward", "text", "message",
    "post", "add", "save", "file", "log", "remind", "schedule",
    "create", "put", "upload", "sync", "assign", "submit",
  ]

  // MARK: - Deictic reference

  /// Words that point at something on screen rather than naming it.
  private static let deictics = [
    "this", "that", "these", "those", "it",
    "the highlighted", "the selection", "the selected",
    "what i highlighted", "what i've highlighted", "what i selected",
  ]

  /// Word-boundary matched, so "this" doesn't fire on "thistle".
  static func containsDeictic(_ transcript: String) -> Bool {
    let normalized = AutoModeClassifier.normalize(transcript)
    return deictics.contains { normalized.contains(" \($0) ") }
  }
}
