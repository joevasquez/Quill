import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let historyLogger = HexLog.history

// MARK: - Date Extensions

extension Date {
	func relativeFormatted() -> String {
		let calendar = Calendar.current
		let now = Date()
		
		if calendar.isDateInToday(self) {
			return "Today"
		} else if calendar.isDateInYesterday(self) {
			return "Yesterday"
		} else if let daysAgo = calendar.dateComponents([.day], from: self, to: now).day, daysAgo < 7 {
			let formatter = DateFormatter()
			formatter.dateFormat = "EEEE" // Day of week
			return formatter.string(from: self)
		} else {
			let formatter = DateFormatter()
			formatter.dateStyle = .medium
			formatter.timeStyle = .none
			return formatter.string(from: self)
		}
	}
}

// MARK: - Models

extension SharedReaderKey
	where Self == FileStorageKey<TranscriptionHistory>.Default
{
	static var transcriptionHistory: Self {
		Self[
			.fileStorage(.transcriptionHistoryURL),
			default: .init()
		]
	}
}

// MARK: - Storage Migration

extension URL {
	static var transcriptionHistoryURL: URL {
		get {
			URL.hexMigratedFileURL(named: "transcription_history.json")
		}
	}
}

class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
	private var player: AVAudioPlayer?
	var onPlaybackFinished: (() -> Void)?

	func play(url: URL) throws -> AVAudioPlayer {
		let player = try AVAudioPlayer(contentsOf: url)
		player.delegate = self
		player.play()
		self.player = player
		return player
	}

	func stop() {
		player?.stop()
		player = nil
	}

	// AVAudioPlayerDelegate method
	func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		self.player = nil
		Task { @MainActor in
			onPlaybackFinished?()
		}
	}
}

// MARK: - History Feature

@Reducer
struct HistoryFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		var playingTranscriptID: UUID?
		var audioPlayer: AVAudioPlayer?
		var audioPlayerController: AudioPlayerController?

		// File transcription
		var isTranscribingFile: Bool = false
		var fileTranscriptionResult: String?
		var fileTranscriptionError: String?
		var speakerDetectionInFlight: Set<UUID> = []
		var speakerDetectionErrors: [UUID: String] = [:]

		mutating func stopAudioPlayback() {
			audioPlayerController?.stop()
			audioPlayer = nil
			audioPlayerController = nil
			playingTranscriptID = nil
		}
	}

	enum Action {
		case playTranscript(UUID)
		case stopPlayback
		case copyToClipboard(String)
		case deleteTranscript(UUID)
		case deleteAllTranscripts
		case confirmDeleteAll
		case playbackFinished
		case navigateToSettings
		case detectSpeakers(UUID)
		case speakerDetectionCompleted(UUID, SpeakerTranscript?)
		case speakerDetectionFailed(UUID, String)
		case renameSpeaker(transcriptID: UUID, speakerID: String, name: String)

		// File transcription
		case transcribeFile(URL)
		case fileTranscriptionCompleted(Transcript, shouldStore: Bool)
		case fileTranscriptionFailed(String)
		case clearFileTranscription
	}

	@Dependency(\.pasteboard) var pasteboard
	@Dependency(\.transcriptPersistence) var transcriptPersistence
	@Dependency(\.transcription) var transcription
	@Dependency(\.speakerDiarization) var speakerDiarization

	private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
		.run { [transcriptPersistence] _ in
			for transcript in transcripts {
				try? await transcriptPersistence.deleteAudio(transcript)
			}
		}
	}

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case let .playTranscript(id):
				if state.playingTranscriptID == id {
					// Stop playback if tapping the same transcript
					state.stopAudioPlayback()
					return .none
				}

				// Stop any existing playback
				state.stopAudioPlayback()

				// Find the transcript and play its audio
				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}

				do {
					let controller = AudioPlayerController()
					let player = try controller.play(url: transcript.audioPath)

					state.audioPlayer = player
					state.audioPlayerController = controller
					state.playingTranscriptID = id

					return .run { send in
						// Using non-throwing continuation since we don't need to throw errors
						await withCheckedContinuation { continuation in
							controller.onPlaybackFinished = {
								continuation.resume()

								// Use Task to switch to MainActor for sending the action
								Task { @MainActor in
									send(.playbackFinished)
								}
							}
						}
					}
				} catch {
					historyLogger.error("Failed to play audio: \(error.localizedDescription)")
					return .none
				}

			case .stopPlayback, .playbackFinished:
				state.stopAudioPlayback()
				return .none

			case let .copyToClipboard(text):
				return .run { [pasteboard] _ in
					await pasteboard.copy(text)
				}

			case let .deleteTranscript(id):
				guard let index = state.transcriptionHistory.history.firstIndex(where: { $0.id == id }) else {
					return .none
				}

				let transcript = state.transcriptionHistory.history[index]

				if state.playingTranscriptID == id {
					state.stopAudioPlayback()
				}

				_ = state.$transcriptionHistory.withLock { history in
					history.history.remove(at: index)
				}

				let deletedID = transcript.id
				return .merge(
					deleteAudioEffect(for: [transcript]),
					.run { _ in
						await MacCloudSync.shared.deleteTranscriptFromCloud(id: deletedID)
					}
				)

			case .deleteAllTranscripts:
				return .send(.confirmDeleteAll)

			case .confirmDeleteAll:
				let transcripts = state.transcriptionHistory.history
				state.stopAudioPlayback()

				state.$transcriptionHistory.withLock { history in
					history.history.removeAll()
				}

				let deletedIDs = transcripts.map(\.id)
				return .merge(
					deleteAudioEffect(for: transcripts),
					.run { _ in
						for id in deletedIDs {
							await MacCloudSync.shared.deleteTranscriptFromCloud(id: id)
						}
					}
				)
				
			case .navigateToSettings:
				// This will be handled by the parent reducer
				return .none

			case let .detectSpeakers(id):
				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }),
				      !state.speakerDetectionInFlight.contains(id)
				else { return .none }
				state.speakerDetectionInFlight.insert(id)
				state.speakerDetectionErrors[id] = nil
				@Shared(.hexSettings) var settings: HexSettings
				let model = settings.selectedModel
				let language = settings.outputLanguage

				return .run { send in
					do {
						let options = DecodingOptions(
							language: language,
							detectLanguage: language == nil,
							chunkingStrategy: .vad
						)
						let timed = try await transcription.transcribeTimestamped(
							transcript.audioPath, model, options
						) { _ in }
						let ranges = try await speakerDiarization.diarize(transcript.audioPath)
						let speakerTranscript = SpeakerTranscriptAssembler.assemble(
							words: timed.words,
							speakerRanges: ranges
						)
						await send(.speakerDetectionCompleted(id, speakerTranscript))
					} catch {
						historyLogger.error("Speaker detection failed: \(error.localizedDescription, privacy: .public)")
						await send(.speakerDetectionFailed(id, error.localizedDescription))
					}
				}

			case let .speakerDetectionCompleted(id, speakerTranscript):
				state.speakerDetectionInFlight.remove(id)
				guard let speakerTranscript else {
					state.speakerDetectionErrors[id] = "Multiple speakers were not detected."
					return .none
				}
				var updatedTranscript: Transcript?
				state.$transcriptionHistory.withLock { history in
					guard let index = history.history.firstIndex(where: { $0.id == id }) else { return }
					history.history[index].speakerTranscript = speakerTranscript
					updatedTranscript = history.history[index]
				}
				guard let updatedTranscript else { return .none }
				return .run { _ in await MacCloudSync.shared.uploadTranscript(updatedTranscript) }

			case let .speakerDetectionFailed(id, error):
				state.speakerDetectionInFlight.remove(id)
				state.speakerDetectionErrors[id] = error
				return .none

			case let .renameSpeaker(transcriptID, speakerID, name):
				var updatedTranscript: Transcript?
				state.$transcriptionHistory.withLock { history in
					guard let index = history.history.firstIndex(where: { $0.id == transcriptID }),
					      history.history[index].speakerTranscript != nil
					else { return }
					history.history[index].speakerTranscript?.renameSpeaker(id: speakerID, to: name)
					updatedTranscript = history.history[index]
				}
				guard let updatedTranscript else { return .none }
				return .run { _ in await MacCloudSync.shared.uploadTranscript(updatedTranscript) }

			// File transcription
			case let .transcribeFile(url):
				state.isTranscribingFile = true
				state.fileTranscriptionResult = nil
				state.fileTranscriptionError = nil
				@Shared(.hexSettings) var hexSettings: HexSettings
				let model = hexSettings.selectedModel
				let language = hexSettings.outputLanguage
				let shouldStore = hexSettings.saveTranscriptionHistory

				return .run { send in
					let accessed = url.startAccessingSecurityScopedResource()
					defer { if accessed { url.stopAccessingSecurityScopedResource() } }
					do {
						let options = DecodingOptions(
							language: language,
							detectLanguage: language == nil,
							chunkingStrategy: .vad
						)
						let timed = try await transcription.transcribeTimestamped(url, model, options) { _ in }
						var conversation: SpeakerTranscript?
						do {
							let ranges = try await speakerDiarization.diarize(url)
							conversation = SpeakerTranscriptAssembler.assemble(
								words: timed.words,
								speakerRanges: ranges
							)
						} catch {
							// Diarization is an enhancement; never discard a successful
							// transcription because speaker detection failed.
							historyLogger.warning("Imported file speaker detection failed: \(error.localizedDescription, privacy: .public)")
						}

						var duration = timed.words.map(\.endTime).max() ?? 0
						if duration <= 0 {
							let asset = AVURLAsset(url: url)
							if let assetDuration = try? await asset.load(.duration), assetDuration.seconds.isFinite {
								duration = assetDuration.seconds
							}
						}
						let storedURL: URL
						if shouldStore {
							let folder = try URL.hexApplicationSupport.appendingPathComponent("Recordings", isDirectory: true)
							try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
							let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
							storedURL = folder.appendingPathComponent("import-\(UUID().uuidString).\(ext)")
							try FileManager.default.copyItem(at: url, to: storedURL)
						} else {
							storedURL = url
						}
						let transcript = Transcript(
							timestamp: Date(),
							text: timed.text.trimmingCharacters(in: .whitespacesAndNewlines),
							audioPath: storedURL,
							duration: duration,
							speakerTranscript: conversation
						)
						await send(.fileTranscriptionCompleted(transcript, shouldStore: shouldStore))
					} catch {
						historyLogger.error("File transcription failed: \(error.localizedDescription)")
						await send(.fileTranscriptionFailed(error.localizedDescription))
					}
				}

			case let .fileTranscriptionCompleted(transcript, shouldStore):
				state.isTranscribingFile = false
				state.fileTranscriptionResult = transcript.shareableText
				var evictedTranscripts: [Transcript] = []
				if shouldStore {
					@Shared(.hexSettings) var hexSettings: HexSettings
					state.$transcriptionHistory.withLock { history in
						history.history.insert(transcript, at: 0)
						if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
							while history.history.count > maxEntries {
								if let removed = history.history.popLast() {
									evictedTranscripts.append(removed)
								}
							}
						}
					}
				}
				return .merge(
					.run { [pasteboard] _ in await pasteboard.copy(transcript.shareableText) },
					.run { _ in await MacCloudSync.shared.uploadTranscript(transcript) },
					deleteAudioEffect(for: evictedTranscripts)
				)

			case let .fileTranscriptionFailed(error):
				state.isTranscribingFile = false
				state.fileTranscriptionError = error
				return .none

			case .clearFileTranscription:
				state.fileTranscriptionResult = nil
				state.fileTranscriptionError = nil
				return .none
			}
		}
	}
}

/// Caches app icons by bundle ID. `NSWorkspace.urlForApplication` +
/// `icon(forFile:)` are Launch Services round-trips — doing them per row
/// per render made scrolling a long history burn CPU on icon lookups.
@MainActor
enum AppIconCache {
	private static var icons: [String: NSImage] = [:]
	/// Bundle IDs that resolved to no app — cached so we don't retry
	/// the lookup on every render.
	private static var misses: Set<String> = []

	static func icon(for bundleID: String) -> NSImage? {
		if let cached = icons[bundleID] { return cached }
		if misses.contains(bundleID) { return nil }
		guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
			misses.insert(bundleID)
			return nil
		}
		let icon = NSWorkspace.shared.icon(forFile: appURL.path)
		icons[bundleID] = icon
		return icon
	}
}

struct TranscriptView: View {
	let transcript: Transcript
	let isPlaying: Bool
	let onPlay: () -> Void
	let onCopy: () -> Void
	let onDelete: () -> Void
	let isDetectingSpeakers: Bool
	let speakerDetectionError: String?
	let onDetectSpeakers: () -> Void
	let onRenameSpeaker: (String, String) -> Void

	/// Long dictations used to render in full, making a single row fill
	/// the window. Collapse past this many lines with a toggle.
	private static let collapsedLineLimit = 6
	@State private var isExpanded = false
	@State private var speakerBeingRenamed: String?
	@State private var speakerNameDraft = ""

	private var isLongTranscript: Bool {
		transcript.text.count > 500
			|| transcript.text.filter { $0 == "\n" }.count >= Self.collapsedLineLimit
			|| (transcript.speakerTranscript?.utterances.count ?? 0) > Self.collapsedLineLimit
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 8) {
				if let conversation = transcript.speakerTranscript {
					ForEach(visibleUtterances(in: conversation)) { utterance in
						HStack(alignment: .top, spacing: 10) {
							Button {
								speakerBeingRenamed = utterance.speakerID
								speakerNameDraft = conversation.displayName(for: utterance.speakerID)
							} label: {
								Text(conversation.displayName(for: utterance.speakerID))
									.font(.caption.weight(.semibold))
									.foregroundStyle(speakerColor(for: utterance.speakerID, in: conversation))
									.frame(width: 76, alignment: .leading)
							}
							.buttonStyle(.plain)
							.help("Rename speaker")

							Text(utterance.text)
								.font(.body)
								.fixedSize(horizontal: false, vertical: true)
								.textSelection(.enabled)
						}
					}
				} else {
					Text(transcript.text)
						.font(.body)
						.lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
						.fixedSize(horizontal: false, vertical: true)
						.textSelection(.enabled)
				}

				if let speakerDetectionError {
					Label(speakerDetectionError, systemImage: "exclamationmark.triangle")
						.font(.caption)
						.foregroundStyle(.orange)
				}

				if isLongTranscript {
					Button(isExpanded ? "Show less" : "Show more") {
						QuillMotion.run(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
					}
					.buttonStyle(.plain)
					.font(.caption.weight(.medium))
					.foregroundStyle(.tint)
				}
			}
			.padding(.trailing, 40) // Space for buttons
			.padding(12)

			Divider()

			HStack {
				HStack(spacing: 6) {
					// Mode badge
					TranscriptModeBadge(mode: transcript.mode)

					Text("•")

					// App icon and name
					if let bundleID = transcript.sourceAppBundleID,
					   let icon = AppIconCache.icon(for: bundleID) {
						Image(nsImage: icon)
							.resizable()
							.frame(width: 14, height: 14)
						if let appName = transcript.sourceAppName {
							Text(appName)
						}
						Text("•")
					}

					Image(systemName: "clock")
					Text(transcript.timestamp.relativeFormatted())
					Text("•")
					Text(transcript.timestamp.formatted(date: .omitted, time: .shortened))
					Text("•")
					Text(String(format: "%.1fs", transcript.duration))
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)

				Spacer()

				HStack(spacing: 10) {
					if transcript.speakerTranscript == nil {
						Button(action: onDetectSpeakers) {
							if isDetectingSpeakers {
								ProgressView().controlSize(.mini)
							} else {
								Image(systemName: "person.2.wave.2")
							}
						}
						.buttonStyle(.plain)
						.disabled(isDetectingSpeakers)
						.foregroundStyle(.secondary)
						.help(isDetectingSpeakers ? "Detecting speakers…" : "Detect speakers")
						.accessibilityLabel("Detect speakers")
					}

					Button {
						onCopy()
						showCopyAnimation()
					} label: {
						HStack(spacing: 4) {
							Image(systemName: showCopied ? "checkmark" : "doc.on.doc.fill")
							if showCopied {
								Text("Copied").font(.caption)
							}
						}
					}
					.buttonStyle(.plain)
					.foregroundStyle(showCopied ? .green : .secondary)
					.help("Copy to clipboard")

					Button(action: onPlay) {
						Image(systemName: isPlaying ? "stop.fill" : "play.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(isPlaying ? .blue : .secondary)
					.help(isPlaying ? "Stop playback" : "Play audio")
					.accessibilityLabel(isPlaying ? "Stop playback" : "Play audio")

					Button(action: onDelete) {
						Image(systemName: "trash.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.help("Delete transcript")
					.accessibilityLabel("Delete transcript")
				}
				.font(.subheadline)
				// Quieter rows: actions only appear on hover (or while
				// active), so the list reads as content, not chrome.
				.opacity(isHovering || isPlaying || isDetectingSpeakers || showCopied ? 1 : 0)
				.animation(.easeOut(duration: 0.12), value: isHovering)
			}
			.frame(height: 20)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
		}
		.background(
			RoundedRectangle(cornerRadius: QuillDesign.Radius.chip)
				.fill(Color(.windowBackgroundColor).opacity(isHovering ? 0.8 : 0.5))
				.overlay(
					RoundedRectangle(cornerRadius: QuillDesign.Radius.chip)
						.strokeBorder(Color.secondary.opacity(isHovering ? 0.3 : 0.2), lineWidth: 1)
				)
		)
		.onHover { isHovering = $0 }
		.onDisappear {
			// Clean up any running task when view disappears
			copyTask?.cancel()
		}
		.alert("Rename Speaker", isPresented: Binding(
			get: { speakerBeingRenamed != nil },
			set: { if !$0 { speakerBeingRenamed = nil } }
		)) {
			TextField("Speaker name", text: $speakerNameDraft)
			Button("Rename") {
				if let speakerID = speakerBeingRenamed {
					onRenameSpeaker(speakerID, speakerNameDraft)
				}
				speakerBeingRenamed = nil
			}
			Button("Cancel", role: .cancel) { speakerBeingRenamed = nil }
		} message: {
			Text("This changes the name everywhere this speaker appears in the transcript.")
		}
	}

	private func visibleUtterances(in conversation: SpeakerTranscript) -> [SpeakerUtterance] {
		isExpanded ? conversation.utterances : Array(conversation.utterances.prefix(Self.collapsedLineLimit))
	}

	private func speakerColor(for id: String, in conversation: SpeakerTranscript) -> Color {
		let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]
		let index = conversation.speakers.first(where: { $0.id == id })?.colorIndex ?? 0
		return palette[index % palette.count]
	}

	@State private var showCopied = false
	@State private var copyTask: Task<Void, Error>?
	@State private var isHovering = false

	private func showCopyAnimation() {
		copyTask?.cancel()

		copyTask = Task {
			QuillMotion.run {
				showCopied = true
			}

			try await Task.sleep(for: .seconds(1.5))

			QuillMotion.run {
				showCopied = false
			}
		}
	}
}

#Preview {
	TranscriptView(
		transcript: Transcript(timestamp: Date(), text: "Hello, world!", audioPath: URL(fileURLWithPath: "/Users/langton/Downloads/test.m4a"), duration: 1.0),
		isPlaying: false,
		onPlay: {},
		onCopy: {},
		onDelete: {},
		isDetectingSpeakers: false,
		speakerDetectionError: nil,
		onDetectSpeakers: {},
		onRenameSpeaker: { _, _ in }
	)
}

struct HistoryView: View {
	@ObserveInjection var inject
	let store: StoreOf<HistoryFeature>
	@State private var showingDeleteConfirmation = false
	@State private var isDropTargeted = false
	@State private var searchQuery: String = ""
	/// Search runs against this, not `searchQuery` directly — a 250ms
	/// debounce so a full-text scan of the history doesn't run on every
	/// keystroke.
	@State private var debouncedQuery: String = ""
	@Shared(.hexSettings) var hexSettings: HexSettings
	@Shared(.usageStats) var usageStats: UsageStats

	/// Transcripts filtered by the current search query. Matches case-
	/// insensitively against transcript text, speaker names, and source app name
	/// — so "slack" surfaces every dictation routed into Slack.
	private var visibleTranscripts: [Transcript] {
		let trimmed = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return store.transcriptionHistory.history }
		return store.transcriptionHistory.history.filter { transcript in
			if transcript.text.localizedCaseInsensitiveContains(trimmed) { return true }
			if transcript.speakerTranscript?.speakers.contains(where: {
				transcript.speakerTranscript?.displayName(for: $0.id)
					.localizedCaseInsensitiveContains(trimmed) == true
			}) == true { return true }
			if let app = transcript.sourceAppName,
			   app.localizedCaseInsensitiveContains(trimmed) { return true }
			return false
		}
	}

	/// Transcripts grouped by day, preserving newest-first order. The key
	/// is the relative day label ("Today", "Yesterday", "Monday", …).
	private var groupedTranscripts: [(label: String, transcripts: [Transcript])] {
		var groups: [(label: String, transcripts: [Transcript])] = []
		for transcript in visibleTranscripts {
			let label = transcript.timestamp.relativeFormatted()
			if groups.last?.label == label {
				groups[groups.count - 1].transcripts.append(transcript)
			} else {
				groups.append((label: label, transcripts: [transcript]))
			}
		}
		return groups
	}

	var body: some View {
      Group {
        VStack(spacing: 0) {
          // File transcription drop zone
          FileDropZoneView(store: store, isDropTargeted: $isDropTargeted)

          // Usage stats
          UsageStatsCardView(stats: usageStats)

          if !hexSettings.saveTranscriptionHistory {
            ContentUnavailableView {
              Label("History Disabled", systemImage: "clock.arrow.circlepath")
            } description: {
              Text("Transcription history is currently disabled.")
            } actions: {
              Button("Enable in Settings") {
                store.send(.navigateToSettings)
              }
            }
          } else if store.transcriptionHistory.history.isEmpty {
            ContentUnavailableView {
              Label("No Transcriptions", systemImage: "text.bubble")
            } description: {
              Text("Your transcription history will appear here.")
            }
          } else if visibleTranscripts.isEmpty {
            ContentUnavailableView.search(text: searchQuery)
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groupedTranscripts, id: \.label) { group in
                  Text(group.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, 4)
                  ForEach(group.transcripts) { transcript in
                    TranscriptView(
                      transcript: transcript,
                      isPlaying: store.playingTranscriptID == transcript.id,
                      onPlay: { store.send(.playTranscript(transcript.id)) },
					  onCopy: { store.send(.copyToClipboard(transcript.shareableText)) },
					  onDelete: { store.send(.deleteTranscript(transcript.id)) },
					  isDetectingSpeakers: store.speakerDetectionInFlight.contains(transcript.id),
					  speakerDetectionError: store.speakerDetectionErrors[transcript.id],
					  onDetectSpeakers: { store.send(.detectSpeakers(transcript.id)) },
					  onRenameSpeaker: { speakerID, name in
						store.send(.renameSpeaker(transcriptID: transcript.id, speakerID: speakerID, name: name))
					  }
					)
                  }
                }
              }
              .padding()
            }
            .toolbar {
              Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
                Label("Delete All", systemImage: "trash")
              }
            }
            .alert("Delete All Transcripts", isPresented: $showingDeleteConfirmation) {
              Button("Delete All", role: .destructive) {
                store.send(.confirmDeleteAll)
              }
              Button("Cancel", role: .cancel) {}
            } message: {
              Text("Are you sure you want to delete all transcripts? This action cannot be undone.")
            }
          }
        }
      }
      // Same soft brand wash as the Home pane, so the two default surfaces
      // read as one product (flat language: tint, not chrome).
      .background(
        RadialGradient(
          colors: [QuillDesign.brand.color(0.08), .clear],
          center: UnitPoint(x: 0.5, y: -0.15),
          startRadius: 0,
          endRadius: 620
        )
        .ignoresSafeArea()
      )
      .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search transcripts")
      .task(id: searchQuery) {
        // Debounce: wait for typing to settle before running the
        // full-text filter. Cancelled + restarted on each keystroke.
        if searchQuery.isEmpty {
          debouncedQuery = ""
          return
        }
        try? await Task.sleep(for: .milliseconds(250))
        debouncedQuery = searchQuery
      }
      .onDrop(of: [.audio, .movie], isTargeted: $isDropTargeted) { providers in
        handleDrop(providers)
      }
      .enableInjection()
	}

	private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
		for provider in providers {
			provider.loadItem(forTypeIdentifier: "public.audio", options: nil) { item, _ in
				if let url = item as? URL {
					Task { @MainActor in store.send(.transcribeFile(url)) }
				} else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
					Task { @MainActor in store.send(.transcribeFile(url)) }
				}
			}
			provider.loadItem(forTypeIdentifier: "public.movie", options: nil) { item, _ in
				if let url = item as? URL {
					Task { @MainActor in store.send(.transcribeFile(url)) }
				}
			}
		}
		return true
	}
}

struct FileDropZoneView: View {
	let store: StoreOf<HistoryFeature>
	@Binding var isDropTargeted: Bool

	var body: some View {
		VStack(spacing: 8) {
			if store.isTranscribingFile {
				ProgressView()
					.controlSize(.small)
				Text("Transcribing and identifying speakers...")
					.font(.caption)
					.foregroundStyle(.secondary)
			} else if let result = store.fileTranscriptionResult {
				VStack(spacing: 6) {
					Text(result)
						.font(.body)
						.lineLimit(5)
						.textSelection(.enabled)
					HStack {
						Text("Copied to clipboard")
							.font(.caption)
							.foregroundStyle(.green)
						Spacer()
						Button("Clear") {
							store.send(.clearFileTranscription)
						}
						.buttonStyle(.borderless)
						.font(.caption)
					}
				}
			} else if let error = store.fileTranscriptionError {
				Label(error, systemImage: "exclamationmark.triangle")
					.font(.caption)
					.foregroundStyle(.red)
			} else {
				Image(systemName: "waveform.badge.plus")
					.font(.title2)
					.foregroundStyle(isDropTargeted ? .blue : .secondary)
				Text("Drop audio or video file to transcribe")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity)
		.padding(12)
		.background(
			RoundedRectangle(cornerRadius: QuillDesign.Radius.chip)
				.strokeBorder(
					isDropTargeted ? Color.blue : Color.secondary.opacity(0.3),
					style: StrokeStyle(lineWidth: 1.5, dash: [6, 3])
				)
				.background(
					RoundedRectangle(cornerRadius: QuillDesign.Radius.chip)
						.fill(isDropTargeted ? Color.blue.opacity(0.05) : Color.clear)
				)
		)
		.padding(.horizontal)
		.padding(.top, 8)
	}
}

// MARK: - Usage Stats Card

struct UsageStatsCardView: View {
	let stats: UsageStats

	var body: some View {
		HStack(spacing: 0) {
			StatItem(
				icon: "text.word.spacing",
				value: Self.formatNumber(stats.totalWordsTranscribed),
				label: "Words",
				tint: .secondary
			)
			StatItem(
				icon: "mic.fill",
				value: "\(stats.dictationCount)",
				label: "Dictations",
				tint: .blue
			)
			StatItem(
				icon: "pencil",
				value: "\(stats.editCount)",
				label: "Edits",
				tint: .purple
			)
			StatItem(
				icon: "bolt.fill",
				value: "\(stats.actionCount)",
				label: "Actions",
				tint: .teal
			)
			StatItem(
				icon: "clock.arrow.circlepath",
				value: Self.formatTimeSaved(stats.estimatedMinutesSaved),
				label: "Saved",
				tint: .green
			)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.quillCard()
		.padding(.horizontal)
		.padding(.top, 8)
	}

	static func formatTimeSaved(_ minutes: Double) -> String {
		if minutes < 1 { return "<1m" }
		if minutes < 60 { return "\(Int(minutes))m" }
		let hours = minutes / 60
		return String(format: "%.1fh", hours)
	}

	static func formatNumber(_ n: Int) -> String {
		if n >= 1_000_000 {
			return String(format: "%.1fM", Double(n) / 1_000_000)
		}
		if n >= 1000 {
			return String(format: "%.1fk", Double(n) / 1000)
		}
		return "\(n)"
	}
}

private struct StatItem: View {
	let icon: String
	let value: String
	let label: String
	var tint: Color = .secondary

	var body: some View {
		VStack(spacing: 4) {
			Image(systemName: icon)
				.font(.caption)
				.foregroundStyle(tint)
			Text(value)
				.font(.headline.monospacedDigit())
			Text(label)
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity)
	}
}

// MARK: - Mode Badge

private struct TranscriptModeBadge: View {
	let mode: TranscriptionMode?

	private var resolvedMode: TranscriptionMode { mode ?? .dictate }

	private var icon: String {
		switch resolvedMode {
		case .dictate: "mic.fill"
		case .edit: "pencil"
		case .action: "bolt.fill"
		}
	}

	private var label: String {
		switch resolvedMode {
		case .dictate: "Dictation"
		case .edit: "Edit"
		case .action: "Action"
		}
	}

	private var tint: Color {
		switch resolvedMode {
		case .dictate: .blue
		case .edit: .purple
		case .action: .teal
		}
	}

	var body: some View {
		HStack(spacing: 3) {
			Image(systemName: icon)
				.font(.caption2)
			Text(label)
				.font(.caption)
		}
		.foregroundStyle(tint)
		.padding(.horizontal, 7)
		.padding(.vertical, 2)
		.background(tint.opacity(0.12), in: Capsule())
	}
}
