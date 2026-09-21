import Dependencies
import DependenciesMacros
import FluidAudio
import Foundation
import HexCore

@DependencyClient
struct SpeakerDiarizationClient {
  var diarize: @Sendable (URL) async throws -> [SpeakerTimeRange]
}

extension SpeakerDiarizationClient: DependencyKey {
  static let liveValue: Self = {
    let live = SpeakerDiarizationClientLive()
    return Self(diarize: { try await live.diarize($0) })
  }()

  static let testValue = Self(diarize: { _ in [] })
}

extension DependencyValues {
  var speakerDiarization: SpeakerDiarizationClient {
    get { self[SpeakerDiarizationClient.self] }
    set { self[SpeakerDiarizationClient.self] = newValue }
  }
}

private actor SpeakerDiarizationClientLive {
  private let manager = OfflineDiarizerManager()

  func diarize(_ url: URL) async throws -> [SpeakerTimeRange] {
    HexLog.transcription.notice("Starting speaker diarization for \(url.lastPathComponent, privacy: .private)")
    let result = try await manager.process(url)
    HexLog.transcription.info("Speaker diarization found \(Set(result.segments.map(\.speakerId)).count) speakers")
    return result.segments.map {
      SpeakerTimeRange(
        speakerID: $0.speakerId,
        startTime: TimeInterval($0.startTimeSeconds),
        endTime: TimeInterval($0.endTimeSeconds)
      )
    }
  }
}
