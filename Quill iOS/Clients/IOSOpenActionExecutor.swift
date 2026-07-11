//
//  IOSOpenActionExecutor.swift
//  Quill (iOS)
//
//  Executes an `.open` ActionIntent on iOS. URLs open via
//  `UIApplication.open` (Safari or the URL's registered app). Launching an
//  arbitrary app *by name* isn't possible on iOS (no NSWorkspace), so
//  app-only intents fail with a clear message instead of silently no-oping.
//

import Foundation
import HexCore
import UIKit

enum IOSOpenActionError: LocalizedError {
  case notAnOpenIntent
  case invalidURL(String)
  case openFailed(String)
  case appLaunchUnsupported(String)

  var errorDescription: String? {
    switch self {
    case .notAnOpenIntent:
      "Not an open action"
    case .invalidURL(let raw):
      "\u{201C}\(raw)\u{201D} isn't a valid web address"
    case .openFailed(let url):
      "Couldn't open \(url)"
    case .appLaunchUnsupported(let app):
      "Opening apps by name (\u{201C}\(app)\u{201D}) isn't supported on iPhone — say a website instead"
    }
  }
}

@MainActor
enum IOSOpenActionExecutor {
  /// Opens the intent's URL and returns a short human-readable summary.
  static func execute(_ intent: ActionIntent) async throws -> String {
    guard intent.actionType == .open else { throw IOSOpenActionError.notAnOpenIntent }

    if let raw = intent.urlString, !raw.isEmpty {
      guard let url = normalizedWebURL(raw) else {
        throw IOSOpenActionError.invalidURL(raw)
      }
      let opened = await UIApplication.shared.open(url)
      guard opened else { throw IOSOpenActionError.openFailed(url.absoluteString) }
      return "Opened \(url.absoluteString)"
    }

    // App-launch-only intent — not possible on iOS.
    throw IOSOpenActionError.appLaunchUnsupported(intent.appName ?? "app")
  }

  /// Add https:// when the planner emitted a bare domain, and require an
  /// http(s) scheme — we never open arbitrary custom schemes from voice.
  static func normalizedWebURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
      return (scheme == "http" || scheme == "https") ? url : nil
    }
    return URL(string: "https://" + trimmed)
  }
}
