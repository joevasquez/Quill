//
//  IOSRecordingClient.swift
//  Quill (iOS)
//
//  AVAudioEngine-based recording for iOS. Captures mono 16kHz WAV to a temp file.
//  Optionally runs a parallel SFSpeechRecognizer for a real-time partial
//  transcript preview (Apple's on-device model; the authoritative final
//  transcript is still produced by WhisperKit after stop).
//

import AVFoundation
import Combine
import Foundation
import HexCore
import os
import Speech

private final class LockedSpeechRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?

  func replace(with request: SFSpeechAudioBufferRecognitionRequest?) {
    lock.lock()
    self.request = request
    lock.unlock()
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    request?.append(buffer)
    lock.unlock()
  }

  func endAndClear() {
    lock.lock()
    request?.endAudio()
    request = nil
    lock.unlock()
  }
}

@MainActor
final class IOSRecordingClient {
  static let shared = IOSRecordingClient()

  private let logger = HexLog.recording

  private var engine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var converter: AVAudioConverter?
  private var currentURL: URL?
  private var interruptionObserver: NSObjectProtocol?
  private(set) var isManuallyPaused = false

  // Live preview (SFSpeechRecognizer)
  private var speechRecognizer: SFSpeechRecognizer?
  private let speechRequest = LockedSpeechRequest()
  private var speechTask: SFSpeechRecognitionTask?
  private var speechRestartTask: Task<Void, Never>?
  private var speechTaskGeneration = 0
  private var isLivePreviewCapturing = false
  private var liveTranscriptAccumulator = IOSLiveTranscriptAccumulator()

  private let targetSampleRate: Double = 16000
  private let targetFormat: AVAudioFormat = {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16000,
      channels: 1,
      interleaved: false
    )!
  }()

  // Audio meter (for UI level indicator)
  @Published private(set) var averagePower: Float = 0

  // Live partial transcript from SFSpeechRecognizer. Resets on each start.
  @Published private(set) var livePartialTranscript: String = ""

  /// A write/conversion failure is never allowed to masquerade as an active
  /// recording. RecordingViewModel observes this and stops the session while
  /// leaving the recoverable audio file on disk.
  @Published private(set) var fatalCaptureError: String?
  @Published private(set) var isSystemInterrupted = false

  private init() {
    let session = AVAudioSession.sharedInstance()
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: session,
      queue: .main
    ) { notification in
      let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let optionValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      Task { @MainActor in
        IOSRecordingClient.shared.handleAudioSessionInterruption(
          typeValue: typeValue,
          optionValue: optionValue
        )
      }
    }
  }

  func requestPermission() async -> Bool {
    if #available(iOS 17.0, *) {
      return await AVAudioApplication.requestRecordPermission()
    } else {
      return await withCheckedContinuation { continuation in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    }
  }

  /// Requests speech recognition authorization. Safe to call repeatedly.
  /// Returns true if the live preview is available; false falls back silently.
  func requestSpeechPermission() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  func startRecording(livePreviewEnabled: Bool = true) throws -> URL {
    // Configure session
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
    try session.setActive(true)

    // Create output file URL
    let recordingsDirectory = try Self.recordingsDirectory()
    let url = recordingsDirectory
      .appendingPathComponent("quill-recording-\(UUID().uuidString).wav")
    currentURL = url

    // Reset live preview
    livePartialTranscript = ""
    liveTranscriptAccumulator.reset()
    fatalCaptureError = nil
    isManuallyPaused = false
    isSystemInterrupted = false
    isLivePreviewCapturing = livePreviewEnabled

    // Build engine
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode

    // Optionally set up SFSpeechRecognizer for live partial transcripts.
    // Failures here are non-fatal — recording continues without live preview.
    if livePreviewEnabled {
      setupLivePreview()
    }

    let audioFile = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: targetSampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: true,
      ],
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    self.audioFile = audioFile

    // The converter is built lazily from the FIRST real buffer (below), not
    // from a format read here. `inputNode.outputFormat(forBus:)` can hand
    // back a 0 Hz placeholder in the moment right after `setActive(true)`
    // while the audio route is still settling — building the converter (and
    // installing the tap) with that bogus format writes a silent WAV, which
    // surfaces as an intermittent "No speech detected" on the first take.
    self.converter = nil

    // `format: nil` → the tap uses the bus's actual format at capture time,
    // so `buffer.format` is always the true hardware format, 0 Hz race and all.
    inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
      guard let self, buffer.format.sampleRate > 0 else { return }

      // Feed the native-format buffer to SFSpeechRecognizer for live preview.
      // SFSpeech accepts the input node's format directly — no conversion needed.
      self.speechRequest.append(buffer)

      // Build the converter from the first buffer's real format.
      if self.converter == nil
          || self.converter?.inputFormat.sampleRate != buffer.format.sampleRate
          || self.converter?.inputFormat.channelCount != buffer.format.channelCount {
        self.converter = AVAudioConverter(from: buffer.format, to: self.targetFormat)
      }
      guard let converter = self.converter else { return }

      // Convert to 16kHz mono for the recorded WAV (what Whisper will transcribe)
      let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * (self.targetSampleRate / buffer.format.sampleRate))
      guard let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: self.targetFormat,
        frameCapacity: max(frameCapacity, 1)
      ) else { return }

      var error: NSError?
      var done = false
      converter.convert(to: outputBuffer, error: &error) { _, status in
        if done {
          status.pointee = .noDataNow
          return nil
        }
        done = true
        status.pointee = .haveData
        return buffer
      }

      if let error {
        Task { @MainActor in
          self.reportFatalCaptureError("Audio conversion failed: \(error.localizedDescription)")
        }
      } else {
        do {
          try self.audioFile?.write(from: outputBuffer)
        } catch {
          Task { @MainActor in
            self.reportFatalCaptureError("Audio could not be saved: \(error.localizedDescription)")
          }
          return
        }
        // Compute meter
        if let data = outputBuffer.floatChannelData?[0] {
          let frameLen = Int(outputBuffer.frameLength)
          var sum: Float = 0
          for i in 0..<frameLen { sum += abs(data[i]) }
          let avg = frameLen > 0 ? sum / Float(frameLen) : 0
          Task { @MainActor in self.averagePower = min(1, avg * 3) }
        }
      }
    }

    engine.prepare()
    try engine.start()
    self.engine = engine
    return url
  }

  /// Suspend capture without tearing anything down. `AVAudioEngine.pause()`
  /// stops the render loop, so the input tap stops firing — no buffers are
  /// written and the live recognizer simply goes quiet — while the file,
  /// converter, and recognition request stay open for `resume()`.
  func pause() {
    isManuallyPaused = true
    engine?.pause()
    averagePower = 0
  }

  /// Resume after `pause()`. Returns false if the engine couldn't restart
  /// (the caller then treats it as a hard stop).
  @discardableResult
  func resume() -> Bool {
    guard let engine, !isSystemInterrupted else { return false }
    do {
      try engine.start()
      isManuallyPaused = false
      return true
    } catch {
      return false
    }
  }

  /// AVAudioEngine can be stopped by an audio-route reconfiguration without
  /// ending Quill's UI session. The recording timer calls this once a second
  /// so a route glitch becomes a short gap, not 27 minutes of false capture.
  @discardableResult
  func recoverIfNeeded() -> Bool {
    guard let engine else { return false }
    guard !isManuallyPaused, !isSystemInterrupted else { return true }
    guard !engine.isRunning else { return true }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setActive(true)
      converter = nil // the new route may have a different hardware format
      engine.prepare()
      try engine.start()
      logger.notice("Recovered audio engine after an unexpected stop")
      return true
    } catch {
      reportFatalCaptureError("The microphone disconnected: \(error.localizedDescription)")
      return false
    }
  }

  func stopRecording() -> URL? {
    isLivePreviewCapturing = false
    isManuallyPaused = false
    isSystemInterrupted = false
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    audioFile = nil
    converter = nil
    averagePower = 0

    // Tear down live preview
    speechRestartTask?.cancel()
    speechRestartTask = nil
    speechTaskGeneration += 1
    speechRequest.endAndClear()
    speechTask?.cancel()
    speechTask = nil
    speechRecognizer = nil

    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    let url = currentURL
    currentURL = nil
    return url
  }

  func recordedDuration(at url: URL) -> TimeInterval? {
    guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
      return nil
    }
    return Double(file.length) / file.fileFormat.sampleRate
  }

  private static func recordingsDirectory() throws -> URL {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = applicationSupport.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableDirectory = directory
    try? mutableDirectory.setResourceValues(values)
    return directory
  }

  private func reportFatalCaptureError(_ message: String) {
    guard fatalCaptureError == nil else { return }
    logger.error("\(message, privacy: .public)")
    fatalCaptureError = message
  }

  private func handleAudioSessionInterruption(typeValue: UInt?, optionValue: UInt) {
    guard engine != nil,
          let typeValue,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

    switch type {
    case .began:
      isSystemInterrupted = true
      engine?.pause()
      averagePower = 0
      logger.notice("Audio capture paused for a system interruption")

    case .ended:
      let options = AVAudioSession.InterruptionOptions(rawValue: optionValue)
      guard options.contains(.shouldResume) else {
        reportFatalCaptureError("iOS did not allow microphone capture to resume after an interruption.")
        return
      }

      isSystemInterrupted = false
      if isManuallyPaused {
        logger.notice("System interruption ended; recording remains manually paused")
      } else if recoverIfNeeded() {
        logger.notice("Audio capture resumed after a system interruption")
      }

    @unknown default:
      reportFatalCaptureError("An unknown iOS audio interruption stopped the microphone.")
    }
  }

  // MARK: - Live preview (SFSpeechRecognizer)

  private func setupLivePreview() {
    // Needs authorization + an available recognizer. If either is missing, we
    // simply leave `livePartialTranscript` empty and the UI will skip it.
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }

    let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    guard let recognizer, recognizer.isAvailable else { return }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // Prefer on-device when supported — keeps the preview private and offline.
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }

    speechTaskGeneration += 1
    let generation = speechTaskGeneration
    speechRecognizer = recognizer
    speechRequest.replace(with: request)
    self.speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      Task { @MainActor in
        guard self.isLivePreviewCapturing,
              generation == self.speechTaskGeneration else { return }
        if let result {
          self.livePartialTranscript = self.liveTranscriptAccumulator.update(
            hypothesis: result.bestTranscription.formattedString
          )
        }
        if error != nil || (result?.isFinal ?? false) {
          self.finishLivePreviewTask(generation: generation)
        }
      }
    }
  }

  /// Apple's live recognizer ends long-running requests on its own. Treat
  /// that as a preview boundary, commit the hypothesis, and start a fresh
  /// request. The WAV recorder never stops and remains authoritative.
  private func finishLivePreviewTask(generation: Int) {
    guard isLivePreviewCapturing, generation == speechTaskGeneration else { return }

    liveTranscriptAccumulator.finishRecognitionTask()
    livePartialTranscript = liveTranscriptAccumulator.combinedText
    speechTaskGeneration += 1
    speechRequest.replace(with: nil)
    speechTask?.cancel()
    speechTask = nil
    speechRecognizer = nil

    speechRestartTask?.cancel()
    speechRestartTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, let self, self.isLivePreviewCapturing else { return }
      self.setupLivePreview()
    }
  }
}
