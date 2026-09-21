import FluidAudio
import Foundation
import HexCore
import os

/// Runs FluidAudio's offline diarizer after an iOS recording finishes.
/// The full recording is required, so live partial text remains unlabeled;
/// the authoritative transcript gains speaker turns during finalization.
actor IOSSpeakerDiarizationClient {
  static let shared = IOSSpeakerDiarizationClient()

  private let manager = OfflineDiarizerManager()

  func diarize(_ url: URL) async throws -> [SpeakerTimeRange] {
    HexLog.transcription.notice("Starting iOS speaker diarization")
    let result = try await manager.process(url)
    let count = Set(result.segments.map(\.speakerId)).count
    HexLog.transcription.info("iOS speaker diarization found \(count, privacy: .public) speakers")
    return result.segments.map {
      SpeakerTimeRange(
        speakerID: $0.speakerId,
        startTime: TimeInterval($0.startTimeSeconds),
        endTime: TimeInterval($0.endTimeSeconds)
      )
    }
  }
}
