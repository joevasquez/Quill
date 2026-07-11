//
//  QuillAppIntents.swift
//  Quill (iOS)
//
//  App Intents so capture is one press away: assign "Start Dictation"
//  to the iPhone Action Button, say "New Quill note" to Siri, or wire
//  either intent into a Shortcut. Both intents open the app and publish
//  into the same `QuillDeepLinkRouter` the home-screen widget uses, so
//  every entry point shares one routing path.
//

import AppIntents
import Foundation

struct StartDictationIntent: AppIntent {
  static let title: LocalizedStringResource = "Start Dictation"
  static let description = IntentDescription(
    "Opens Quill, starts a fresh note, and begins recording immediately."
  )
  static let openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    QuillDeepLinkRouter.shared.handle(URL(string: "quill://record")!)
    return .result()
  }
}

struct OpenNotesIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Notes"
  static let description = IntentDescription("Opens Quill's notes list.")
  static let openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    QuillDeepLinkRouter.shared.handle(URL(string: "quill://notes")!)
    return .result()
  }
}

struct QuillAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartDictationIntent(),
      phrases: [
        "Start dictating in \(.applicationName)",
        "New \(.applicationName) note",
        "Dictate in \(.applicationName)",
      ],
      shortTitle: "Dictate",
      systemImageName: "mic.fill"
    )
    AppShortcut(
      intent: OpenNotesIntent(),
      phrases: [
        "Show my \(.applicationName) notes",
        "Open \(.applicationName) notes",
      ],
      shortTitle: "Notes",
      systemImageName: "note.text"
    )
  }
}
