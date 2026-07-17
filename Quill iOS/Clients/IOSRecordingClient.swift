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
import Speech

@MainActor
final class IOSRecordingClient {
  static let shared = IOSRecordingClient()

  private var engine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var converter: AVAudioConverter?
  private var currentURL: URL?

  // Live preview (SFSpeechRecognizer)
  private var speechRecognizer: SFSpeechRecognizer?
  private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
  private var speechTask: SFSpeechRecognitionTask?

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

  private init() {}

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
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true)

    // Create output file URL
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("quill-recording-\(UUID().uuidString).wav")
    currentURL = url

    // Reset live preview
    livePartialTranscript = ""

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
      Task { @MainActor in self.speechRequest?.append(buffer) }

      // Build the converter from the first buffer's real format.
      if self.converter == nil {
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

      if error == nil {
        try? self.audioFile?.write(from: outputBuffer)
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
    engine?.pause()
    averagePower = 0
  }

  /// Resume after `pause()`. Returns false if the engine couldn't restart
  /// (the caller then treats it as a hard stop).
  @discardableResult
  func resume() -> Bool {
    guard let engine else { return false }
    do {
      try engine.start()
      return true
    } catch {
      return false
    }
  }

  func stopRecording() -> URL? {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    audioFile = nil
    converter = nil
    averagePower = 0

    // Tear down live preview
    speechRequest?.endAudio()
    speechTask?.cancel()
    speechTask = nil
    speechRequest = nil
    speechRecognizer = nil

    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    return currentURL
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

    self.speechRecognizer = recognizer
    self.speechRequest = request
    self.speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let result {
        let text = result.bestTranscription.formattedString
        Task { @MainActor in self.livePartialTranscript = text }
      }
      if error != nil || (result?.isFinal ?? false) {
        Task { @MainActor in
          self.speechTask = nil
          self.speechRequest = nil
        }
      }
    }
  }
}
