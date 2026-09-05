//
//  QuillRecordingActivity.swift
//  HexCore
//
//  Shared Live Activity state and controls used by the iOS app and widget.
//

#if os(iOS) && canImport(ActivityKit) && canImport(AppIntents)
import ActivityKit
import AppIntents
import Foundation

public struct QuillRecordingActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public var modeLabel: String
    public var isPaused: Bool
    public var referenceDate: Date
    public var elapsedSeconds: TimeInterval

    public init(modeLabel: String, isPaused: Bool, referenceDate: Date, elapsedSeconds: TimeInterval) {
      self.modeLabel = modeLabel
      self.isPaused = isPaused
      self.referenceDate = referenceDate
      self.elapsedSeconds = elapsedSeconds
    }
  }

  public var captureID: UUID

  public init(captureID: UUID) {
    self.captureID = captureID
  }
}

public extension Notification.Name {
  static let quillToggleRecordingPauseRequested = Notification.Name("quill.toggleRecordingPauseRequested")
  static let quillStopRecordingRequested = Notification.Name("quill.stopRecordingRequested")
}

/// Cross-process signals used by Live Activity buttons. App intents may run
/// in the widget extension, so a process-local NotificationCenter post cannot
/// reach the recording app. Darwin notifications carry these stateless button
/// presses across that boundary without persisting any recording content.
public enum QuillRecordingControlSignal {
  public static let togglePause = "com.joevasquez.Quill.recording.togglePause"
  public static let stop = "com.joevasquez.Quill.recording.stop"

  public static func post(_ name: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(name as CFString),
      nil,
      nil,
      true
    )
  }
}

public struct QuillToggleRecordingPauseIntent: LiveActivityIntent {
  public static let title: LocalizedStringResource = "Pause or Resume Recording"
  public static let description = IntentDescription("Pauses or resumes the current Quill recording.")
  public static let openAppWhenRun = false

  public init() {}

  @MainActor
  public func perform() async throws -> some IntentResult {
    QuillRecordingControlSignal.post(QuillRecordingControlSignal.togglePause)
    return .result()
  }
}

public struct QuillStopRecordingIntent: LiveActivityIntent {
  public static let title: LocalizedStringResource = "Stop Recording"
  public static let description = IntentDescription("Stops and saves the current Quill recording.")
  public static let openAppWhenRun = false

  public init() {}

  @MainActor
  public func perform() async throws -> some IntentResult {
    QuillRecordingControlSignal.post(QuillRecordingControlSignal.stop)
    return .result()
  }
}
#endif
