//
//  MemoryStore.swift
//  HexCore
//
//  Local-first persistence for the agent's memory. Single `agent-memory.json`
//  in Application Support (same pattern as QueuedActionStore / RoutineStore).
//  Nothing here syncs to the cloud — memory stays on-device until per-user
//  isolated sync (accounts phase) exists.
//

import Foundation
import os

private let memoryLogger = HexLog.app

public actor MemoryStore {
  public static let shared = MemoryStore()

  private var cachedURL: URL?
  private let overrideURL: URL?
  private let fileName = "agent-memory.json"

  /// Keep the store bounded — least-recently-seen entities are evicted past
  /// this count so the file (and the planner context pool) can't grow forever.
  private let maxEntities = 400

  public init(fileURL: URL? = nil) {
    self.overrideURL = fileURL
  }

  // MARK: - Public

  public func loadAll() -> [MemoryEntity] {
    guard let url = try? fileURL() else { return [] }
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode([MemoryEntity].self, from: data)
    } catch {
      memoryLogger.error("MemoryStore: load failed: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  /// Merge extraction candidates into the store. Matching is by normalized
  /// name or alias (case-insensitive): a match merges details (new values
  /// win), unions aliases, bumps `occurrences`, and refreshes `lastSeenAt`;
  /// otherwise a new entity is created.
  public func upsert(_ candidates: [MemoryCandidate], at date: Date = Date()) {
    guard !candidates.isEmpty else { return }
    var entities = loadAll()

    for candidate in candidates {
      let candidateNames = ([candidate.name] + (candidate.aliases ?? [])).map(normalizeName)
      if let idx = entities.firstIndex(where: { existing in
        existing.kind == candidate.kind && !Set(existingNames(of: existing)).isDisjoint(with: candidateNames)
      }) {
        var entity = entities[idx]
        let known = Set(existingNames(of: entity))
        for alias in ([candidate.name] + (candidate.aliases ?? [])) where !known.contains(normalizeName(alias)) {
          entity.aliases.append(alias)
        }
        for (key, value) in candidate.details ?? [:] where !value.isEmpty {
          entity.details[key] = value
        }
        entity.occurrences += 1
        entity.lastSeenAt = date
        entities[idx] = entity
      } else {
        entities.append(
          MemoryEntity(
            kind: candidate.kind,
            name: candidate.name,
            aliases: candidate.aliases ?? [],
            details: candidate.details ?? [:],
            firstSeenAt: date,
            lastSeenAt: date
          )
        )
      }
    }

    if entities.count > maxEntities {
      entities.sort { $0.lastSeenAt > $1.lastSeenAt }
      entities = Array(entities.prefix(maxEntities))
    }
    save(entities)
  }

  public func remove(id: UUID) {
    var entities = loadAll()
    entities.removeAll { $0.id == id }
    save(entities)
  }

  public func clear() {
    save([])
  }

  // MARK: - Internal

  private func existingNames(of entity: MemoryEntity) -> [String] {
    ([entity.name] + entity.aliases).map(normalizeName)
  }

  private func normalizeName(_ name: String) -> String {
    name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func save(_ entities: [MemoryEntity]) {
    do {
      let url = try fileURL()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(entities)
      try data.write(to: url, options: [.atomic])
    } catch {
      memoryLogger.error("MemoryStore: save failed: \(error.localizedDescription, privacy: .public)")
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
