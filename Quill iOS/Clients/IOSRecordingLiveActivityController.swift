//
//  IOSRecordingLiveActivityController.swift
//  Quill (iOS)
//
//  Owns the one Live Activity representing the current recording.
//

import ActivityKit
import Foundation
import HexCore
import os

@MainActor
final class IOSRecordingLiveActivityController {
  static let shared = IOSRecordingLiveActivityController()

  private var activity: Activity<QuillRecordingActivityAttributes>?
  private var modeLabel = "Record"

  private init() {
    installControlObservers()
  }

  private func installControlObservers() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    for name in [QuillRecordingControlSignal.togglePause, QuillRecordingControlSignal.stop] {
      CFNotificationCenterAddObserver(
        center,
        observer,
        Self.controlNotificationCallback,
        name as CFString,
        nil,
        .deliverImmediately
      )
    }
  }

  private nonisolated static let controlNotificationCallback: CFNotificationCallback = {
    _, observer, name, _, _ in
    guard let observer, let name else { return }
    let controller = Unmanaged<IOSRecordingLiveActivityController>
      .fromOpaque(observer)
      .takeUnretainedValue()
    let rawName = name.rawValue as String
    Task { @MainActor in
      controller.forwardControlSignal(rawName)
    }
  }

  private func forwardControlSignal(_ name: String) {
    switch name {
    case QuillRecordingControlSignal.togglePause:
      NotificationCenter.default.post(name: .quillToggleRecordingPauseRequested, object: nil)
    case QuillRecordingControlSignal.stop:
      NotificationCenter.default.post(name: .quillStopRecordingRequested, object: nil)
    default:
      break
    }
  }

  func start(modeLabel: String, startedAt: Date) async {
    self.modeLabel = modeLabel
    for existing in Activity<QuillRecordingActivityAttributes>.activities {
      await existing.end(nil, dismissalPolicy: .immediate)
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

    let state = QuillRecordingActivityAttributes.ContentState(
      modeLabel: modeLabel,
      isPaused: false,
      referenceDate: startedAt,
      elapsedSeconds: 0
    )
    do {
      activity = try Activity.request(
        attributes: QuillRecordingActivityAttributes(captureID: UUID()),
        content: ActivityContent(state: state, staleDate: nil),
        pushType: nil
      )
    } catch {
      HexLog.recording.error("Could not start recording Live Activity: \(error.localizedDescription, privacy: .public)")
    }
  }

  func update(isPaused: Bool, elapsed: TimeInterval) async {
    guard let activity else { return }
    let safeElapsed = max(0, elapsed)
    let state = QuillRecordingActivityAttributes.ContentState(
      modeLabel: modeLabel,
      isPaused: isPaused,
      referenceDate: Date().addingTimeInterval(-safeElapsed),
      elapsedSeconds: safeElapsed
    )
    await activity.update(ActivityContent(state: state, staleDate: nil))
  }

  func end(elapsed: TimeInterval) async {
    guard let activity else { return }
    let safeElapsed = max(0, elapsed)
    let state = QuillRecordingActivityAttributes.ContentState(
      modeLabel: modeLabel,
      isPaused: true,
      referenceDate: Date().addingTimeInterval(-safeElapsed),
      elapsedSeconds: safeElapsed
    )
    await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
    self.activity = nil
  }
}
