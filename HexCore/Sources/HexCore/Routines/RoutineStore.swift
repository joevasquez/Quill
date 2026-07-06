//
//  RoutineStore.swift
//  HexCore
//
//  File-based JSON persistence for saved routines, mirroring the
//  QueuedActionStore pattern: single consolidated `routines.json` in
//  Application Support, re-written atomically on every mutation. Routine
//  mutations are rare user-driven events; a single file keeps this trivial.
//

import Foundation
import os

private let routineLogger = HexLog.app

public actor RoutineStore {
  public static let shared = RoutineStore()

  private var cachedURL: URL?
  private let overrideURL: URL?
  private let fileName = "routines.json"

  public init(fileURL: URL? = nil) {
    self.overrideURL = fileURL
  }

  // MARK: - Public

  public func loadAll() -> [Routine] {
    guard let url = try? fileURL() else { return [] }
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode([Routine].self, from: data)
    } catch {
      routineLogger.error("RoutineStore: load failed: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  public func save(_ routines: [Routine]) {
    do {
      let url = try fileURL()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(routines)
      try data.write(to: url, options: [.atomic])
    } catch {
      routineLogger.error("RoutineStore: save failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func add(_ routine: Routine) {
    var routines = loadAll()
    routines.append(routine)
    save(routines)
  }

  public func update(_ routine: Routine) {
    var routines = loadAll()
    if let idx = routines.firstIndex(where: { $0.id == routine.id }) {
      routines[idx] = routine
      save(routines)
    }
  }

  public func remove(id: UUID) {
    var routines = loadAll()
    routines.removeAll { $0.id == id }
    save(routines)
  }

  /// Bump run stats after a routine fires.
  public func recordRun(id: UUID, at date: Date = Date()) {
    var routines = loadAll()
    if let idx = routines.firstIndex(where: { $0.id == id }) {
      routines[idx].lastRunAt = date
      routines[idx].runCount += 1
      save(routines)
    }
  }

  // MARK: - Internal

  private func fileURL() throws -> URL {
    if let overrideURL { return overrideURL }
    if let cachedURL { return cachedURL }
    let url = try URL.hexApplicationSupport.appendingPathComponent(fileName, isDirectory: false)
    cachedURL = url
    return url
  }
}
