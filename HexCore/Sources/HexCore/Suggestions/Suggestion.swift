//
//  Suggestion.swift
//  HexCore
//
//  Proactive suggestions (Pro): a calm nudge layer over Act mode. Each
//  suggestion is backed by pre-built `ActionIntent`s so accepting one opens
//  the SAME editable confirmation sheet a voice command would, pre-filled.
//  Never auto-executed — review-before-run is absolute in v1.
//

import Foundation

/// A source Quill can read to produce suggestions. Hues follow the design
/// handoff's destination registry (`DESTS` in q-tokens): Gmail 330 · Dex 32 ·
/// Calendar 255 · Todoist 12 · Reminders 25.
public enum SuggestionSource: String, Codable, CaseIterable, Sendable, Identifiable {
  case gmail
  case dex
  case calendar
  case todoist
  case reminders

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .gmail: "Gmail"
    case .dex: "Dex"
    case .calendar: "Calendar"
    case .todoist: "Todoist"
    case .reminders: "Reminders"
    }
  }

  /// OKLCH hue for the source tint (rendered via `QuillDesign.destination`).
  public var hue: Double {
    switch self {
    case .gmail: 330
    case .dex: 32
    case .calendar: 255
    case .todoist: 12
    case .reminders: 25
    }
  }

  public var systemImage: String {
    switch self {
    case .gmail: "envelope.fill"
    case .dex: "person.crop.circle.fill"
    case .calendar: "calendar"
    case .todoist: "checkmark.circle.fill"
    case .reminders: "list.bullet.circle.fill"
    }
  }

  /// Per the handoff's Settings spec, Reminders is opted out by default.
  public var enabledByDefault: Bool { self != .reminders }
}

/// A ready-to-act nudge. `intents` are the pre-built steps that pre-fill the
/// confirmation sheet — the same `ActionIntent` vocabulary the voice pipeline
/// produces, so execution reuses the existing path unchanged.
public struct Suggestion: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var source: SuggestionSource
  public var headline: String
  /// One-line rationale shown under the headline with a spark glyph.
  public var why: String
  public var intents: [ActionIntent]
  public var generatedAt: Date

  public init(
    id: UUID = UUID(),
    source: SuggestionSource,
    headline: String,
    why: String,
    intents: [ActionIntent],
    generatedAt: Date = Date()
  ) {
    self.id = id
    self.source = source
    self.headline = headline
    self.why = why
    self.intents = intents
    self.generatedAt = generatedAt
  }

  /// Stable identity across regenerations, so a dismissed suggestion stays
  /// dismissed even though each generation pass mints fresh UUIDs.
  public var dedupeKey: String {
    let normalized = headline
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(source.rawValue)|\(normalized)"
  }
}
