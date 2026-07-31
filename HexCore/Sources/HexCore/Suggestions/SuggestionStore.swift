//
//  SuggestionStore.swift
//  HexCore
//
//  Persistence for proactive suggestions. Single `suggestions.json` in
//  Application Support (same pattern as MemoryStore / RoutineStore). Holds
//  the current suggestion set, the dismissed-key map (dismissed stays
//  dismissed across regenerations), and the last-generation timestamp that
//  backs the staleness TTL.
//

import Foundation
import os

private let suggestionLogger = HexLog.app

public actor SuggestionStore {
  public static let shared = SuggestionStore()

  private var cachedURL: URL?
  private let overrideURL: URL?
  private let fileName = "suggestions.json"

  /// Keep the visible feed calm — a nudge layer, not an inbox.
  private let maxSuggestions = 6
  /// Bound the dismissed map so it can't grow forever.
  private let maxDismissedKeys = 300
  private let dismissedRetention: TimeInterval = 60 * 60 * 24 * 60  // 60 days

  private struct State: Codable {
    var suggestions: [Suggestion] = []
    var dismissed: [String: Date] = [:]
    var lastGeneratedAt: Date?
  }

  public init(fileURL: URL? = nil) {
    self.overrideURL = fileURL
  }

  // MARK: - Public

  /// The suggestions to show, dismissed ones already filtered out.
  public func current() -> [Suggestion] {
    let state = load()
    return state.suggestions.filter { state.dismissed[$0.dedupeKey] == nil }
  }

  public func lastGeneratedAt() -> Date? {
    load().lastGeneratedAt
  }

  /// True when a new generation pass is warranted.
  public func isStale(ttl: TimeInterval, now: Date = Date()) -> Bool {
    guard let last = load().lastGeneratedAt else { return true }
    return now.timeIntervalSince(last) > ttl
  }

  /// Replace the suggestion set with a fresh generation pass. Previously
  /// dismissed suggestions (matched by `dedupeKey`) are dropped on the way
  /// in, and the set is capped so the feed stays a nudge, not a backlog.
  public func replaceAll(_ fresh: [Suggestion], at date: Date = Date()) {
    var state = load()
    pruneDismissed(&state, now: date)
    state.suggestions = fresh
      .filter { state.dismissed[$0.dedupeKey] == nil }
      .prefix(maxSuggestions)
      .map { $0 }
    state.lastGeneratedAt = date
    save(state)
  }

  /// Dismiss removes the suggestion AND remembers it, so the same nudge
  /// doesn't come back on the next generation pass.
  public func dismiss(_ suggestion: Suggestion, at date: Date = Date()) {
    var state = load()
    state.dismissed[suggestion.dedupeKey] = date
    state.suggestions.removeAll { $0.id == suggestion.id }
    save(state)
  }

  /// A suggestion that was run is consumed — same terminal state as
  /// dismissal (it shouldn't be re-offered).
  public func consume(_ suggestion: Suggestion, at date: Date = Date()) {
    dismiss(suggestion, at: date)
  }

  /// Master-toggle off / forget-everything path.
  public func clearAll() {
    save(State())
  }

  // MARK: - Persistence

  private func load() -> State {
    guard let url = try? fileURL(),
          FileManager.default.fileExists(atPath: url.path)
    else { return State() }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(State.self, from: data)
    } catch {
      suggestionLogger.error("SuggestionStore: load failed: \(error.localizedDescription, privacy: .public)")
      return State()
    }
  }

  private func save(_ state: State) {
    do {
      let url = try fileURL()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(state)
      try data.write(to: url, options: [.atomic])
    } catch {
      suggestionLogger.error("SuggestionStore: save failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func pruneDismissed(_ state: inout State, now: Date) {
    state.dismissed = state.dismissed.filter {
      now.timeIntervalSince($0.value) < dismissedRetention
    }
    if state.dismissed.count > maxDismissedKeys {
      let keep = state.dismissed
        .sorted { $0.value > $1.value }
        .prefix(maxDismissedKeys)
      state.dismissed = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
  }

  private func fileURL() throws -> URL {
    if let overrideURL { return overrideURL }
    if let cachedURL { return cachedURL }
    let url = try URL.hexApplicationSupport.appendingPathComponent(fileName, isDirectory: false)
    cachedURL = url
    return url
  }
}
