//
//  OpenActionExecutor.swift
//  Quill (macOS)
//
//  Executes an `.open` ActionIntent: opens a URL (optionally in a named
//  browser) and/or launches a macOS app by name via NSWorkspace. Called from
//  the confirmation panel and the offline queue replay.
//

import AppKit
import Foundation
import HexCore

enum OpenActionError: LocalizedError {
  case nothingToOpen
  case appNotFound(String)

  var errorDescription: String? {
    switch self {
    case .nothingToOpen:
      "Nothing to open — no website or app was recognized"
    case .appNotFound(let name):
      "Couldn't find an app named \u{201C}\(name)\u{201D}"
    }
  }
}

enum OpenActionExecutor {
  /// Opens the URL/app and returns a short human summary for the panel.
  @MainActor
  static func execute(_ intent: ActionIntent) async throws -> String {
    let appName = intent.appName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawURL = intent.urlString?.trimmingCharacters(in: .whitespacesAndNewlines)

    // Case 1: open a URL (optionally in a named browser).
    if let rawURL, !rawURL.isEmpty, let url = normalizedURL(rawURL) {
      let config = NSWorkspace.OpenConfiguration()
      if let appName, !appName.isEmpty {
        guard let appURL = applicationURL(named: appName) else {
          throw OpenActionError.appNotFound(appName)
        }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        return "Opened \(url.absoluteString) in \(appName)"
      }
      NSWorkspace.shared.open(url)
      return "Opened \(url.absoluteString)"
    }

    // Case 2: launch an app by name.
    if let appName, !appName.isEmpty {
      guard let appURL = applicationURL(named: appName) else {
        throw OpenActionError.appNotFound(appName)
      }
      let config = NSWorkspace.OpenConfiguration()
      _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
      return "Launched \(appName)"
    }

    throw OpenActionError.nothingToOpen
  }

  /// Adds an https:// scheme when the user/LLM gave a bare host.
  private static func normalizedURL(_ raw: String) -> URL? {
    if let url = URL(string: raw), url.scheme != nil { return url }
    return URL(string: "https://\(raw)")
  }

  /// Resolves a display name ("Google Chrome", "Safari", "Spotify") to its
  /// app bundle URL via LaunchServices, then the standard app folders.
  private static func applicationURL(named name: String) -> URL? {
    let bare = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    if let path = NSWorkspace.shared.fullPath(forApplication: bare) {
      return URL(fileURLWithPath: path)
    }
    let fm = FileManager.default
    let candidates = [
      "/Applications/\(bare).app",
      "/System/Applications/\(bare).app",
      "\(NSHomeDirectory())/Applications/\(bare).app",
    ]
    for path in candidates where fm.fileExists(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    return nil
  }
}
