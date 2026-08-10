//
//  AutoModeSampleStore.swift
//  HexCore
//
//  Records what Auto mode decided, and what the user changed it to.
//
//  This exists to answer a question nobody can currently answer: how often is
//  the classifier wrong, and *how* is it wrong? Without that, every proposed
//  improvement (more keywords, a Core ML model, confidence thresholds) is
//  argued from intuition. Every Auto resolution is logged, not just the
//  corrections, so the denominator is real — accuracy needs both.
//
//  A re-route patches the sample it came from, which turns the feature into a
//  labelling tool: `predicted` is what the classifier said, `corrected` is
//  what the user actually wanted. That is exactly the shape a classifier
//  wants for training, should it come to that.
//
//  **Local only, never synced.** Samples quote transcripts verbatim. Mirrors
//  the ActionRunStore rule for the same reason.
//

import Foundation
import os

private let sampleLogger = HexLog.transcription

/// One Auto-mode decision, plus the correction if the user made one.
public struct AutoModeSample: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let timestamp: Date
  /// The transcript as the classifier saw it (post word-remapping).
  public let transcript: String
  public let predicted: TranscriptionMode
  /// Set when the user re-routed. Nil means they accepted the guess — which
  /// is weaker evidence than an explicit confirmation, but it's what we have.
  public var corrected: TranscriptionMode?

  // Features, stored so a wrong call can be explained rather than guessed at.
  public let hasSelection: Bool
  public let editableTarget: EditableTarget
  public let hasIntegrations: Bool
  public let sourceAppBundleID: String?

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    transcript: String,
    predicted: TranscriptionMode,
    corrected: TranscriptionMode? = nil,
    hasSelection: Bool,
    editableTarget: EditableTarget,
    hasIntegrations: Bool,
    sourceAppBundleID: String?
  ) {
    self.id = id
    self.timestamp = timestamp
    self.transcript = transcript
    self.predicted = predicted
    self.corrected = corrected
    self.hasSelection = hasSelection
    self.editableTarget = editableTarget
    self.hasIntegrations = hasIntegrations
    self.sourceAppBundleID = sourceAppBundleID
  }

  /// True when the user re-routed away from the prediction.
  public var wasCorrected: Bool {
    guard let corrected else { return false }
    return corrected != predicted
  }
}

/// Accuracy over a window of samples, for reading at a glance.
public struct AutoModeAccuracy: Equatable, Sendable {
  public let total: Int
  public let corrected: Int
  /// Per-(predicted → corrected) counts, so the *shape* of the error is
  /// visible: "Action misread as Dictate" is a different problem from
  /// "Dictate misread as Edit".
  public let confusions: [String: Int]

  public var accuracy: Double {
    total == 0 ? 1 : Double(total - corrected) / Double(total)
  }
}

public actor AutoModeSampleStore {
  public static let shared = AutoModeSampleStore()

  /// Samples carry raw transcripts, so this is capped tighter than history.
  /// Enough to see a pattern, not a permanent archive of everything said.
  private static let maxSamples = 500

  private var cachedURL: URL?
  private let overrideURL: URL?
  private let fileName = "auto-mode-samples.json"

  public init(fileURL: URL? = nil) {
    self.overrideURL = fileURL
  }

  // MARK: - Public

  /// Newest first.
  public func loadAll() -> [AutoModeSample] {
    guard let url = try? fileURL(),
          FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode([AutoModeSample].self, from: Data(contentsOf: url))
    } catch {
      sampleLogger.error("AutoModeSampleStore: load failed: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  public func record(_ sample: AutoModeSample) {
    var samples = loadAll()
    samples.insert(sample, at: 0)
    if samples.count > Self.maxSamples { samples.removeLast(samples.count - Self.maxSamples) }
    save(samples)
    let predicted = sample.predicted.rawValue
    let target = sample.editableTarget.rawValue
    let selection = sample.hasSelection ? "yes" : "no"
    let app = sample.sourceAppBundleID ?? "nil"
    sampleLogger.info(
      "Auto sample: predicted=\(predicted, privacy: .public) selection=\(selection, privacy: .public) target=\(target, privacy: .public) app=\(app, privacy: .public)"
    )
  }

  /// Attach the user's correction to an earlier prediction. No-op if the
  /// sample has already aged out of the cap.
  public func recordCorrection(id: UUID, corrected: TranscriptionMode) {
    var samples = loadAll()
    guard let idx = samples.firstIndex(where: { $0.id == id }) else { return }
    samples[idx].corrected = corrected
    save(samples)
    let from = samples[idx].predicted.rawValue
    let to = corrected.rawValue
    sampleLogger.info(
      "Auto sample corrected: \(from, privacy: .public) -> \(to, privacy: .public)"
    )
  }

  public func accuracy() -> AutoModeAccuracy {
    let samples = loadAll()
    var confusions: [String: Int] = [:]
    for s in samples where s.wasCorrected {
      confusions["\(s.predicted.rawValue)→\(s.corrected!.rawValue)", default: 0] += 1
    }
    return AutoModeAccuracy(
      total: samples.count,
      corrected: samples.filter(\.wasCorrected).count,
      confusions: confusions
    )
  }

  // MARK: - Internal

  private func save(_ samples: [AutoModeSample]) {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(samples).write(to: try fileURL(), options: [.atomic])
    } catch {
      sampleLogger.error("AutoModeSampleStore: save failed: \(error.localizedDescription, privacy: .public)")
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
