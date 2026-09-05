//
//  NoteQuestions.swift
//  Quill (iOS)
//
//  Provider-neutral context selection and cited answers for Ask Quill.
//

import Foundation
import HexCore

struct NoteCitation: Codable, Equatable, Identifiable, Hashable {
  var id: UUID { noteID }
  var noteID: UUID
  var noteTitle: String
  var excerpt: String
}

struct NoteAnswer: Equatable, Hashable {
  var answer: String
  var citations: [NoteCitation]
}

enum NoteAnswerParser {
  private struct Payload: Decodable {
    struct Citation: Decodable {
      var noteID: UUID
      var excerpt: String
    }

    var answer: String
    var citations: [Citation]
  }

  static func parse(_ raw: String, allowedNotes: [Note]) throws -> NoteAnswer {
    let payload = try JSONDecoder().decode(Payload.self, from: JSONPayload.data(from: raw))
    let answerText = payload.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedAnswer = answerText.lowercased()
    guard !answerText.isEmpty,
          !TranscriptRefusalDetector.isRefusal(answerText),
          !normalizedAnswer.contains("system-prompt transformation"),
          !normalizedAnswer.contains("system prompt transformation")
    else { throw TextAIError.invalidResponse }
    let allowed = Dictionary(uniqueKeysWithValues: allowedNotes.map {
      (
        $0.id,
        (
          title: $0.displayTitle,
          source: [$0.displayTitle, NoteContent.stripPhotos(from: $0.body)].joined(separator: "\n")
        )
      )
    })
    var seen: Set<UUID> = []
    let citations = payload.citations.compactMap { citation -> NoteCitation? in
      guard let note = allowed[citation.noteID], seen.insert(citation.noteID).inserted else { return nil }
      let excerpt = citation.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !excerpt.isEmpty,
            note.source.localizedCaseInsensitiveContains(excerpt) else { return nil }
      return NoteCitation(noteID: citation.noteID, noteTitle: note.title, excerpt: excerpt)
    }
    return NoteAnswer(
      answer: answerText,
      citations: citations
    )
  }
}

enum NoteQuestionRequestBuilder {
  static func build(question: String, context: String) -> String {
    """
    <question>\(question.xmlEscaped)</question>

    <notes>
    \(context)
    </notes>
    """
  }
}

enum NoteQuestionContextBuilder {
  private static let stopWords: Set<String> = [
    "a", "an", "and", "are", "did", "do", "for", "from", "how", "i", "in",
    "is", "it", "me", "my", "of", "on", "the", "to", "was", "we", "what",
    "when", "where", "which", "who", "with",
  ]

  static func select(
    notes: [Note],
    question: String,
    maxNotes: Int = 8,
    maxCharacters: Int = 24_000
  ) -> [Note] {
    guard maxNotes > 0, maxCharacters > 0 else { return [] }
    let terms = tokens(in: question).subtracting(stopWords)
    let scored = notes.map { (note: $0, score: score($0, terms: terms)) }
    let hasLexicalMatch = scored.contains { $0.score > 0 }
    let ranked = scored
      .filter { !hasLexicalMatch || $0.score > 0 }
      .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.note.updatedAt > rhs.note.updatedAt
      }
      .map(\.note)

    var selected: [Note] = []
    var used = 0
    for note in ranked {
      guard selected.count < maxNotes else { break }
      let cost = note.displayTitle.count + NoteContent.stripPhotos(from: note.body).count + 80
      if !selected.isEmpty, used + cost > maxCharacters { continue }
      selected.append(note)
      used += min(cost, maxCharacters)
    }
    return selected
  }

  static func context(
    from notes: [Note],
    question: String = "",
    maxCharacters: Int = 12_000
  ) -> String {
    var remaining = maxCharacters
    var blocks: [String] = []
    for (index, note) in notes.enumerated() where remaining > 0 {
      let body = NoteContent.stripPhotos(from: note.body)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let header = "<note id=\"\(note.id.uuidString)\" title=\"\(note.displayTitle.xmlEscaped)\">\n"
      let footer = "\n</note>"
      let notesLeft = max(1, notes.count - index)
      let fairShare = max(700, remaining / notesLeft)
      let availableBody = max(0, min(3_500, fairShare) - header.count - footer.count)
      guard availableBody > 0 else { break }
      let excerpt = relevantExcerpt(from: body, question: question, limit: availableBody)
      let block = header + excerpt.xmlEscaped + footer
      guard block.count <= remaining else { continue }
      blocks.append(block)
      remaining -= block.count
    }
    return blocks.joined(separator: "\n\n")
  }

  /// Pulls the passages that overlap the question rather than always taking
  /// the beginning of a long transcript. This matters for talks and extended
  /// dictations where the relevant topic may arrive much later.
  private static func relevantExcerpt(from body: String, question: String, limit: Int) -> String {
    guard body.count > limit else { return body }
    let terms = tokens(in: question).subtracting(stopWords)
    let paragraphs = body
      .components(separatedBy: CharacterSet.newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let ranked = paragraphs.enumerated().sorted { lhs, rhs in
      let left = terms.intersection(tokens(in: lhs.element)).count
      let right = terms.intersection(tokens(in: rhs.element)).count
      if left != right { return left > right }
      return lhs.offset < rhs.offset
    }
    var picked: [(Int, String)] = []
    var used = 0
    for candidate in ranked where used < limit {
      let clipped = window(candidate.element, around: terms, limit: limit - used)
      guard !clipped.isEmpty else { continue }
      picked.append((candidate.offset, clipped))
      used += clipped.count + 1
    }
    let result = picked.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
    return result.isEmpty ? String(body.prefix(limit)) : String(result.prefix(limit))
  }

  private static func window(_ text: String, around terms: Set<String>, limit: Int) -> String {
    guard limit > 0, text.count > limit else { return text }
    let match = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.min {
      text.distance(from: text.startIndex, to: $0.lowerBound)
        < text.distance(from: text.startIndex, to: $1.lowerBound)
    }
    guard let match else { return String(text.prefix(limit)) }
    let center = text.distance(from: text.startIndex, to: match.lowerBound)
    let startOffset = max(0, min(text.count - limit, center - limit / 3))
    let start = text.index(text.startIndex, offsetBy: startOffset)
    let end = text.index(start, offsetBy: min(limit, text.distance(from: start, to: text.endIndex)))
    return String(text[start..<end])
  }

  private static func score(_ note: Note, terms: Set<String>) -> Int {
    let titleTokens = tokens(in: note.displayTitle)
    let bodyTokens = tokens(in: NoteContent.stripPhotos(from: note.body))
    return terms.reduce(into: 0) { total, term in
      if titleTokens.contains(term) { total += 5 }
      if bodyTokens.contains(term) { total += 1 }
    }
  }

  private static func tokens(in text: String) -> Set<String> {
    Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
  }
}

private enum JSONPayload {
  static func data(from raw: String) throws -> Data {
    let stripped = raw
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = stripped.firstIndex(of: "{"),
          let end = stripped.lastIndex(of: "}") else {
      throw TextAIError.invalidResponse
    }
    return Data(stripped[start...end].utf8)
  }
}

private extension String {
  var xmlEscaped: String {
    replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
