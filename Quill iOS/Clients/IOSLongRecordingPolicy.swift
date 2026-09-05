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
    currentHypothesis = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
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

enum IOSLongTextChunker {
  /// Splits at paragraph, sentence, or word boundaries in that order. All
  /// dictated content remains represented; callers can safely format chunks
  /// independently and join their outputs without accepting a model's output
  /// limit as an apparently-successful partial meeting.
  static func chunks(_ text: String, maxCharacters: Int = 4_000) -> [String] {
    guard maxCharacters > 0 else { return [text] }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxCharacters else { return trimmed.isEmpty ? [] : [trimmed] }

    var result: [String] = []
    var remainder = trimmed[...]

    while remainder.count > maxCharacters {
      let limit = remainder.index(remainder.startIndex, offsetBy: maxCharacters)
      let prefix = remainder[remainder.startIndex..<limit]
      let boundary = preferredBoundary(in: prefix) ?? limit
      let chunk = remainder[remainder.startIndex..<boundary]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !chunk.isEmpty { result.append(chunk) }
      remainder = remainder[boundary...].drop(while: { $0.isWhitespace })
    }

    let tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { result.append(tail) }
    return result
  }

  private static func preferredBoundary(in text: Substring) -> String.Index? {
    let minimumUsefulLength = text.index(
      text.startIndex,
      offsetBy: max(1, text.count / 2)
    )
    let candidates = ["\n\n", "\n", ". ", "? ", "! ", " "]
    for separator in candidates {
      if let range = text.range(of: separator, options: .backwards),
         range.upperBound >= minimumUsefulLength {
        return range.upperBound
      }
    }
    return nil
  }
}
