//
//  NoteEditCommands.swift
//  HexCore
//
//  The in-note AI Edit vocabulary, shared so iOS and macOS offer the same
//  command chips, learned-usage ordering, and past-tense banner labels.
//

import Foundation

public enum NoteEditCommands {
  /// The built-in one-tap edit commands, in display order.
  public static let suggestions: [String] = [
    "Shorten by 20%", "Make it bullets", "Summarize", "Turn into email",
    "Extract action items", "More formal", "Fix grammar",
  ]

  /// Short past-tense summary for the pending-edit banner.
  public static func label(for command: String) -> String {
    let c = command.lowercased()
    if c.contains("shorten") || c.contains("tighten") { return "Shortened" }
    if c.contains("bullet") { return "Reformatted as bullets" }
    if c.contains("summar") { return "Summarized" }
    if c.contains("email") { return "Turned into email" }
    if c.contains("action item") { return "Extracted action items" }
    if c.contains("formal") { return "Tone adjusted" }
    if c.contains("grammar") { return "Grammar polished" }
    return "Note revised"
  }

  // MARK: - Learned-usage ordering

  /// Per-command usage counts, persisted as `[String: Int]` JSON (the same
  /// format the iOS `EditCommandUsage` helper uses, under the shared
  /// `quill.editCommandUsage` UserDefaults key).
  public static func decodeUsage(_ data: Data) -> [String: Int] {
    guard !data.isEmpty,
          let counts = try? JSONDecoder().decode([String: Int].self, from: data)
    else { return [:] }
    return counts
  }

  public static func encodeUsage(_ counts: [String: Int]) -> Data {
    (try? JSONEncoder().encode(counts)) ?? Data()
  }

  /// Bump `command`'s count and return the re-encoded blob.
  public static func recordUsage(_ command: String, in data: Data) -> Data {
    var counts = decodeUsage(data)
    counts[command, default: 0] += 1
    return encodeUsage(counts)
  }

  /// The `limit` most-used commands, most-used first. Ties break
  /// alphabetically so the row doesn't reshuffle on every render.
  public static func mostUsed(_ data: Data, limit: Int = 3) -> [String] {
    decodeUsage(data)
      .sorted { a, b in
        a.value == b.value ? a.key < b.key : a.value > b.value
      }
      .prefix(limit)
      .map(\.key)
  }
}
