//
//  ActionRunStore.swift
//  HexCore
//
//  File-backed persistence for Action-run traces, mirroring RoutineStore:
//  one consolidated `action-runs.json` in Application Support, rewritten
//  atomically. Newest first, capped — traces carry raw service responses
//  and grow fast, and the useful window for "what broke?" is recent.
//

import Foundation
import os

private let runLogger = HexLog.action

public actor ActionRunStore {
  public static let shared = ActionRunStore()

  /// Traces are verbose (raw MCP payloads). Enough to debug a bad week,
  /// not enough to become a second history database.
  public static let maxRuns = 100

  private var cachedURL: URL?
  private let overrideURL: URL?
  private let fileName = "action-runs.json"

  public init(fileURL: URL? = nil) {
    self.overrideURL = fileURL
  }

  // MARK: - Public

  /// Newest first.
  public func loadAll() -> [ActionRun] {
    guard let url = try? fileURL() else { return [] }
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode([ActionRun].self, from: data)
    } catch {
      runLogger.error("ActionRunStore: load failed: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  public func record(_ run: ActionRun) {
    var runs = loadAll()
    runs.insert(run, at: 0)
    if runs.count > Self.maxRuns { runs = Array(runs.prefix(Self.maxRuns)) }
    save(runs)
    runLogger.info(
      "Recorded action run: \(run.steps.count, privacy: .public) step(s), status \(run.status.rawValue, privacy: .public)"
    )
  }

  public func remove(id: UUID) {
    var runs = loadAll()
    runs.removeAll { $0.id == id }
    save(runs)
  }

  public func removeAll() {
    save([])
  }

  // MARK: - Internal

  private func save(_ runs: [ActionRun]) {
    do {
      let url = try fileURL()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(runs).write(to: url, options: [.atomic])
    } catch {
      runLogger.error("ActionRunStore: save failed: \(error.localizedDescription, privacy: .public)")
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
