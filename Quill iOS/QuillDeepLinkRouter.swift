//
//  QuillDeepLinkRouter.swift
//  Quill (iOS)
//
//  Tiny publisher for `quill://` URLs arriving from the home-screen
//  widget (or any other deep-link source — shortcuts, share
//  extensions, etc.). Parses the URL into a `QuillDeepLink` enum and
//  publishes it on `pendingLink`; `ContentView` observes and reacts
//  by, e.g., opening the record flow or showing the notes list.
//
//  URL scheme registered in `Info.plist` under `CFBundleURLTypes`:
//    quill://record  → start recording immediately
//    quill://notes   → present the notes list sheet
//

import Combine
import Foundation

enum QuillDeepLink: Equatable {
  case record
  case notes
}

@MainActor
final class QuillDeepLinkRouter: ObservableObject {
  /// Single app-wide instance — the SwiftUI scene observes it and App
  /// Intents (Siri / Action Button / Shortcuts) publish into it.
  static let shared = QuillDeepLinkRouter()

  /// Monotonically-increasing sequence of pending deep links. Using a
  /// sequence (rather than a single optional) means back-to-back
  /// widget taps don't deduplicate — the consumer sees each one.
  @Published var pendingLink: IdentifiedLink?

  struct IdentifiedLink: Equatable {
    let id: UUID
    let link: QuillDeepLink
  }

  func handle(_ url: URL) {
    guard url.scheme == "quill" else { return }
    let host = url.host(percentEncoded: false) ?? url.path.trimmingCharacters(in: .init(charactersIn: "/"))
    switch host.lowercased() {
    case "record":
      pendingLink = IdentifiedLink(id: UUID(), link: .record)
    case "notes":
      pendingLink = IdentifiedLink(id: UUID(), link: .notes)
    default:
      break
    }
  }

  func consume() {
    pendingLink = nil
  }
}
