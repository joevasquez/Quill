//
//  IOSLongRecordingPolicy.swift
//  Quill (iOS)
//
//  Pure policy used by the recorder and its regression tests. Long captures
//  are decoded as independent voice-activity chunks, and the recorded file is
//  audited against the user's elapsed capture time before Quill treats a
//  transcript as complete.
//

import Foundation

enum IOSLongRecordingPolicy {
  enum TranscriptionStrategy: Equatable {
    case continuous
    case voiceActivityChunks
  }

  enum CaptureAudit: Equatable {
    case complete
    case truncated
  }

  /// Whisper's native inference window is 30 seconds. Explicit VAD chunking
  /// keeps longer recordings bounded and prevents one failed/early-ending
  /// decoder pass from silently becoming the final meeting transcript.
  static func transcriptionStrategy(for duration: TimeInterval) -> TranscriptionStrategy {
    duration > 30 ? .voiceActivityChunks : .continuous
  }

  /// Audio callbacks and the UI clock will differ slightly at start/stop.
  /// A five-second or five-percent allowance avoids false alarms while still
  /// catching the catastrophic 30-minute-UI / 3-minute-file case.
  static func audit(
    elapsedDuration: TimeInterval,
    capturedDuration: TimeInterval
  ) -> CaptureAudit {
    guard elapsedDuration > 5 else { return .complete }
    let allowedShortfall = max(5, elapsedDuration * 0.05)
    return elapsedDuration - capturedDuration <= allowedShortfall ? .complete : .truncated
  }
}

struct IOSLiveTranscriptAccumulator {
  private(set) var committed = ""
  private(set) var currentHypothesis = ""

  mutating func reset() {
    committed = ""
    currentHypothesis = ""
  }

  @discardableResult
  mutating func update(hypothesis: String) -> String {
    let candidate = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
    let previousCount = currentHypothesis.split(whereSeparator: { $0.isWhitespace }).count
    let candidateCount = candidate.split(whereSeparator: { $0.isWhitespace }).count
    // Live hypotheses can transiently clear or retract a large block. Keep
    // the readable preview until a fuller update arrives or the task rotates.
    // Small corrections still apply; final Whisper output remains authoritative.
    guard !candidate.isEmpty, previousCount - candidateCount <= 12 else { return combinedText }
    currentHypothesis = candidate
    return combinedText
  }

  mutating func finishRecognitionTask() {
    let finished = currentHypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
    if !finished.isEmpty {
      committed = Self.join(committed, finished)
    }
    currentHypothesis = ""
  }

  var combinedText: String {
    Self.join(committed, currentHypothesis)
  }

  private static func join(_ lhs: String, _ rhs: String) -> String {
    [lhs, rhs]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
