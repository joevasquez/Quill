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
  mutating func finalizePendingTranscription(id: UUID, finalText: String) -> String? {
    guard let pendingTranscription, pendingTranscription.id == id else { return nil }
    let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = pendingTranscription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = final.isEmpty ? fallback : final
    self.pendingTranscription = nil
    guard !resolved.isEmpty else { return "" }
    body = Self.appendingParagraph(resolved, to: body)
    updatedAt = Date()
    return resolved
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
