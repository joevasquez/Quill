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

  init(
    id: UUID = UUID(),
    title: String = "",
    body: String = "",
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    location: NoteLocation? = nil,
    isAutoTitle: Bool = true,
    isPinned: Bool = false
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.location = location
    self.isAutoTitle = isAutoTitle
    self.isPinned = isPinned
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

struct NoteLocation: Codable, Equatable, Hashable {
  var latitude: Double
  var longitude: Double
  /// Best-effort reverse-geocoded label (e.g. "Brooklyn, NY"). Optional
  /// because the geocode may fail even when we have coordinates.
  var placeName: String?
}
