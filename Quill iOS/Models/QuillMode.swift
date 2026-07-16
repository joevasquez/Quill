//
//  QuillMode.swift
//  Quill (iOS)
//
//  The capture modes. Mode is chosen on a rail and signalled everywhere by
//  a single hue — the same palette the macOS orb uses.
//
//  This is the iOS counterpart of the macOS `TranscriptionIndicatorView.Mode`.
//  It lives here rather than in HexCore because the iOS rail has a different
//  membership: Edit is note-scoped (it only appears once you're inside a
//  note), so home shows Auto/Dictate/Act and the note view shows
//  Dictate/Edit/Act.
//

import HexCore
import SwiftUI

enum QuillMode: String, CaseIterable, Identifiable, Sendable {
  /// Quill picks the format — and may route the capture to the agent.
  case auto
  /// Transcribe & format. Carries the format sub-filters.
  case dictate
  /// Conversational revision of an existing note. Note-scoped.
  case edit
  /// Do something with it — routes to a connected destination.
  case act

  var id: String { rawValue }

  /// Modes offered on the home screen. Edit is absent: there's nothing to
  /// revise until a note is open.
  static let homeOrder: [QuillMode] = [.auto, .dictate, .act]
  /// Modes offered in a note's composer.
  static let noteOrder: [QuillMode] = [.dictate, .edit, .act]

  var label: String {
    switch self {
    case .auto: "Auto"
    case .dictate: "Dictate"
    case .edit: "Edit"
    case .act: "Act"
    }
  }

  var subtitle: String {
    switch self {
    case .auto: "Quill picks the format"
    case .dictate: "Transcribe & format"
    case .edit: "Revise this note"
    case .act: "Do something with it"
    }
  }

  var systemImage: String {
    switch self {
    case .auto: "sparkles"
    case .dictate: "waveform"
    case .edit: "square.and.pencil"
    case .act: "bolt.fill"
    }
  }

  /// The mode's colour. Shared with macOS via `QuillDesign`.
  var palette: OKLCH {
    switch self {
    case .auto: QuillDesign.ModePalette.auto
    case .dictate: QuillDesign.ModePalette.dictate
    case .edit: QuillDesign.ModePalette.edit
    case .act: QuillDesign.ModePalette.act
    }
  }

  /// Bridges to the shared classifier / pipeline vocabulary. Auto has no
  /// counterpart — it resolves to one of the others before it's used.
  var transcriptionMode: TranscriptionMode? {
    switch self {
    case .auto: nil
    case .dictate: .dictate
    case .edit: .edit
    case .act: .action
    }
  }
}
