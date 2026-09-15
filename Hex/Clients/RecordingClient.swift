//
//  RecordingClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AppKit // For NSEvent media key simulation
import AVFoundation
import ComposableArchitecture
import CoreAudio
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let recordingLogger = HexLog.recording
private let mediaLogger = HexLog.media
private typealias CoreAudioPropertyListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Equatable {
  var id: String
  var name: String
}

@DependencyClient
struct RecordingClient {
  var startRecording: @Sendable () async -> Void = {}
  var stopRecording: @Sendable () async -> URL = { URL(fileURLWithPath: "") }
  var requestMicrophoneAccess: @Sendable () async -> Bool = { false }
  var observeAudioLevel: @Sendable () async -> AsyncStream<Meter> = { AsyncStream { _ in } }
  var getAvailableInputDevices: @Sendable () async -> [AudioInputDevice] = { [] }
  var getDefaultInputDeviceName: @Sendable () async -> String? = { nil }
  var warmUpRecorder: @Sendable () async -> Void = {}
  var cleanup: @Sendable () async -> Void = {}
  var snapshotCurrentRecording: @Sendable () async -> URL? = { nil }
  var checkpointCurrentRecording: @Sendable (URL) async -> Bool = { _ in false }
}

extension RecordingClient: DependencyKey {
  static var liveValue: Self {
    let live = RecordingClientLive()
    Task {
      await live.startObservingSystemChanges()
    }
    return Self(
      startRecording: { await live.startRecording() },
      stopRecording: { await live.stopRecording() },
      requestMicrophoneAccess: { await live.requestMicrophoneAccess() },
      observeAudioLevel: { await live.observeAudioLevel() },
      getAvailableInputDevices: { await live.getAvailableInputDevices() },
      getDefaultInputDeviceName: { await live.getDefaultInputDeviceName() },
      warmUpRecorder: { await live.warmUpRecorder() },
      cleanup: { await live.cleanup() },
      snapshotCurrentRecording: { await live.snapshotCurrentRecording() },
      checkpointCurrentRecording: { await live.checkpointCurrentRecording(to: $0) }
    )
  }
}

/// Simple structure representing audio metering values.
struct Meter: Equatable {
  let averagePower: Double
  let peakPower: Double
}

// Define function pointer types for the MediaRemote functions.
typealias MRNowPlayingIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
typealias MRMediaRemoteSendCommandFunc = @convention(c) (Int32, CFDictionary?) -> Void

enum MediaRemoteCommand: Int32 {
  case play = 0
  case pause = 1
  case togglePlayPause = 2
}

/// Wraps a few MediaRemote functions.
@Observable
class MediaRemoteController {
  private var mediaRemoteHandle: UnsafeMutableRawPointer?
  private var mrNowPlayingIsPlaying: MRNowPlayingIsPlayingFunc?
  private var mrSendCommand: MRMediaRemoteSendCommandFunc?

  init?() {
    // Open the private framework.
    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) as UnsafeMutableRawPointer? else {
      mediaLogger.error("Unable to open MediaRemote framework")
      return nil
    }
    mediaRemoteHandle = handle

    // Get pointer for the "is playing" function.
    guard let playingPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
      mediaLogger.error("Unable to find MRMediaRemoteGetNowPlayingApplicationIsPlaying symbol")
      return nil
    }
    mrNowPlayingIsPlaying = unsafeBitCast(playingPtr, to: MRNowPlayingIsPlayingFunc.self)

    if let commandPtr = dlsym(handle, "MRMediaRemoteSendCommand") {
      mrSendCommand = unsafeBitCast(commandPtr, to: MRMediaRemoteSendCommandFunc.self)
    } else {
      mediaLogger.error("Unable to find MRMediaRemoteSendCommand symbol")
    }
  }

  deinit {
    if let handle = mediaRemoteHandle {
      dlclose(handle)
    }
  }

  /// Asynchronously refreshes the "is playing" status.
  func isMediaPlaying() async -> Bool {
    guard let isPlayingFunc = mrNowPlayingIsPlaying else { return false }
    return await withCheckedContinuation { continuation in
      isPlayingFunc(DispatchQueue.main) { isPlaying in
        continuation.resume(returning: isPlaying)
      }
    }
  }

  func send(_ command: MediaRemoteCommand) -> Bool {
    guard let sendCommand = mrSendCommand else {
      return false
    }
    sendCommand(command.rawValue, nil)
    return true
  }
}

// Global instance of MediaRemoteController
private let mediaRemoteController = MediaRemoteController()

func isAudioPlayingOnDefaultOutput() async -> Bool {
  // Refresh the state before checking
  return await mediaRemoteController?.isMediaPlaying() ?? false
}

/// Check if an application is installed by looking for its bundle
private func isAppInstalled(bundleID: String) -> Bool {
  let workspace = NSWorkspace.shared
  return workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
}

/// Cached list of installed media players (computed once at first access)
private let installedMediaPlayers: [String: String] = {
  var result: [String: String] = [:]

  if isAppInstalled(bundleID: "com.apple.Music") {
    result["Music"] = "com.apple.Music"
  }

  if isAppInstalled(bundleID: "com.apple.iTunes") {
    result["iTunes"] = "com.apple.iTunes"
  }

  if isAppInstalled(bundleID: "com.spotify.client") {
    result["Spotify"] = "com.spotify.client"
  }

  if isAppInstalled(bundleID: "org.videolan.vlc") {
    result["VLC"] = "org.videolan.vlc"
  }

  return result
}()

// Backoff to avoid spamming AppleScript errors on systems without controllable players
private var mediaControlErrorCount = 0
private var mediaControlDisabled = false

func pauseAllMediaApplications() async -> [String] {
  if mediaControlDisabled { return [] }
  // Use cached list of installed media players
  if installedMediaPlayers.isEmpty {
    return []
  }

  mediaLogger.debug("Installed media players: \(installedMediaPlayers.keys.joined(separator: ", "))")
  
  // Create AppleScript that only targets installed players
  var scriptParts: [String] = ["set pausedPlayers to {}"]

  for (appName, _) in installedMediaPlayers {
    if appName == "VLC" {
      // VLC: check running, then pause if currently playing
      scriptParts.append("""
      try
        if application \"VLC\" is running then
          tell application \"VLC\"
            if playing then
              pause
              set end of pausedPlayers to \"VLC\"
            end if
          end tell
        end if
      end try
      """)
    } else {
      // Music / iTunes / Spotify: check running outside of tell, then query player state
      scriptParts.append("""
      try
        if application \"\(appName)\" is running then
          tell application \"\(appName)\"
            if player state is playing then
              pause
              set end of pausedPlayers to \"\(appName)\"
            end if
          end tell
        end if
      end try
      """)
    }
  }
  
  scriptParts.append("return pausedPlayers")
  let script = scriptParts.joined(separator: "\n\n")
  
  let appleScript = NSAppleScript(source: script)
  var error: NSDictionary?
  guard let resultDescriptor = appleScript?.executeAndReturnError(&error) else {
    if let error = error {
      mediaLogger.error("Failed to pause media apps: \(error)")
      mediaControlErrorCount += 1
      if mediaControlErrorCount >= 3 { mediaControlDisabled = true }
    }
    return []
  }
  
  // Convert AppleScript list to Swift array
  var pausedPlayers: [String] = []
  let count = resultDescriptor.numberOfItems
  
  if count > 0 {
    for i in 1...count {
      if let item = resultDescriptor.atIndex(i)?.stringValue {
        pausedPlayers.append(item)
      }
    }
  }
    
  mediaLogger.notice("Paused media players: \(pausedPlayers.joined(separator: ", "))")
  
  return pausedPlayers
}

func resumeMediaApplications(_ players: [String]) async {
  guard !players.isEmpty else { return }

  // Only attempt to resume players that are installed
  let validPlayers = players.filter { installedMediaPlayers.keys.contains($0) }
  if validPlayers.isEmpty {
    return
  }
  
  // Create specific resume script for each player
  var scriptParts: [String] = []
  
  for player in validPlayers {
    if player == "VLC" {
      scriptParts.append("""
      try
        if application id \"org.videolan.vlc\" is running then
          tell application id \"org.videolan.vlc\" to play
        end if
      end try
      """)
    } else {
      scriptParts.append("""
      try
        if application \"\(player)\" is running then
          tell application \"\(player)\" to play
        end if
      end try
      """)
    }
  }
  
  let script = scriptParts.joined(separator: "\n\n")
  
  let appleScript = NSAppleScript(source: script)
  var error: NSDictionary?
  appleScript?.executeAndReturnError(&error)
  if let error = error {
    mediaLogger.error("Failed to resume media apps: \(error)")
  }
}

/// Simulates a media key press (the Play/Pause key) by posting a system-defined NSEvent.
/// This toggles the state of the active media app.
private func sendMediaKey() {
  let NX_KEYTYPE_PLAY: UInt32 = 16
  func postKeyEvent(down: Bool) {
    let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
    let data1 = Int((NX_KEYTYPE_PLAY << 16) | (down ? 0xA << 8 : 0xB << 8))
    if let event = NSEvent.otherEvent(with: .systemDefined,
                                      location: .zero,
                                      modifierFlags: flags,
                                      timestamp: 0,
                                      windowNumber: 0,
                                      context: nil,
                                      subtype: 8,
                                      data1: data1,
                                      data2: -1)
    {
      event.cgEvent?.post(tap: .cghidEventTap)
    }
  }
  postKeyEvent(down: true)
  postKeyEvent(down: false)
}

// MARK: - RecordingClientLive Implementation

actor RecordingClientLive {
  private struct AudioHardwareObserver {
    let selector: AudioObjectPropertySelector
    let reason: String
    let listener: CoreAudioPropertyListenerBlock
  }

  private enum RecordingBackend: String {
    case captureEngine = "capture-engine"
    case recorderFallback = "recorder-fallback"
  }

  private struct ActiveRecordingSession {
    let startedAt: Date
    let mode: CaptureRecordingMode
    let backend: RecordingBackend
  }

  private var recorder: AVAudioRecorder?
  private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")
  private var isRecorderPrimedForNextSession = false
  private var lastPrimedDeviceID: AudioDeviceID?
  private var recordingSessionID: UUID?
  private var activeRecordingSession: ActiveRecordingSession?
  private var lastRecordingEndedAt: Date?
  private var deferredCaptureRestartReason: String?
  private var environmentChangeDebounceTask: Task<Void, Never>?
  private var mediaControlTask: Task<Void, Never>?
  private let recorderSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
  ]
  private let (meterStream, meterContinuation) = AsyncStream<Meter>.makeStream()
  private var meterTask: Task<Void, Never>?
  private lazy var captureController = SuperFastCaptureController(meterContinuation: meterContinuation)
  private var captureControllerDeviceID: AudioDeviceID?
  private var notificationObservers: [NSObjectProtocol] = []
  private var audioHardwareObservers: [AudioHardwareObserver] = []
  private var isObservingSystemChanges = false

  @Shared(.hexSettings) var hexSettings: HexSettings

  /// Tracks whether media was paused using the media key when recording started.
  private var didPauseMedia: Bool = false

  /// Tracks whether media was toggled via MediaRemote
  private var didPauseViaMediaRemote: Bool = false

  /// Tracks which specific media players were paused
  private var pausedPlayers: [String] = []

  /// Tracks previous system volume when muted for recording
  private var previousVolume: Float?

  // Cache to store already-processed device information
  private var deviceCache: [AudioDeviceID: (hasInput: Bool, name: String?)] = [:]
  private var lastDeviceCheck = Date(timeIntervalSince1970: 0)
  
  /// Gets all available input devices on the system
  func getAvailableInputDevices() async -> [AudioInputDevice] {
    // Reset cache if it's been more than 5 minutes since last full refresh
    let now = Date()
    if now.timeIntervalSince(lastDeviceCheck) > 300 {
      deviceCache.removeAll()
      lastDeviceCheck = now
    }
    
    // Get all available audio devices
    let devices = getAllAudioDevices()
    var inputDevices: [AudioInputDevice] = []
    
    // Filter to only input devices and convert to our model
    for device in devices {
      let hasInput: Bool
      let name: String?
      
      // Check cache first to avoid expensive Core Audio calls
      if let cached = deviceCache[device] {
        hasInput = cached.hasInput
        name = cached.name
      } else {
        hasInput = deviceHasInput(deviceID: device)
        name = hasInput ? getDeviceName(deviceID: device) : nil
        deviceCache[device] = (hasInput, name)
      }
      
      if hasInput, let deviceName = name {
        inputDevices.append(AudioInputDevice(id: String(device), name: deviceName))
      }
    }
    
    return inputDevices
  }

  /// Gets the current system default input device name
  func getDefaultInputDeviceName() async -> String? {
    guard let deviceID = getDefaultInputDevice() else { return nil }
    if let cached = deviceCache[deviceID], cached.hasInput, let name = cached.name {
      return name
    }
    let name = getDeviceName(deviceID: deviceID)
    if let name {
      deviceCache[deviceID] = (hasInput: true, name: name)
    }
    return name
  }
  
  // MARK: - Core Audio Helpers

  /// Creates an AudioObjectPropertyAddress with common defaults.
  private func audioPropertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: element
    )
  }

  func startObservingSystemChanges() {
    guard !isObservingSystemChanges else { return }
    isObservingSystemChanges = true

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    notificationObservers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { [weak self] in
          await self?.enqueueCaptureEnvironmentChange(reason: "system-wake", forceRestart: true)
        }
      }
    )
    notificationObservers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { [weak self] in
          await self?.enqueueCaptureEnvironmentChange(reason: "display-wake", forceRestart: true)
        }
      }
    )

    let center = NotificationCenter.default
    notificationObservers.append(
      center.addObserver(
        forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { [weak self] in
          await self?.enqueueCaptureEnvironmentChange(reason: "capture-device-connected", forceRestart: true)
        }
      }
    )
    notificationObservers.append(
      center.addObserver(
        forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { [weak self] in
          await self?.enqueueCaptureEnvironmentChange(reason: "capture-device-disconnected", forceRestart: true)
        }
      }
    )

    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDefaultInputDevice,
      reason: "default-input-changed"
    )
    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDefaultOutputDevice,
      reason: "default-output-changed"
    )
    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDevices,
      reason: "audio-devices-changed"
    )

    recordingLogger.notice("Installed recording environment observers")
  }

  private func installAudioHardwareObserver(
    selector: AudioObjectPropertySelector,
    reason: String
  ) {
    let listener: CoreAudioPropertyListenerBlock = { [weak self] _, _ in
      Task { [weak self] in
        await self?.enqueueCaptureEnvironmentChange(reason: reason, forceRestart: true)
      }
    }

    var address = audioPropertyAddress(selector)
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      DispatchQueue.main,
      listener
    )

    if status == noErr {
      audioHardwareObservers.append(
        AudioHardwareObserver(selector: selector, reason: reason, listener: listener)
      )
    } else {
      recordingLogger.error("Failed to install audio observer reason=\(reason) status=\(status)")
    }
  }

  private func enqueueCaptureEnvironmentChange(reason: String, forceRestart: Bool) {
    environmentChangeDebounceTask?.cancel()
    environmentChangeDebounceTask = Task { [self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      await handleCaptureEnvironmentChange(reason: reason, forceRestart: forceRestart)
    }
  }

  private func stopObservingSystemChanges() {
    guard isObservingSystemChanges else { return }
    isObservingSystemChanges = false
    environmentChangeDebounceTask?.cancel()
    environmentChangeDebounceTask = nil

    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    notificationObservers.removeAll()

    for observer in audioHardwareObservers {
      var address = audioPropertyAddress(observer.selector)
      let status = AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        DispatchQueue.main,
        observer.listener
      )
      if status != noErr {
        recordingLogger.error("Failed to remove audio observer reason=\(observer.reason) status=\(status)")
      }
    }
    audioHardwareObservers.removeAll()
  }

  private func handleCaptureEnvironmentChange(reason: String, forceRestart: Bool) async {
    let currentInputDevice = getDefaultInputDevice()
    let currentOutputDevice = getDefaultOutputDevice()
    let isRecorderRecording = recorder?.isRecording == true
    let isEngineRecording = captureController.isRecording
    let isRecordingActive = isRecorderRecording || isEngineRecording

    recordingLogger.notice(
      "Capture environment changed reason=\(reason) activeRecording=\(isRecordingActive) input=\(self.describeDevice(currentInputDevice)) output=\(self.describeDevice(currentOutputDevice)) captureEngineArmed=\(self.captureController.isRunning) primed=\(self.isRecorderPrimedForNextSession)"
    )

    if isRecordingActive {
      deferredCaptureRestartReason = reason
      invalidatePrimedState()
      recordingLogger.notice("Deferring capture restart until current recording stops reason=\(reason)")
      return
    }

    deferredCaptureRestartReason = nil
    let activeInputDevice = applyPreferredInputDevice()

    if hexSettings.superFastModeEnabled {
      releaseRecorder(reason: "environment-change-\(reason)")
      do {
        try ensureCaptureControllerReady(
          for: activeInputDevice,
          reason: reason,
          forceRestart: forceRestart
        )
      } catch {
        recordingLogger.error("Failed to restart capture engine after \(reason): \(error.localizedDescription)")
      }
      return
    }

    stopCaptureController(reason: reason)
    let shouldReprimeRecorder = recorder != nil || isRecorderPrimedForNextSession
    releaseRecorder(reason: "environment-change-\(reason)")

    guard shouldReprimeRecorder else {
      recordingLogger.debug("No warm recorder state to rebuild after reason=\(reason)")
      return
    }

    do {
      try primeRecorderForNextSession()
      recordingLogger.notice("Recorder re-primed after reason=\(reason)")
    } catch {
      recordingLogger.error("Failed to re-prime recorder after \(reason): \(error.localizedDescription)")
    }
  }

  private func flushDeferredCaptureRestartIfNeeded() async {
    guard let deferredCaptureRestartReason else { return }
    recordingLogger.notice("Applying deferred capture restart reason=\(deferredCaptureRestartReason)")
    await handleCaptureEnvironmentChange(
      reason: "deferred-\(deferredCaptureRestartReason)",
      forceRestart: true
    )
  }

  /// Get all available audio devices
  private func getAllAudioDevices() -> [AudioDeviceID] {
    var propertySize: UInt32 = 0
    var address = audioPropertyAddress(kAudioHardwarePropertyDevices)
    
    // Get the property data size
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      recordingLogger.error("AudioObjectGetPropertyDataSize failed: \(status)")
      return []
    }
    
    // Calculate device count
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    
    // Get the device IDs
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize,
      &deviceIDs
    )
    
      if status != 0 {
        recordingLogger.error("AudioObjectGetPropertyData failed while listing devices: \(status)")
        return []
      }
    
    return deviceIDs
  }
  
  /// Get device name for the given device ID
  private func getDeviceName(deviceID: AudioDeviceID) -> String? {
    var address = audioPropertyAddress(kAudioDevicePropertyDeviceNameCFString)
    
    var deviceName: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let deviceNamePtr: UnsafeMutableRawPointer = .allocate(byteCount: Int(size), alignment: MemoryLayout<CFString?>.alignment)
    defer { deviceNamePtr.deallocate() }
    
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      deviceNamePtr
    )
    
    if status == 0 {
        deviceName = deviceNamePtr.load(as: CFString?.self)
    }
    
      if status != 0 {
        recordingLogger.error("Failed to fetch device name: \(status)")
        return nil
      }
    
    return deviceName as String?
  }
  
  /// Check if device has input capabilities
  private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
    var address = audioPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
    
    var propertySize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      return false
    }
    
    let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
    defer { bufferList.deallocate() }
    
    let getStatus = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &propertySize,
      bufferList
    )
    
    if getStatus != 0 {
      return false
    }
    
    // Check if we have any input channels
    let buffersPointer = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffersPointer.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
  }
  
  /// Set device as the default input device
  private func setInputDevice(deviceID: AudioDeviceID) {
    var device = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      size,
      &device
    )
    
    if status != 0 {
      recordingLogger.error("Failed to set default input device: \(status)")
    } else {
      recordingLogger.notice("Selected input device set to \(deviceID)")
    }
  }

  func requestMicrophoneAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  // MARK: - Input Device Query

  /// Gets the current default input device ID
  private func getDefaultInputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    if status != 0 {
      recordingLogger.error("Failed to get default input device: \(status)")
      return nil
    }

    return deviceID
  }

  private func resolvePreferredInputDevice() -> AudioDeviceID? {
    if let selectedDeviceIDString = hexSettings.selectedMicrophoneID,
       let selectedDeviceID = AudioDeviceID(selectedDeviceIDString) {
      let devices = getAllAudioDevices()
      if devices.contains(selectedDeviceID), deviceHasInput(deviceID: selectedDeviceID) {
        return selectedDeviceID
      }

      recordingLogger.notice("Selected device \(selectedDeviceID) missing; using system default")
      return nil
    }

    return nil
  }

  private func formatDuration(_ duration: TimeInterval?) -> String {
    guard let duration else { return "n/a" }
    return String(format: "%.3fs", duration)
  }

  private func describeDevice(_ deviceID: AudioDeviceID?) -> String {
    guard let deviceID else { return "none" }
    if let name = getDeviceName(deviceID: deviceID) {
      return "\(name) [\(deviceID)]"
    }
    return "unknown [\(deviceID)]"
  }

  private func logRecordingStartRequest(mode: CaptureRecordingMode, inputDeviceID: AudioDeviceID?) {
    let idleDuration = lastRecordingEndedAt.map { Date().timeIntervalSince($0) }
    let outputDeviceID = getDefaultOutputDevice()
    recordingLogger.notice(
      "Recording requested mode=\(mode.rawValue) idle=\(self.formatDuration(idleDuration)) input=\(self.describeDevice(inputDeviceID)) output=\(self.describeDevice(outputDeviceID)) fallbackPrimed=\(self.isRecorderPrimedForNextSession)"
    )
  }

  private func currentCaptureMode() -> CaptureRecordingMode {
    hexSettings.superFastModeEnabled ? .superFast : .standard
  }

  @discardableResult
  private func applyPreferredInputDevice() -> AudioDeviceID? {
    let targetDeviceID = resolvePreferredInputDevice()
    let currentDefaultDevice = getDefaultInputDevice()

    if let primedDevice = lastPrimedDeviceID, primedDevice != currentDefaultDevice {
      recordingLogger.notice("Default input changed from \(primedDevice) to \(currentDefaultDevice ?? 0); invalidating primed state")
      invalidatePrimedState()
    }

    if let targetDeviceID {
      if targetDeviceID != currentDefaultDevice {
        recordingLogger.notice("Switching input device from \(currentDefaultDevice ?? 0) to \(targetDeviceID)")
        setInputDevice(deviceID: targetDeviceID)
        invalidatePrimedState()
      } else {
        recordingLogger.debug("Device \(targetDeviceID) already set as default, skipping setInputDevice()")
      }
    } else {
      recordingLogger.debug("Using system default microphone")
    }

    return getDefaultInputDevice()
  }

  private func makeCaptureRecordingURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")
  }

  private func makeIgnoredStopURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hex-ignored-stop-\(UUID().uuidString).wav")
  }

  nonisolated static func shouldIgnoreStopRequest(
    snapshotSessionID: UUID?,
    currentSessionID: UUID?
  ) -> Bool {
    guard let snapshotSessionID else { return false }
    return currentSessionID != snapshotSessionID
  }

  private func ensureCaptureControllerReady(
    for deviceID: AudioDeviceID?,
    reason: String,
    forceRestart: Bool = false
  ) throws {
    if forceRestart || captureControllerDeviceID != deviceID {
      recordingLogger.notice(
        "Restarting capture engine reason=\(reason) previousInput=\(self.describeDevice(self.captureControllerDeviceID)) newInput=\(self.describeDevice(deviceID)) force=\(forceRestart)"
      )
      stopCaptureController(reason: forceRestart ? "restart-\(reason)" : "input-device-changed")
    }

    try captureController.startIfNeeded(
      reason: reason,
      keepWarmBuffer: currentCaptureMode().keepsWarmBuffer
    )
    captureControllerDeviceID = deviceID
  }

  private func stopCaptureController(reason: String) {
    captureController.stop(reason: reason)
    captureControllerDeviceID = nil
  }

  private func releaseRecorder(reason: String) {
    if recorder != nil {
      recordingLogger.notice(
        "Releasing recorder reason=\(reason) primed=\(self.isRecorderPrimedForNextSession) input=\(self.describeDevice(self.lastPrimedDeviceID))"
      )
    }
    stopMeterTask()
    if recorder?.isRecording == true {
      recorder?.stop()
    }
    recorder = nil
    invalidatePrimedState()
  }

  // MARK: - Input Device Mute Detection & Fix

  /// Checks if the input device is muted at the Core Audio device level
  private func isInputDeviceMuted(_ deviceID: AudioDeviceID) -> Bool {
    var address = audioPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)

    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
    if status != noErr {
      // Property not supported on this device
      return false
    }
    return muted == 1
  }

  /// Unmutes the input device at the Core Audio device level
  private func unmuteInputDevice(_ deviceID: AudioDeviceID) {
    var address = audioPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    var muted: UInt32 = 0
    let size = UInt32(MemoryLayout<UInt32>.size)

    let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muted)
    if status == noErr {
      recordingLogger.warning("Input device \(deviceID) was muted at device level - automatically unmuted")
    } else {
      recordingLogger.error("Failed to unmute input device \(deviceID): \(status)")
    }
  }

  /// Checks and fixes muted input device before recording
  private func ensureInputDeviceUnmuted() {
    // Check the selected device if specified, otherwise the default
    var deviceIDsToCheck: [AudioDeviceID] = []

    if let selectedIDString = hexSettings.selectedMicrophoneID,
       let selectedID = AudioDeviceID(selectedIDString) {
      deviceIDsToCheck.append(selectedID)
    }

    if let defaultID = getDefaultInputDevice() {
      if !deviceIDsToCheck.contains(defaultID) {
        deviceIDsToCheck.append(defaultID)
      }
    }

    for deviceID in deviceIDsToCheck {
      if isInputDeviceMuted(deviceID) {
        recordingLogger.error("⚠️ Input device \(deviceID) is MUTED at Core Audio level! This causes silent recordings.")
        unmuteInputDevice(deviceID)
      }
    }
  }

  // MARK: - Volume Control

  /// Mutes system volume and returns the previous volume level
  private func muteSystemVolume() async -> Float {
    let currentVolume = getSystemVolume()
    setSystemVolume(0)
    recordingLogger.notice("Muted system volume (was \(String(format: "%.2f", currentVolume)))")
    return currentVolume
  }

  /// Restores system volume to the specified level
  private func restoreSystemVolume(_ volume: Float) async {
    setSystemVolume(volume)
    recordingLogger.notice("Restored system volume to \(String(format: "%.2f", volume))")
  }

  /// Gets the default output device ID
  private func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    if status != 0 {
      recordingLogger.error("Failed to get default output device: \(status)")
      return nil
    }

    return deviceID
  }

  /// Gets the current system output volume (0.0 to 1.0)
  private func getSystemVolume() -> Float {
    guard let deviceID = getDefaultOutputDevice() else {
      return 0.0
    }

    var volume: Float32 = 0.0
    var size = UInt32(MemoryLayout<Float32>.size)
    var address = audioPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)

    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &volume
    )

    if status != 0 {
      recordingLogger.error("Failed to get system volume: \(status)")
      return 0.0
    }

    return volume
  }

  /// Sets the system output volume (0.0 to 1.0)
  private func setSystemVolume(_ volume: Float) {
    guard let deviceID = getDefaultOutputDevice() else {
      return
    }

    var newVolume = volume
    let size = UInt32(MemoryLayout<Float32>.size)
    var address = audioPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)

    let status = AudioObjectSetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      size,
      &newVolume
    )

    if status != 0 {
      recordingLogger.error("Failed to set system volume: \(status)")
    }
  }

  func startRecording() async {
    // Check and fix device-level mute before recording
    ensureInputDeviceUnmuted()

    let sessionID = UUID()
    recordingSessionID = sessionID
    mediaControlTask?.cancel()
    mediaControlTask = nil

    // Handle audio behavior based on user preference
    switch hexSettings.recordingAudioBehavior {
    case .pauseMedia:
      // Pause media in background - don't block recording from starting
      mediaControlTask = Task { [sessionID] in
        guard await self.isCurrentSession(sessionID) else { return }
        if await self.pauseUsingMediaRemoteIfPossible(sessionID: sessionID) {
          return
        }

        // First, pause all media applications using their AppleScript interface.
        let paused = await pauseAllMediaApplications()
        await self.updatePausedPlayers(paused, sessionID: sessionID)

        // If no specific players were paused, pause generic media using the media key.
        guard await self.isCurrentSession(sessionID) else { return }
        if paused.isEmpty {
          if await isAudioPlayingOnDefaultOutput() {
            mediaLogger.notice("Detected active audio on default output; sending media pause")
            await MainActor.run {
              sendMediaKey()
            }
            await self.setDidPauseMedia(true, sessionID: sessionID)
            mediaLogger.notice("Paused media via media key fallback")
          }
        } else {
          mediaLogger.notice("Paused media players: \(paused.joined(separator: ", "))")
        }
      }

    case .mute:
      // Mute system volume in background
      mediaControlTask = Task { [sessionID] in
        guard await self.isCurrentSession(sessionID) else { return }
        let volume = await self.muteSystemVolume()
        await self.setPreviousVolume(volume, sessionID: sessionID)
      }

    case .doNothing:
      // No audio handling
      break
    }

    let activeInputDevice = applyPreferredInputDevice()
    let mode = currentCaptureMode()
    logRecordingStartRequest(mode: mode, inputDeviceID: activeInputDevice)
    let startRequestAt = Date()

    do {
      try ensureCaptureControllerReady(for: activeInputDevice, reason: "startRecording")
      let recordingURL = makeCaptureRecordingURL()
      try captureController.beginRecording(to: recordingURL, requestedAt: startRequestAt, mode: mode)
      let startedAt = Date()
      activeRecordingSession = ActiveRecordingSession(
        startedAt: startedAt,
        mode: mode,
        backend: .captureEngine
      )
      recordingLogger.notice(
        "Recording started mode=\(mode.rawValue) backend=\(RecordingBackend.captureEngine.rawValue) startup=\(self.formatDuration(startedAt.timeIntervalSince(startRequestAt)))"
      )
      return
    } catch {
      recordingLogger.error("Failed to start capture engine for mode=\(mode.rawValue): \(error.localizedDescription); falling back to AVAudioRecorder")
      stopCaptureController(reason: "capture-engine-start-failed")
    }

    do {
      let recorder = try ensureRecorderReadyForRecording()
      let recordCallStartedAt = Date()
      guard recorder.record() else {
        recordingLogger.error("AVAudioRecorder refused to start recording")
        endRecordingSession()
        return
      }
      let startedAt = Date()
      activeRecordingSession = ActiveRecordingSession(
        startedAt: startedAt,
        mode: mode,
        backend: .recorderFallback
      )
      startMeterTask()
      recordingLogger.notice(
        "Recording started mode=\(mode.rawValue) backend=\(RecordingBackend.recorderFallback.rawValue) recordCall=\(self.formatDuration(Date().timeIntervalSince(recordCallStartedAt))) totalStart=\(self.formatDuration(startedAt.timeIntervalSince(startRequestAt)))"
      )
    } catch {
      recordingLogger.error("Failed to start recording: \(error.localizedDescription)")
      clearActiveRecordingMetadata()
      endRecordingSession()
    }
  }

  func stopRecording() async -> URL {
    let stopSessionID = recordingSessionID
    let activeSession = activeRecordingSession

    if activeSession?.backend == .captureEngine || captureController.isRecording {
      let stopTimingEstimate = captureController.stopTimingEstimate
      recordingLogger.debug(
        "Waiting \(self.formatDuration(stopTimingEstimate.gracePeriod)) before finalizing capture-engine recording callbackInterval=\(self.formatDuration(stopTimingEstimate.callbackInterval)) bufferDuration=\(self.formatDuration(stopTimingEstimate.bufferDuration))"
      )
      try? await Task.sleep(for: .milliseconds(Int((stopTimingEstimate.gracePeriod * 1000).rounded())))

      if Self.shouldIgnoreStopRequest(
        snapshotSessionID: stopSessionID,
        currentSessionID: recordingSessionID
      ) {
        recordingLogger.notice("Ignoring stale stop request after a newer recording session started")
        return makeIgnoredStopURL()
      }
    }

    if let captureURL = captureController.finishRecording(clearBuffer: currentCaptureMode() == .superFast) {
      let stoppedAt = Date()
      let session = activeSession ?? ActiveRecordingSession(
        startedAt: stoppedAt,
        mode: currentCaptureMode(),
        backend: .captureEngine
      )
      let recordingDuration = stoppedAt.timeIntervalSince(session.startedAt)
      stopMeterTask()
      endRecordingSession()
      clearActiveRecordingMetadata()
      lastRecordingEndedAt = stoppedAt
      recordingLogger.notice(
        "Recording stopped mode=\(session.mode.rawValue) backend=\(session.backend.rawValue) duration=\(self.formatDuration(recordingDuration))"
      )

      if !hexSettings.superFastModeEnabled {
        stopCaptureController(reason: "mode-disabled-after-stop")
        releaseRecorder(reason: "capture-engine-stop")
      }

      await flushDeferredCaptureRestartIfNeeded()
      await resumeMediaIfNeeded()
      return captureURL
    }

    let stoppedAt = Date()
    let session = activeSession ?? ActiveRecordingSession(
      startedAt: stoppedAt,
      mode: currentCaptureMode(),
      backend: .recorderFallback
    )
    let recordingDuration = stoppedAt.timeIntervalSince(session.startedAt)
    let wasRecording = recorder?.isRecording == true
    recorder?.stop()
    stopMeterTask()
    endRecordingSession()
    clearActiveRecordingMetadata()
    lastRecordingEndedAt = stoppedAt
    if wasRecording {
      recordingLogger.notice("Recording stopped mode=\(session.mode.rawValue) backend=\(session.backend.rawValue) duration=\(self.formatDuration(recordingDuration))")
    } else {
      recordingLogger.notice("stopRecording() called while recorder was idle")
    }

    var exportedURL = recordingURL
    var didCopyRecording = false
    do {
      exportedURL = try duplicateCurrentRecording()
      didCopyRecording = true
    } catch {
      isRecorderPrimedForNextSession = false
      recordingLogger.error("Failed to copy recording: \(error.localizedDescription)")
    }

    if didCopyRecording {
      do {
        if session.backend == .recorderFallback {
          try primeRecorderForNextSession()
        }
      } catch {
        isRecorderPrimedForNextSession = false
        recordingLogger.error("Failed to prime recorder fallback: \(error.localizedDescription)")
      }
    }

    if !hexSettings.superFastModeEnabled {
      stopCaptureController(reason: "standard-stop")
    }

    await flushDeferredCaptureRestartIfNeeded()
    await resumeMediaIfNeeded()

    return exportedURL
  }

  private func resumeMediaIfNeeded() async {
    // Resume audio in background - don't block stop from completing
    let playersToResume = pausedPlayers
    let shouldResumeMedia = didPauseMedia
    let shouldResumeViaMediaRemote = didPauseViaMediaRemote
    let volumeToRestore = previousVolume

    if !playersToResume.isEmpty || shouldResumeMedia || shouldResumeViaMediaRemote || volumeToRestore != nil {
      Task {
        // Restore volume if it was muted
        if let volume = volumeToRestore {
          await self.restoreSystemVolume(volume)
        }
        // Resume media if we previously paused specific players
        else if !playersToResume.isEmpty {
          mediaLogger.notice("Resuming players: \(playersToResume.joined(separator: ", "))")
          await resumeMediaApplications(playersToResume)
        }
        else if shouldResumeViaMediaRemote {
          if mediaRemoteController?.send(.play) == true {
            mediaLogger.notice("Resuming media via MediaRemote")
          } else {
            mediaLogger.error("Failed to resume via MediaRemote; falling back to media key")
            await MainActor.run {
              sendMediaKey()
            }
          }
        }
        // Resume generic media if we paused it with the media key
        else if shouldResumeMedia {
          await MainActor.run {
            sendMediaKey()
          }
          mediaLogger.notice("Resuming media via media key")
        }

        // Clear the flags
        self.clearMediaState()
      }
    }
  }

  // Actor state update helpers
  private func isCurrentSession(_ sessionID: UUID) -> Bool {
    recordingSessionID == sessionID
  }

  private func endRecordingSession() {
    recordingSessionID = nil
    mediaControlTask?.cancel()
    mediaControlTask = nil
  }

  private func clearActiveRecordingMetadata() {
    activeRecordingSession = nil
  }

  private func invalidatePrimedState() {
    isRecorderPrimedForNextSession = false
    lastPrimedDeviceID = nil
  }

  private func updatePausedPlayers(_ players: [String], sessionID: UUID) {
    guard recordingSessionID == sessionID else { return }
    pausedPlayers = players
  }

  private func setDidPauseMedia(_ value: Bool, sessionID: UUID) {
    guard recordingSessionID == sessionID else { return }
    didPauseMedia = value
  }

  private func setDidPauseViaMediaRemote(_ value: Bool, sessionID: UUID) {
    guard recordingSessionID == sessionID else { return }
    didPauseViaMediaRemote = value
  }

  private func setPreviousVolume(_ volume: Float, sessionID: UUID) {
    guard recordingSessionID == sessionID else { return }
    previousVolume = volume
  }

  private func clearMediaState() {
    pausedPlayers = []
    didPauseMedia = false
    didPauseViaMediaRemote = false
    previousVolume = nil
  }

  @discardableResult
  private func pauseUsingMediaRemoteIfPossible(sessionID: UUID) async -> Bool {
    guard let controller = mediaRemoteController else {
      return false
    }

    let isPlaying = await controller.isMediaPlaying()
    guard isPlaying else {
      return false
    }

    guard controller.send(.pause) else {
      mediaLogger.error("Failed to send MediaRemote pause command")
      return false
    }

    setDidPauseViaMediaRemote(true, sessionID: sessionID)
    mediaLogger.notice("Paused media via MediaRemote")
    return true
  }

  private enum RecorderPreparationError: Error {
    case failedToPrepareRecorder
    case missingRecordingOnDisk
  }

  private func ensureRecorderReadyForRecording() throws -> AVAudioRecorder {
    let recorder = try recorderOrCreate()

    if !isRecorderPrimedForNextSession {
      recordingLogger.notice("Recorder NOT primed, calling prepareToRecord() now")
      guard recorder.prepareToRecord() else {
        throw RecorderPreparationError.failedToPrepareRecorder
      }
    } else {
      recordingLogger.notice("Recorder already primed, skipping prepareToRecord()")
    }

    isRecorderPrimedForNextSession = false
    return recorder
  }

  private func recorderOrCreate() throws -> AVAudioRecorder {
    if let recorder {
      return recorder
    }

    let recorder = try AVAudioRecorder(url: recordingURL, settings: recorderSettings)
    recorder.isMeteringEnabled = true
    self.recorder = recorder
    return recorder
  }

  private func duplicateCurrentRecording() throws -> URL {
    let fm = FileManager.default

    guard fm.fileExists(atPath: recordingURL.path) else {
      throw RecorderPreparationError.missingRecordingOnDisk
    }

    let exportURL = recordingURL
      .deletingLastPathComponent()
      .appendingPathComponent("hex-recording-\(UUID().uuidString).wav")

    if fm.fileExists(atPath: exportURL.path) {
      try fm.removeItem(at: exportURL)
    }

    try fm.copyItem(at: recordingURL, to: exportURL)
    return exportURL
  }

  private func primeRecorderForNextSession() throws {
    let recorder = try recorderOrCreate()
    guard recorder.prepareToRecord() else {
      isRecorderPrimedForNextSession = false
      lastPrimedDeviceID = nil
      throw RecorderPreparationError.failedToPrepareRecorder
    }

    isRecorderPrimedForNextSession = true
    lastPrimedDeviceID = getDefaultInputDevice()
    recordingLogger.debug("Recorder primed for device \(self.lastPrimedDeviceID ?? 0)")
  }

  func startMeterTask() {
    meterTask = Task {
      while !Task.isCancelled, let r = self.recorder, r.isRecording {
        r.updateMeters()
        let averagePower = r.averagePower(forChannel: 0)
        let averageNormalized = pow(10, averagePower / 20.0)
        let peakPower = r.peakPower(forChannel: 0)
        let peakNormalized = pow(10, peakPower / 20.0)
        meterContinuation.yield(Meter(averagePower: Double(averageNormalized), peakPower: Double(peakNormalized)))
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  func stopMeterTask() {
    meterTask?.cancel()
    meterTask = nil
  }

  func observeAudioLevel() -> AsyncStream<Meter> {
    meterStream
  }

  func warmUpRecorder() async {
    let activeInputDevice = applyPreferredInputDevice()

    if hexSettings.superFastModeEnabled {
      releaseRecorder(reason: "warm-up-super-fast")
      do {
        try ensureCaptureControllerReady(for: activeInputDevice, reason: "warmUpRecorder")
      } catch {
        recordingLogger.error("Failed to arm capture engine for super fast mode: \(error.localizedDescription)")
      }
      return
    }

    stopCaptureController(reason: "warm-up-standard")
    releaseRecorder(reason: "warm-up-standard")
    recordingLogger.debug("Standard mode uses on-demand capture engine startup; skipping idle recorder priming")
  }

  /// Release recorder resources. Call on app termination.
  func cleanup() {
    endRecordingSession()
    stopObservingSystemChanges()
    stopCaptureController(reason: "cleanup")
    releaseRecorder(reason: "cleanup")
    recordingLogger.notice("RecordingClient cleaned up")
  }

  /// Copy the in-progress recording to a temporary file for live transcription.
  /// Returns nil if no recording is active.
  func snapshotCurrentRecording() -> URL? {
    guard let session = activeRecordingSession else {
      recordingLogger.debug("snapshotCurrentRecording: no active session")
      return nil
    }

    let sourceURL: URL
    switch session.backend {
    case .captureEngine:
      guard let captureURL = captureController.activeRecordingURL else {
        recordingLogger.debug("snapshotCurrentRecording: capture engine has no active URL")
        return nil
      }
      sourceURL = captureURL
    case .recorderFallback:
      sourceURL = recordingURL
    }

    let snapshotURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("hex-snapshot-\(UUID().uuidString).wav")

    do {
      // Read the bytes rather than copyItem to avoid file lock conflicts
      var data = try Data(contentsOf: sourceURL)
      guard data.count > 44 else {  // WAV header is 44 bytes; skip empty files
        recordingLogger.debug("snapshotCurrentRecording: file too small (\(data.count) bytes)")
        return nil
      }
      // Patch the WAV header — the in-progress file has placeholder size fields.
      // WAV format: bytes 4-7 = file size - 8, bytes 40-43 = data chunk size
      let fileSize = UInt32(data.count - 8)
      let dataSize = UInt32(data.count - 44)
      data.replaceSubrange(4..<8, with: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
      data.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

      try data.write(to: snapshotURL)
      let durationSecs = Double(dataSize) / (16000.0 * 4.0)  // 16kHz, 32-bit float
      recordingLogger.debug("snapshotCurrentRecording: created snapshot (\(data.count) bytes, ~\(String(format: "%.1f", durationSecs))s)")
      return snapshotURL
    } catch {
      recordingLogger.warning("Failed to snapshot recording: \(error.localizedDescription)")
      return nil
    }
  }

  /// Appends only newly captured WAV bytes into a durable recovery file.
  /// The header is committed last, so an interruption leaves the previous
  /// checkpoint playable instead of corrupting it.
  func checkpointCurrentRecording(to destination: URL) -> Bool {
    guard let sourceURL = activeRecordingSourceURL() else {
      recordingLogger.debug("checkpointCurrentRecording: no active recording URL")
      return false
    }

    do {
      let fm = FileManager.default
      try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !fm.fileExists(atPath: destination.path) {
        _ = fm.createFile(atPath: destination.path, contents: nil)
      }

      let source = try FileHandle(forReadingFrom: sourceURL)
      let target = try FileHandle(forUpdating: destination)
      defer {
        try? source.close()
        try? target.close()
      }

      let sourceSize = try source.seekToEnd()
      var targetSize = try target.seekToEnd()
      guard sourceSize > 44 else { return false }
      if targetSize > sourceSize || targetSize < 44 {
        try target.truncate(atOffset: 0)
        targetSize = 0
      }

      if sourceSize > targetSize {
        try source.seek(toOffset: targetSize)
        try target.seek(toOffset: targetSize)
        var remaining = sourceSize - targetSize
        while remaining > 0 {
          let count = Int(min(remaining, 256 * 1024))
          guard let data = try source.read(upToCount: count), !data.isEmpty else { break }
          try target.write(contentsOf: data)
          remaining -= UInt64(data.count)
        }
      }

      let committedSize = try target.seekToEnd()
      guard committedSize > 44 else { return false }
      try target.synchronize()
      try Self.patchWAVHeader(target, fileSize: committedSize)
      try target.synchronize()
      recordingLogger.debug("Incremental recovery checkpoint committed (\(committedSize) bytes)")
      return true
    } catch {
      recordingLogger.warning("Incremental recovery checkpoint failed: \(error.localizedDescription)")
      return false
    }
  }

  private func activeRecordingSourceURL() -> URL? {
    guard let session = activeRecordingSession else { return nil }
    switch session.backend {
    case .captureEngine: return captureController.activeRecordingURL
    case .recorderFallback: return recordingURL
    }
  }

  private static func patchWAVHeader(_ handle: FileHandle, fileSize: UInt64) throws {
    let riffSize = UInt32(clamping: fileSize - 8).littleEndian
    let dataSize = UInt32(clamping: fileSize - 44).littleEndian
    try handle.seek(toOffset: 4)
    try handle.write(contentsOf: withUnsafeBytes(of: riffSize) { Data($0) })
    try handle.seek(toOffset: 40)
    try handle.write(contentsOf: withUnsafeBytes(of: dataSize) { Data($0) })
  }
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}
