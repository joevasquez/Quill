//
//  ConnectionMentions.swift
//  HexCore
//
//  `@`-mention tagging for typed agent commands: "draft a reply to Mike
//  @Gmail and log it in @Dex". The mention is a hard targeting signal, not
//  a hint — see `ActTargeting`.
//
//  Pure string logic so both typed-command surfaces (macOS Home / menu-bar
//  panel, iOS TypedActionSheet) share one grammar and one set of tests.
//
//  Grammar, deliberately small:
//  - `@` opens a mention only at the start of the text or after whitespace,
//    so emails and handles inside a sentence don't pop a menu.
//  - A completed mention is the literal destination name ("@Google Calendar").
//    Multi-word names round-trip because extraction matches against the known
//    destination list longest-name-first rather than guessing at a delimiter.
//  - An `@` token matching nothing stays literal text. Never silently dropped.
//

import Foundation

public enum ConnectionMentions {
  public static let trigger: Character = "@"

  // MARK: - Autocomplete

  /// The in-progress mention the caret sits in, if any. Returns the query
  /// (text between the `@` and the caret, possibly empty) and the range of
  /// the whole token including the `@`.
  ///
  /// Caret-relative rather than end-of-string, so going back to tag
  /// something mid-sentence works. Callers with no caret to offer (a plain
  /// SwiftUI `TextField` doesn't expose one) can use the overload below,
  /// which assumes the end.
  public static func activeQuery(
    in text: String,
    caret: String.Index
  ) -> (query: String, range: Range<String.Index>)? {
    let head = text[text.startIndex ..< caret]
    guard let at = head.lastIndex(of: trigger) else { return nil }

    // Must open at the start of the text or after whitespace.
    if at != text.startIndex {
      let before = text[text.index(before: at)]
      guard before.isWhitespace else { return nil }
    }

    let query = String(head[head.index(after: at)...])
    // A newline ends a mention; so does a query long enough that the user
    // is clearly typing prose past a mention they never completed.
    guard !query.contains(where: \.isNewline), query.count <= 40 else { return nil }
    return (query, at ..< caret)
  }

  public static func activeQuery(in text: String) -> (query: String, range: Range<String.Index>)? {
    activeQuery(in: text, caret: text.endIndex)
  }

  /// UTF-16 convenience for AppKit/UIKit callers, whose selection offsets
  /// are UTF-16 based. Out-of-range offsets clamp to the end rather than
  /// trapping — a stale caret from a mid-edit callback shouldn't crash.
  public static func activeQuery(
    in text: String,
    utf16Caret: Int
  ) -> (query: String, range: Range<String.Index>)? {
    let clamped = max(0, min(utf16Caret, text.utf16.count))
    guard let caret = String.Index(String.UTF16View.Index(utf16Offset: clamped, in: text), within: text)
    else { return activeQuery(in: text) }
    return activeQuery(in: text, caret: caret)
  }

  /// Ranges of every completed mention token in `text`, paired with the
  /// destination each resolves to. Drives inline token styling — the text
  /// stays plain, only its presentation changes.
  public static func tokenRanges(
    in text: String,
    destinations: [QuillActDestination]
  ) -> [(range: Range<String.Index>, destination: QuillActDestination)] {
    guard text.contains(trigger), !destinations.isEmpty else { return [] }
    let byLength = destinations.sorted { $0.name.count > $1.name.count }

    var result: [(Range<String.Index>, QuillActDestination)] = []
    var index = text.startIndex

    while index < text.endIndex {
      guard text[index] == trigger else {
        index = text.index(after: index)
        continue
      }
      let atWordStart = index == text.startIndex
        || text[text.index(before: index)].isWhitespace
      guard atWordStart else {
        index = text.index(after: index)
        continue
      }

      let after = text.index(after: index)
      if let match = byLength.first(where: {
        text[after...].lowercased().hasPrefix($0.name.lowercased())
      }) {
        let end = text.index(after, offsetBy: match.name.count)
        result.append((index ..< end, match))
        index = end
      } else {
        index = after
      }
    }
    return result
  }

  /// Destinations matching an in-progress query, best first: prefix matches
  /// before interior matches, then alphabetical. An empty query lists
  /// everything (the menu that opens the moment you type `@`).
  public static func matches(
    query: String,
    among destinations: [QuillActDestination],
    limit: Int = 6
  ) -> [QuillActDestination] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return Array(destinations.prefix(limit)) }

    let scored: [(destination: QuillActDestination, rank: Int)] = destinations.compactMap {
      let name = $0.name.lowercased()
      if name.hasPrefix(needle) { return ($0, 0) }
      // Match a later word too, so "calendar" finds "Google Calendar".
      if name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return ($0, 1) }
      if name.contains(needle) { return ($0, 2) }
      return nil
    }

    return scored
      .sorted { $0.rank == $1.rank ? $0.destination.name < $1.destination.name : $0.rank < $1.rank }
      .prefix(limit)
      .map(\.destination)
  }

  /// An open mention menu: what to show, and what accepting it replaces.
  public struct Menu: Equatable, Sendable {
    public let query: String
    public let range: Range<String.Index>
    public let matches: [QuillActDestination]
  }

  /// The mention menu for the current caret, or nil when there shouldn't be
  /// one. Single entry point for both platforms so the open/close rules
  /// can't drift.
  ///
  /// Closes on an exact name match, which is what stops the menu from
  /// hanging around after a selection: `complete` writes "@Dex ", and a
  /// query is allowed to contain spaces (for "Google Calendar"), so "Dex "
  /// would otherwise keep matching Dex forever.
  public static func menu(
    in text: String,
    utf16Caret: Int? = nil,
    destinations: [QuillActDestination],
    limit: Int = 6
  ) -> Menu? {
    guard !destinations.isEmpty else { return nil }
    let active = utf16Caret.map { activeQuery(in: text, utf16Caret: $0) } ?? activeQuery(in: text)
    guard let active else { return nil }

    let needle = active.query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !destinations.contains(where: { $0.name.lowercased() == needle }) else { return nil }

    let matches = matches(query: active.query, among: destinations, limit: limit)
    guard !matches.isEmpty else { return nil }
    return Menu(query: active.query, range: active.range, matches: matches)
  }

  /// Text with the in-progress mention replaced by the completed one, plus a
  /// trailing space so the user keeps typing rather than editing.
  public static func complete(
    _ text: String,
    with destination: QuillActDestination,
    replacing range: Range<String.Index>
  ) -> String {
    text.replacingCharacters(in: range, with: "\(trigger)\(destination.name) ")
  }

  // MARK: - Extraction

  public struct Extraction: Equatable, Sendable {
    /// The command with mention tokens removed — what the planner sees.
    public let text: String
    /// Destinations the user tagged, in the order they appeared, deduped.
    public let pinned: [QuillActDestination]

    public init(text: String, pinned: [QuillActDestination]) {
      self.text = text
      self.pinned = pinned
    }
  }

  /// Strips `@Destination` tokens and returns them as structured pins.
  ///
  /// Tokens are removed rather than left in place because the model reads
  /// "@Dex" as prose and will happily echo it into a task title. The pin is
  /// re-stated to the planner as a directive instead (`ActTargeting`).
  public static func extract(
    from text: String,
    destinations: [QuillActDestination]
  ) -> Extraction {
    guard text.contains(trigger), !destinations.isEmpty else {
      return Extraction(text: text, pinned: [])
    }

    // Longest name first so "@Google Calendar" isn't clipped to "@Google".
    let byLength = destinations.sorted { $0.name.count > $1.name.count }

    var result = ""
    var pinned: [QuillActDestination] = []
    var index = text.startIndex

    while index < text.endIndex {
      let character = text[index]
      guard character == trigger else {
        result.append(character)
        index = text.index(after: index)
        continue
      }

      // Only at a word boundary — "joe@dex.com" is an address, not a pin.
      let atWordStart = index == text.startIndex
        || (result.last.map(\.isWhitespace) ?? true)
      guard atWordStart else {
        result.append(character)
        index = text.index(after: index)
        continue
      }

      let after = text.index(after: index)
      let remainder = text[after...]
      if let match = byLength.first(where: {
        remainder.lowercased().hasPrefix($0.name.lowercased())
      }) {
        if !pinned.contains(match) { pinned.append(match) }
        index = text.index(after, offsetBy: match.name.count)
        // Swallow one following space so "@Dex log this" doesn't become
        // a double space.
        if index < text.endIndex, text[index] == " " {
          index = text.index(after: index)
        }
        continue
      }

      // Unknown tag — leave it exactly as typed.
      result.append(character)
      index = after
    }

    let cleaned = result
      .replacingOccurrences(of: "  ", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Extraction(text: cleaned, pinned: pinned)
  }
}
