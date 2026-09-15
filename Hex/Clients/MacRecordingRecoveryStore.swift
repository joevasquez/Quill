#if os(macOS)
import AVFoundation
import Combine
import Foundation
import HexCore
import os

struct MacRecoveryRecording: Codable, Equatable, Identifiable {
  enum State: String, Codable { case recording, processing, needsRecovery }

  var id: UUID
  var startedAt: Date
  var updatedAt: Date
  var expectedDuration: TimeInterval
  var capturedDuration: TimeInterval
  var liveTranscript: String
  var failureReason: String?
  var state: State
  var audioFileName: String { "\(id.uuidString).wav" }
}

enum MacRecordingRecoveryError: LocalizedError {
  case truncated(expected: TimeInterval, captured: TimeInterval)
  case audioUnavailable

  var errorDescription: String? {
    switch self {
    case let .truncated(expected, captured):
      "The saved audio is shorter than the recording (\(Int(captured))s of \(Int(expected))s). Quill kept it in Recording Recovery."
    case .audioUnavailable:
      "Quill couldn't secure the recording file. Any live words remain in Recording Recovery."
    }
  }
}

@MainActor
final class MacRecordingRecoveryStore: ObservableObject {
  static let shared = MacRecordingRecoveryStore()

  @Published private(set) var recordings: [MacRecoveryRecording] = []
  let directory: URL
  private let indexURL: URL

  init(directory: URL? = nil) {
    let root = directory ?? ((try? URL.hexApplicationSupport) ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("Recording Recovery", isDirectory: true)
    self.directory = root
    self.indexURL = root.appendingPathComponent("recovery.json")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    load()
  }

  func begin(id: UUID, startedAt: Date) {
    guard !recordings.contains(where: { $0.id == id }) else { return }
    recordings.insert(MacRecoveryRecording(
      id: id,
      startedAt: startedAt,
      updatedAt: startedAt,
      expectedDuration: 0,
      capturedDuration: 0,
      liveTranscript: "",
      failureReason: nil,
      state: .recording
    ), at: 0)
    persist()
  }

  func checkpoint(
    id: UUID,
    snapshotURL: URL,
    expectedDuration: TimeInterval,
    liveTranscript: String
  ) {
    defer { try? FileManager.default.removeItem(at: snapshotURL) }
    guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
    do {
      let destination = audioURL(for: id)
      try replaceFile(at: destination, with: snapshotURL)
      recordings[index].expectedDuration = max(0, expectedDuration)
      recordings[index].capturedDuration = Self.duration(of: destination)
      recordings[index].liveTranscript = liveTranscript
      recordings[index].updatedAt = Date()
      persist()
    } catch {
      HexLog.recording.error("Recovery checkpoint failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func recordCheckpoint(id: UUID, expectedDuration: TimeInterval, liveTranscript: String) {
    guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
    let destination = audioURL(for: id)
    recordings[index].expectedDuration = max(0, expectedDuration)
    recordings[index].capturedDuration = Self.duration(of: destination)
    recordings[index].liveTranscript = liveTranscript
    recordings[index].updatedAt = Date()
    persist()
  }

  func secureFinalAudio(
    id: UUID,
    sourceURL: URL,
    expectedDuration: TimeInterval,
    liveTranscript: String
  ) throws -> URL {
    guard let index = recordings.firstIndex(where: { $0.id == id }) else {
      throw MacRecordingRecoveryError.audioUnavailable
    }
    let destination = audioURL(for: id)
    try replaceFile(at: destination, with: sourceURL)
    try? FileManager.default.removeItem(at: sourceURL)

    let captured = Self.duration(of: destination)
    recordings[index].expectedDuration = expectedDuration
    recordings[index].capturedDuration = captured
    recordings[index].liveTranscript = liveTranscript
    recordings[index].state = .processing
    recordings[index].updatedAt = Date()
    persist()

    guard RecordingCaptureAudit.evaluate(elapsed: expectedDuration, captured: captured) == .complete else {
      markNeedsRecovery(id: id, reason: MacRecordingRecoveryError.truncated(expected: expectedDuration, captured: captured).localizedDescription)
      throw MacRecordingRecoveryError.truncated(expected: expectedDuration, captured: captured)
    }
    return destination
  }

  func markNeedsRecovery(id: UUID, reason: String?) {
    guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
    recordings[index].state = .needsRecovery
    recordings[index].failureReason = reason
    recordings[index].updatedAt = Date()
    persist()
  }

  func markNeedsRecovery(audioURL: URL?, reason: String?) {
    guard let audioURL,
          let id = UUID(uuidString: audioURL.deletingPathExtension().lastPathComponent)
    else { return }
    markNeedsRecovery(id: id, reason: reason)
  }

  func complete(audioURL: URL?, deleteAudio: Bool) {
    guard let audioURL,
          let id = UUID(uuidString: audioURL.deletingPathExtension().lastPathComponent)
    else { return }
    complete(id: id, deleteAudio: deleteAudio)
  }

  func complete(id: UUID, deleteAudio: Bool) {
    recordings.removeAll { $0.id == id }
    if deleteAudio { try? FileManager.default.removeItem(at: audioURL(for: id)) }
    persist()
  }

  func discard(id: UUID) { complete(id: id, deleteAudio: true) }
  func audioURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).wav") }

  private func load() {
    guard let data = try? Data(contentsOf: indexURL),
          var decoded = try? JSONDecoder.recovery.decode([MacRecoveryRecording].self, from: data)
    else { return }
    for index in decoded.indices where decoded[index].state != .needsRecovery {
      decoded[index].state = .needsRecovery
      decoded[index].failureReason = decoded[index].failureReason
        ?? "Quill closed before this recording finished processing."
    }
    decoded.removeAll {
      !FileManager.default.fileExists(atPath: audioURL(for: $0.id).path)
        && $0.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    recordings = decoded.sorted { $0.startedAt > $1.startedAt }
    persist()
  }

  private func persist() {
    do {
      try JSONEncoder.recovery.encode(recordings).write(to: indexURL, options: .atomic)
    } catch {
      HexLog.recording.error("Could not persist Mac recording recovery catalog: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func replaceFile(at destination: URL, with source: URL) throws {
    let fm = FileManager.default
    let staged = directory.appendingPathComponent("\(UUID().uuidString).staged")
    try? fm.removeItem(at: staged)
    try fm.copyItem(at: source, to: staged)
    if fm.fileExists(atPath: destination.path) {
      _ = try fm.replaceItemAt(destination, withItemAt: staged)
    } else {
      try fm.moveItem(at: staged, to: destination)
    }
  }

  private static func duration(of url: URL) -> TimeInterval {
    guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
    return Double(file.length) / file.fileFormat.sampleRate
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
#endif
