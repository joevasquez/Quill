//
//  Note.swift
//  Quill (iOS)
//
//  Local-only note model. Each note is a flat text blob that recordings
//  append to. The "active" note is tracked separately in NotesStore —
//  every recording extends the active note unless the user explicitly
//  starts a new one.
//

import Foundation
import HexCore

struct NoteSpeakerLabelOccurrence: Equatable {
  let transcriptionID: UUID
  let speakerID: String
  let displayName: String
  let colorIndex: Int
  let utf16Location: Int
}

struct Note: Codable, Identifiable, Equatable, Hashable {
  var id: UUID
  var title: String
  var body: String
  var createdAt: Date
  var updatedAt: Date
  /// Where the note was started. Captured once at creation when location
  /// permission is granted; never updated on subsequent appends so the
  /// value reflects "where this thought began."
  var location: NoteLocation?
  /// When true, the title is eligible for automatic generation
  /// (either from `Note.derivedTitle` as a display fallback, or via
  /// `TextAIClient.generateTitle` after the first append). Set to
  /// `false` the moment the user renames manually OR the AI writes
  /// a real title, so subsequent appends don't keep re-titling the
  /// note out from under the user.
  var isAutoTitle: Bool
  /// Pinned notes sort to the top of the notes list.
  var isPinned: Bool
  /// A best-effort live transcript that has not yet been replaced by the
  /// authoritative Whisper result. Kept separate from `body` so recognition
  /// revisions never rewrite existing note text or create duplicate words.
  ///
  /// This is persisted locally for interruption/crash recovery, but it is not
  /// included in `SyncableNote` and therefore never reaches cloud sync before
  /// the capture is finalized.
  var pendingTranscription: PendingTranscription?
  /// Set while an Edit-mode revision is awaiting Undo/Keep. Holds the
  /// previous body so Undo is lossless. Cleared when the user accepts or
  /// reverts.
  ///
  /// Deliberately local: it isn't uploaded by cloud sync, since a pending
  /// review on your phone shouldn't follow you to the Mac.
  var pendingEdit: NoteEdit?
  /// Local originals and retry configuration, retained after cleanup.
  var transcriptions: [NoteTranscription] = []

  init(
    id: UUID = UUID(),
    title: String = "",
    body: String = "",
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    location: NoteLocation? = nil,
    isAutoTitle: Bool = true,
    isPinned: Bool = false,
    pendingTranscription: PendingTranscription? = nil,
    pendingEdit: NoteEdit? = nil
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.location = location
    self.isAutoTitle = isAutoTitle
    self.isPinned = isPinned
    self.pendingTranscription = pendingTranscription
    self.pendingEdit = pendingEdit
  }

  /// Custom Codable init so notes persisted before the
  /// `isAutoTitle` field existed decode cleanly. Legacy notes
  /// default to `false` — they already have a title the user has
  /// been living with, so we don't want the AI-title feature to
  /// retroactively overwrite it.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    body = try c.decode(String.self, forKey: .body)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    location = try c.decodeIfPresent(NoteLocation.self, forKey: .location)
    isAutoTitle = try c.decodeIfPresent(Bool.self, forKey: .isAutoTitle) ?? false
    isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    pendingTranscription = try c.decodeIfPresent(PendingTranscription.self, forKey: .pendingTranscription)
    pendingEdit = try c.decodeIfPresent(NoteEdit.self, forKey: .pendingEdit)
    transcriptions = try c.decodeIfPresent([NoteTranscription].self, forKey: .transcriptions) ?? []
  }

  /// Apply a retry only to the unchanged capture at the end of this note.
  /// An edit or another recording taking place during cleanup wins.
  mutating func applyCleanup(recordID: UUID, text: String, expectedBody: String) -> Bool {
    guard body == expectedBody, pendingTranscription == nil,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let index = transcriptions.firstIndex(where: { $0.id == recordID }),
          !transcriptions[index].appliedText.isEmpty,
          body.hasSuffix(transcriptions[index].appliedText) else { return false }
    body = String(body.dropLast(transcriptions[index].appliedText.count)) + text
    transcriptions[index].appliedText = text
    transcriptions[index].cleanupError = nil
    updatedAt = Date()
    return true
  }

  /// Only untouched, content-free drafts may be discarded on navigation.
  /// A title, photo marker, original transcript, or pending work counts as content.
  var isEmptyDraft: Bool {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && pendingTranscription == nil
      && pendingEdit == nil
      && transcriptions.isEmpty
  }

  /// The note body as rendered while recording. The durable body remains
  /// unchanged until finalization; the provisional paragraph is only joined
  /// for display.
  var bodyIncludingPendingTranscription: String {
    Self.appendingParagraph(pendingTranscription?.text ?? "", to: body)
  }

  mutating func beginPendingTranscription(id: UUID, at date: Date = Date()) {
    pendingTranscription = PendingTranscription(
      id: id,
      text: "",
      startedAt: date,
      updatedAt: date
    )
  }

  /// Replaces the recognizer's previous full best guess. Returns false for a
  /// stale callback from an older recording session.
  @discardableResult
  mutating func updatePendingTranscription(
    id: UUID,
    text: String,
    at date: Date = Date()
  ) -> Bool {
    guard pendingTranscription?.id == id else { return false }
    pendingTranscription?.text = text
    pendingTranscription?.updatedAt = date
    return true
  }

  /// Replaces the provisional paragraph with the authoritative result. If
  /// final transcription failed, an empty `finalText` falls back to the last
  /// live partial so the recoverable words are still kept.
  @discardableResult
  mutating func finalizePendingTranscription(
    id: UUID,
    finalText: String,
    speakerTranscript: SpeakerTranscript? = nil
  ) -> String? {
    guard let pendingTranscription, pendingTranscription.id == id else { return nil }
    let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = pendingTranscription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = final.isEmpty ? fallback : final
    self.pendingTranscription = nil
    if !resolved.isEmpty {
      transcriptions.append(NoteTranscription(
        id: id, recordedAt: pendingTranscription.startedAt,
        original: pendingTranscription.originalText ?? fallback,
        appliedText: resolved,
        speakerTranscript: speakerTranscript
      ))
    }
    guard !resolved.isEmpty else { return "" }
    body = Self.appendingParagraph(resolved, to: body)
    updatedAt = Date()
    return resolved
  }

  /// Renames one diarized speaker and rewrites the exact transcript block
  /// in the note body. If the user has edited that block since capture, the
  /// rename is rejected rather than replacing unrelated text.
  @discardableResult
  mutating func renameSpeaker(
    transcriptionID: UUID,
    speakerID: String,
    to name: String
  ) -> Bool {
    guard let index = transcriptions.firstIndex(where: { $0.id == transcriptionID }),
          var conversation = transcriptions[index].speakerTranscript
    else { return false }

    let previousText = transcriptions[index].appliedText
    let previousLabel = conversation.displayName(for: speakerID) + ":"
    conversation.renameSpeaker(id: speakerID, to: name)
    let renamedLabel = conversation.displayName(for: speakerID) + ":"
    let renamedText = previousText
      .components(separatedBy: .newlines)
      .map { $0 == previousLabel ? renamedLabel : $0 }
      .joined(separator: "\n")
    guard let range = bodyRange(forTranscriptionAt: index) else { return false }

    body.replaceSubrange(range, with: renamedText)
    transcriptions[index].appliedText = renamedText
    transcriptions[index].speakerTranscript = conversation
    updatedAt = Date()
    return true
  }

  private func bodyRange(forTranscriptionAt targetIndex: Int) -> Range<String.Index>? {
    var searchStart = body.startIndex
    for index in transcriptions.indices {
      let appliedText = transcriptions[index].appliedText
      guard !appliedText.isEmpty,
            let range = body.range(of: appliedText, range: searchStart..<body.endIndex)
      else { continue }
      if index == targetIndex { return range }
      searchStart = range.upperBound
    }
    return nil
  }

  /// Keeps a recording's editable body block anchored when a manual edit
  /// changes its words but leaves the speaker label lines intact. The timed
  /// original remains untouched in `speakerTranscript`.
  mutating func updateBodyPreservingSpeakerLabels(_ newBody: String) {
    guard newBody != body else { return }
    let old = body as NSString
    let new = newBody as NSString
    let prefixLimit = min(old.length, new.length)
    var prefix = 0
    while prefix < prefixLimit, old.character(at: prefix) == new.character(at: prefix) {
      prefix += 1
    }
    var suffix = 0
    while suffix < old.length - prefix,
          suffix < new.length - prefix,
          old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) {
      suffix += 1
    }
    let changedEnd = old.length - suffix
    let delta = new.length - old.length

    for index in transcriptions.indices {
      guard let conversation = transcriptions[index].speakerTranscript else { continue }
      guard let range = bodyRange(forTranscriptionAt: index),
            let start = range.lowerBound.samePosition(in: body.utf16),
            let end = range.upperBound.samePosition(in: body.utf16)
      else { continue }
      let startOffset = body.utf16.distance(from: body.utf16.startIndex, to: start)
      let endOffset = body.utf16.distance(from: body.utf16.startIndex, to: end)
      guard prefix >= startOffset, changedEnd <= endOffset else { continue }
      // A new paragraph after the recording is independent note content,
      // not an edit to the final spoken turn.
      if prefix == endOffset, changedEnd == endOffset,
         new.substring(from: prefix).hasPrefix("\n\n") {
        continue
      }
      let newLength = endOffset - startOffset + delta
      guard newLength >= 0, startOffset + newLength <= new.length else { continue }
      let candidate = new.substring(with: NSRange(location: startOffset, length: newLength))
      let previousLabels = speakerLabelLines(in: transcriptions[index].appliedText, conversation: conversation)
      let candidateLabels = speakerLabelLines(in: candidate, conversation: conversation)
      guard previousLabels == candidateLabels else { continue }
      transcriptions[index].appliedText = candidate
      break
    }
    body = newBody
    updatedAt = Date()
  }

  private func speakerLabelLines(in text: String, conversation: SpeakerTranscript) -> [String] {
    let labels = Set(conversation.speakers.map { conversation.displayName(for: $0.id) + ":" })
    return text.components(separatedBy: "\n").filter { labels.contains($0) }
  }

  var transcriptionMetadataJSON: String? {
    let speakerRecords = transcriptions.compactMap(SyncedSpeakerTranscription.init)
    guard !speakerRecords.isEmpty,
          let data = try? JSONEncoder().encode(speakerRecords)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  mutating func restoreTranscriptionMetadata(from json: String) {
    guard let data = json.data(using: .utf8) else { return }
    let records: [NoteTranscription]
    if let compact = try? JSONDecoder().decode([SyncedSpeakerTranscription].self, from: data) {
      records = compact.map(\.noteTranscription)
    } else if let legacy = try? JSONDecoder().decode([NoteTranscription].self, from: data) {
      records = legacy
    } else {
      return
    }
    let incomingIDs = Set(records.map(\.id))
    transcriptions.removeAll { incomingIDs.contains($0.id) }
    transcriptions.append(contentsOf: records)
    transcriptions.sort { $0.recordedAt < $1.recordedAt }
  }

  /// Cloud only needs the editable block plus speaker identity to render and
  /// rename pills. Raw audio-derived utterances, retry prompts, and duplicate
  /// originals stay local; omitting them roughly halves long-meeting payloads.
  private struct SyncedSpeakerTranscription: Codable {
    var id: UUID
    var recordedAt: Date
    var appliedText: String
    var speakers: [TranscriptSpeaker]

    init?(_ transcription: NoteTranscription) {
      guard let speakerTranscript = transcription.speakerTranscript else { return nil }
      id = transcription.id
      recordedAt = transcription.recordedAt
      appliedText = transcription.appliedText
      speakers = speakerTranscript.speakers
    }

    var noteTranscription: NoteTranscription {
      NoteTranscription(
        id: id,
        recordedAt: recordedAt,
        original: "",
        appliedText: appliedText,
        speakerTranscript: SpeakerTranscript(speakers: speakers, utterances: [])
      )
    }
  }

  /// Finds the speaker-label lines that still belong to their original
  /// recording block in the note body. The absolute offsets let the reading
  /// view distinguish two separate recordings that both contain "Speaker 1".
  /// If a user substantially edits a transcript block, it intentionally stops
  /// becoming interactive rather than risking a rename in the wrong place.
  var speakerLabelOccurrences: [NoteSpeakerLabelOccurrence] {
    var result: [NoteSpeakerLabelOccurrence] = []
    var searchStart = body.startIndex

    for transcription in transcriptions {
      guard let conversation = transcription.speakerTranscript,
            !transcription.appliedText.isEmpty,
            searchStart <= body.endIndex,
            let blockRange = body.range(
              of: transcription.appliedText,
              range: searchStart..<body.endIndex
            )
      else { continue }

      let blockStart = body.utf16.distance(
        from: body.utf16.startIndex,
        to: blockRange.lowerBound.samePosition(in: body.utf16) ?? body.utf16.startIndex
      )
      var relativeLocation = 0
      let lines = transcription.appliedText.components(separatedBy: "\n")
      for line in lines {
        if let speaker = conversation.speakers.first(where: {
          line == conversation.displayName(for: $0.id) + ":"
        }) {
          result.append(NoteSpeakerLabelOccurrence(
            transcriptionID: transcription.id,
            speakerID: speaker.id,
            displayName: conversation.displayName(for: speaker.id),
            colorIndex: speaker.colorIndex,
            utf16Location: blockStart + relativeLocation
          ))
        }
        relativeLocation += line.utf16.count + 1
      }
      searchStart = blockRange.upperBound
    }

    return result
  }

  @discardableResult
  mutating func discardPendingTranscription(id: UUID) -> Bool {
    guard pendingTranscription?.id == id else { return false }
    pendingTranscription = nil
    return true
  }

  /// Promotes a draft left by a terminated/interrupted recording. Called on
  /// store load so recovered text becomes ordinary note content and can sync.
  @discardableResult
  mutating func recoverPendingTranscription() -> Bool {
    guard let pendingTranscription else { return false }
    let recovered = pendingTranscription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    self.pendingTranscription = nil
    if !recovered.isEmpty {
      transcriptions.append(NoteTranscription(
        id: pendingTranscription.id, recordedAt: pendingTranscription.startedAt,
        original: pendingTranscription.originalText ?? recovered, appliedText: recovered
      ))
    }
    guard !recovered.isEmpty else { return false }
    body = Self.appendingParagraph(recovered, to: body)
    updatedAt = max(updatedAt, pendingTranscription.updatedAt)
    return true
  }

  private static func appendingParagraph(_ paragraph: String, to body: String) -> String {
    let paragraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !paragraph.isEmpty else { return body }
    return body.isEmpty ? paragraph : body + "\n\n" + paragraph
  }

  /// Derive a title from the first meaningful line of body text.
  /// Used when a user hasn't set a custom title yet. Photo tokens are
  /// stripped first so a note that starts with an image still derives
  /// a sensible title from the surrounding prose.
  static func derivedTitle(from body: String) -> String {
    let textOnly = NoteContent.stripPhotos(from: body)
    guard !textOnly.isEmpty else { return "New Note" }

    let firstLine = textOnly.components(separatedBy: .newlines).first ?? textOnly
    let words = firstLine.split(separator: " ", omittingEmptySubsequences: true).prefix(6)
    let candidate = words.joined(separator: " ")
    let clipped = String(candidate.prefix(60))
    return clipped.isEmpty ? "New Note" : clipped
  }

  var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? Note.derivedTitle(from: body) : trimmed
  }

  var wordCount: Int {
    NoteContent.stripPhotos(from: body).split { $0.isWhitespace || $0.isNewline }.count
  }

  /// Count of inline photos embedded in the note body.
  var photoCount: Int {
    NoteContent.photoIDs(in: body).count
  }
}

/// Session-scoped live recognition state. `SFSpeechRecognizer` publishes its
/// whole best guess on every update, so this value is replaced rather than
/// appended until Whisper supplies the final transcript.
struct PendingTranscription: Codable, Equatable, Hashable {
  var id: UUID
  var text: String
  var startedAt: Date
  var updatedAt: Date
  var originalText: String?
}

struct NoteTranscription: Codable, Equatable, Hashable, Identifiable {
  var id: UUID
  var recordedAt: Date
  var original: String
  var appliedText: String
  var cleanupMode: AIProcessingMode?
  var provider: AIProvider?
  var customPrompt: String?
  var cleanupError: String?
  var speakerTranscript: SpeakerTranscript? = nil
}

/// A revision awaiting the user's Undo/Keep. Stores the previous body so
/// reverting restores exactly what was there.
struct NoteEdit: Codable, Equatable, Hashable {
  /// The body as it was before the edit.
  var previousBody: String
  /// Short past-tense summary for the banner, e.g. "Shortened".
  var label: String
  var editedAt: Date

  init(previousBody: String, label: String, editedAt: Date = Date()) {
    self.previousBody = previousBody
    self.label = label
    self.editedAt = editedAt
  }
}

struct NoteLocation: Codable, Equatable, Hashable {
  var latitude: Double
  var longitude: Double
  /// Best-effort reverse-geocoded label (e.g. "Brooklyn, NY"). Optional
  /// because the geocode may fail even when we have coordinates.
  var placeName: String?
}
