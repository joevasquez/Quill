//
//  RecordingRecoveryStore.swift
//  Quill (iOS)
//
//  A durable catalog beside the recording files. Any entry left in a live
//  state at launch becomes recoverable instead of disappearing silently.
//

import Combine
import Foundation
import HexCore
import os

struct RecoveryRecording: Codable, Equatable, Identifiable {
  enum State: String, Codable {
    case recording
    case processing
    case needsRecovery
  }

  var id: UUID
  var audioFileName: String
  var noteID: UUID?
  var startedAt: Date
  var updatedAt: Date
  var expectedDuration: TimeInterval
  var capturedDuration: TimeInterval
  var liveTranscript: String
  var failureReason: String?
  var state: State

  func audioURL(in directory: URL) -> URL {
    directory.appendingPathComponent(audioFileName)
  }
}

@MainActor
final class RecordingRecoveryStore: ObservableObject {
  static let shared = RecordingRecoveryStore()

  @Published private(set) var recordings: [RecoveryRecording] = []

  let directory: URL
  private let indexURL: URL

  init(directory: URL? = nil) {
    let resolved: URL
    if let directory {
      resolved = directory
    } else {
      let support = (try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )) ?? FileManager.default.temporaryDirectory
      resolved = support.appendingPathComponent("Recordings", isDirectory: true)
    }
    self.directory = resolved
    self.indexURL = resolved.appendingPathComponent("recovery.json")
    try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
    load()
  }

  @discardableResult
  func begin(audioURL: URL, startedAt: Date = Date()) -> UUID {
    let entry = RecoveryRecording(
      id: UUID(),
      audioFileName: audioURL.lastPathComponent,
      noteID: nil,
      startedAt: startedAt,
      updatedAt: startedAt,
      expectedDuration: 0,
      capturedDuration: 0,
      liveTranscript: "",
      failureReason: nil,
      state: .recording
    )
    recordings.insert(entry, at: 0)
    persist()
    return entry.id
  }

  func checkpoint(
    id: UUID,
    noteID: UUID? = nil,
    expectedDuration: TimeInterval,
    capturedDuration: TimeInterval,
    liveTranscript: String
  ) {
    guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
    if let noteID { recordings[index].noteID = noteID }
    recordings[index].expectedDuration = max(0, expectedDuration)
    recordings[index].capturedDuration = max(0, capturedDuration)
    recordings[index].liveTranscript = liveTranscript
    recordings[index].updatedAt = Date()
    persist()
  }

  func associate(id: UUID, noteID: UUID) {
    guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
    recordings[index].noteID = noteID
    recordings[index].updatedAt = Date()
    persist()
  }

  func markProcessing(id: UUID) {
    guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
    recordings[index].state = .processing
    recordings[index].failureReason = nil
    recordings[index].updatedAt = Date()
    persist()
  }

  func markNeedsRecovery(id: UUID, reason: String?) {
    guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
    recordings[index].state = .needsRecovery
    recordings[index].failureReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
    recordings[index].updatedAt = Date()
    persist()
  }

  func complete(id: UUID, deleteAudio: Bool) {
    guard let entry = recordings.first(where: { $0.id == id }) else { return }
    recordings.removeAll { $0.id == id }
    if deleteAudio {
      try? FileManager.default.removeItem(at: entry.audioURL(in: directory))
    }
    persist()
  }

  func discard(id: UUID) {
    complete(id: id, deleteAudio: true)
  }

  private func load() {
    guard let data = try? Data(contentsOf: indexURL),
          var decoded = try? JSONDecoder.recovery.decode([RecoveryRecording].self, from: data)
    else { return }

    var changed = false
    for index in decoded.indices where decoded[index].state != .needsRecovery {
      decoded[index].state = .needsRecovery
      if decoded[index].failureReason == nil {
        decoded[index].failureReason = "Quill closed before this recording finished processing."
      }
      changed = true
    }
    let countBeforePruning = decoded.count
    decoded.removeAll { entry in
      let missingAudio = !FileManager.default.fileExists(atPath: entry.audioURL(in: directory).path)
      return missingAudio && entry.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    changed = changed || decoded.count != countBeforePruning
    recordings = decoded.sorted { $0.startedAt > $1.startedAt }
    if changed { persist() }
  }

  private func persist() {
    do {
      let data = try JSONEncoder.recovery.encode(recordings)
      try data.write(to: indexURL, options: [.atomic])
    } catch {
      HexLog.recording.error("Could not persist recording recovery catalog: \(error.localizedDescription, privacy: .public)")
    }
  }
}

private extension JSONEncoder {
  static let recovery: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()
}

private extension JSONDecoder {
  static let recovery: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
