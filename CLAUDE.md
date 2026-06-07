# Quill – Dev Notes for Agents

This file provides guidance for coding agents working in this repo.

> **Naming note:** The project was renamed from **Hex** (Kit Langton's original) to **Quill** (Joe Vasquez's fork). Internal module names like `HexCore`, `HexSettings`, and `HexLog` intentionally retain the "Hex" name — they are internal technical identifiers, and renaming them would be pure churn. User-facing identifiers (bundle ID, product name, storage paths, copyright, About view) have all been updated to Quill / Joe Vasquez.

## Project Overview

Quill is a macOS menu bar application (plus an iOS companion app) for on-device voice-to-text with optional AI post-processing. It supports Whisper (Core ML via WhisperKit) and Parakeet TDT v3 (Core ML via FluidAudio). Users activate transcription with hotkeys; text can be auto-pasted into the active app, with optional LLM clean-up via OpenAI or Anthropic.

**Bundle IDs:**
- macOS: `com.joevasquez.Quill` (release), `com.joevasquez.Quill.debug` (debug)
- iOS: `com.joevasquez.Quill.iOS`

**Storage:** `~/Library/Application Support/com.joevasquez.Quill/` on macOS.

## Build & Development Commands

```bash
# Build the macOS app
xcodebuild -scheme Quill -configuration Release

# Build the iOS app (Simulator)
xcodebuild -scheme "Quill iOS" -destination 'generic/platform=iOS Simulator' build

# Run tests (must be run from HexCore directory for unit tests)
cd HexCore && swift test

# Or run all tests via Xcode
xcodebuild test -scheme Hex

# Open in Xcode (recommended for development)
open Hex.xcodeproj
```

## Architecture

The app uses **The Composable Architecture (TCA)** for state management. Key architectural components:

### Features (TCA Reducers)
- `AppFeature`: Root feature coordinating the app lifecycle
- `TranscriptionFeature`: Core recording and transcription logic
- `SettingsFeature`: User preferences and configuration
- `HistoryFeature`: Transcription history management
- `ActionConfirmationFeature`: Action mode confirmation panel state (integration picker, editable fields, execute/cancel)

### Dependency Clients
- `TranscriptionClient`: WhisperKit integration for ML transcription
- `RecordingClient`: AVAudioRecorder wrapper for audio capture
- `PasteboardClient`: Clipboard operations
- `KeyEventMonitorClient`: Global hotkey monitoring via Sauce framework
- `ActionParsingClient`: Parses Action-mode voice commands into structured `ActionIntent` JSON via the LLM
- `RemindersAdapter`: EventKit wrapper that creates Apple Reminders from an `ActionIntent`
- `TodoistAdapter`: Todoist v1 REST client (`https://api.todoist.com/api/v1/`) — token validation, project fetch, task creation

### Key Dependencies
- **WhisperKit**: Core ML transcription (tracking main branch)
- **FluidAudio (Parakeet)**: Core ML ASR (multilingual) default model
- **Sauce**: Keyboard event monitoring
- **Sparkle**: Auto-update framework is linked but the feed URL has been removed for the Quill fork. Joe can host his own appcast on GitHub Releases or an S3 bucket if/when he wants to ship updates.
- **Swift Composable Architecture**: State management
- **Inject** Hot Reloading for SwiftUI

## Important Implementation Details

1. **Hotkey Recording Modes**: The app supports both press-and-hold and double-tap recording modes, implemented in `HotKeyProcessor.swift`. See `docs/hotkey-semantics.md` for detailed behavior specifications including:
   - **Modifier-only hotkeys** (e.g., Option) use a **0.3s threshold** to prevent accidental triggers from OS shortcuts
   - **Regular hotkeys** (e.g., Cmd+A) use user's `minimumKeyTime` setting (default 0.2s)
   - Mouse clicks and extra modifiers are discarded within threshold, ignored after
   - Only ESC cancels recordings after the threshold

2. **Model Management**: Models are managed by `ModelDownloadFeature`. Curated defaults live in `Hex/Resources/Data/models.json`. The Settings UI shows a compact opinionated list (Parakeet + three Whisper sizes). No dropdowns.

3. **Sound Effects**: Audio feedback is provided via `SoundEffect.swift` using files in `Resources/Audio/`

4. **Window Management**: Uses an `InvisibleWindow` for the transcription indicator overlay

5. **Permissions**: Requires audio input and automation entitlements (see `Hex.entitlements`)

6. **Logging**: All diagnostics should use the unified logging helper `HexLog` (`HexCore/Sources/HexCore/Logging.swift`). Pick an existing category (e.g., `.transcription`, `.recording`, `.settings`) or add a new case so Console predicates stay consistent. Avoid `print` and prefer privacy annotations (`, privacy: .private`) for anything potentially sensitive like transcript text or file paths.

7. **Paste reliability (macOS)**: `PasteboardClient.paste(text:sourceAppBundleID:)` takes the bundle ID captured at record-start so we can reactivate the user's original target app before pasting (AppKit's front-app state has usually drifted 1–3 s later after Whisper + AI finish). Order of attempts: (a) reactivate source app, wait 120 ms for focus to settle; (b) refuse to paste if we're still frontmost (don't write into Quill's own Settings); (c) Accessibility `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` with before/after value verification — silent "success" from apps that accept but drop the write is caught and falls through; (d) clipboard + `Cmd+V` via CGEvent; (e) always sync the transcription into the clipboard post-paste so any user-initiated `Cmd+V` recovery still delivers the dictation. Both AX insertion and CGEvent injection require `AXIsProcessTrusted()` — we check once upfront and skip paths that would silently fail when permission is missing.

8. **Cross-platform AI modes architecture**:
   - `HexCore/Models/AIProcessingMode.swift` holds the built-in modes (off / clean / email / notes / message / code) plus the safety preamble (public) used by inline edit + custom modes.
   - `HexCore/Models/CustomAIMode.swift` defines user-authored modes (`name`, `systemPrompt`, `icon`) and `AIModeSelection` — a wrapper supporting both built-ins and `custom:<uuid>`. `CustomAIMode.fullSystemPrompt` wraps the user prompt in the shared preamble.
   - macOS persists custom modes in `HexSettings.customAIModes`; iOS via `@AppStorage(CustomAIModesStorage.userDefaultsKey)` (JSON-encoded `[CustomAIMode]`).
   - Both AI clients (`AIProcessingClient` on macOS, `TextAIClient` on iOS) accept an optional `customSystemPrompt` override — call sites resolve the prompt from the current selection and pass it through.
   - User messages are wrapped in `<transcript>…</transcript>` tags by `TranscriptWrapper`; `TranscriptRefusalDetector` catches "I am a post-processor"-style refusals and falls back to the raw transcript so the user's dictation is never replaced by an assistant-style reply.

9. **Inline Edit (macOS)**: Active in Edit mode (HUD pill cycle) or when `hexSettings.inlineEditEnabled` is on. The user highlights text in any app, holds the hotkey, speaks an instruction ("tighten 20%", "translate to Spanish"), and releases. The pipeline: record → transcribe → send instruction + selection to LLM (`InlineEditPrompt.systemPrompt`) → replace selection via AX → show Accept/Undo pill on the HUD. Falls back to normal paste if AX replacement fails.

   **Critical architecture note — selection capture timing:** Selection capture (`InlineEditClient.captureSelectionSync`) happens in `handleStopRecording`, NOT `handleStartRecording`. This is intentional. AX calls in the reducer at recording-start blocked/interfered with the recording effect chain in TCA, causing Edit mode to silently fail to record. Moving capture to stop time works because the HUD is a non-activating `NSPanel`, so the source app is still frontmost with text highlighted when the user releases the hotkey. If AX fails (common in Chrome/Electron), a clipboard fallback (Cmd+C simulation via CGEvent) runs in parallel with transcription (~150ms vs ~1-3s).

   **Selection capture strategy (two-tier):**
   - **Tier 1 — AX sync** (`captureSelectionSync`): reads `kAXSelectedTextAttribute` from the focused element. Fast, no side effects. Works in native AppKit apps and most Cocoa text views.
   - **Tier 2 — Clipboard fallback** (`captureSelectionViaClipboard`): simulates Cmd+C, reads pasteboard, restores original clipboard. Works in Chrome, Electron (Slack, VS Code, Discord), and apps with non-standard text controls. Same approach as Raycast/Rewind.

10. **Integrations surface**: `HexCore/Models/Integration.swift` holds the static catalog (`todoist`, `appleReminders`, `calendar`, `googleCalendar`, `gmail`, `notion`, `things`, `slack`, `linear`) with per-integration tint, tagline, and Pro flag. `IntegrationConnectionStore` persists the connected set in UserDefaults under a cross-platform key. `IntegrationLimits.freeTierMaxConnections = 2` caps free-tier connections — but the cap counts **only non-Pro integrations** (`requiresPro == false`). Without that filter, signing into Google fills the cap with `.gmail` + `.googleCalendar` and disables every other Connect button. Five integrations ship with working adapters today:
   - **Apple Reminders**: EventKit. macOS `RemindersAdapter` (TCA `@DependencyClient`) + iOS `IOSRemindersAdapter` (`@MainActor enum`). Requires `com.apple.security.personal-information.calendars` entitlement + `NSRemindersUsageDescription`.
   - **Apple Calendar**: EventKit. `CalendarAdapter` (macOS) + `IOSCalendarAdapter` (iOS). Same entitlement + `NSCalendarsFullAccessUsageDescription`.
   - **Todoist**: REST API. `TodoistAdapter` (macOS) + `IOSTodoistAdapter` (iOS). User pastes their API token via `TodoistTokenSheet` (macOS) / `TodoistTokenSheetIOS`. Token validates against `GET /api/v1/projects` and is stored under `KeychainKey.todoistAPIToken`.
   - **Gmail + Google Calendar**: shared OAuth (one sign-in, both services). `GoogleOAuthClient` (macOS) + `IOSGoogleOAuthClient` (iOS) handle the auth flow via `ASWebAuthenticationSession` + PKCE against an **iOS-type** Google Cloud OAuth credential (Desktop-type clients are rejected by Google for custom URI scheme redirects since 2022). No client secret in source — PKCE replaces it. Adapters: `GmailAdapter` / `GoogleCalendarAdapter` on macOS, `IOSGmailAdapter` / `IOSGoogleCalendarAdapter` on iOS. Tokens stored under `KeychainKey.googleAccessToken` / `.googleRefreshToken` / `.googleTokenExpiry`. The integration set is treated as a UI cache; **OAuth keychain state is the source of truth for `.gmail`/`.googleCalendar`** — `QuilliOSApp.syncGoogleIntegrationsFromOAuth()` repairs the store on every launch so signing in/out of Google always reflects in the dropdown + Integrations rows.
   - Other integrations (Notion, Things, Slack, Linear) still show "Coming Soon" — send adapters land in follow-ups.

11. **Action mode (macOS)**: Third HUD pill (Dictate → Edit → Action) routes voice commands to integrations. Pipeline: record → transcribe → `ActionParsingClient` produces `ActionIntent { actionType, targetIntegration, title, dueDate, notes, listName, priority }` → `ActionConfirmationPanel` (a key-capable `NSPanel` anchored below the menu bar) drops down with the **HEARD / WILL DO** card → user confirms → adapter creates the task. Key behaviors:
   - **LLM picks the integration from voice context.** "Add to Todoist write email to Mike" → `targetIntegration: .todoist, title: "Write email to Mike"`. The integration phrase is stripped from the title.
   - **HUD integration picker (Action mode only)**: while the HUD is in Action mode, a chip row appears under the pill listing the user's connected & authenticated integrations. Tapping a chip — or pressing `fn + 1`…`fn + 9` — toggles a **hard lock**. When locked, the `actionIntentParsed` reducer overrides the LLM-picked `targetIntegration` with the user's choice. Each chip shows `[icon] Name [fn N]` so the keystroke is discoverable. The fn-digit global tap is wired in `AppFeature.startActionIntegrationHotKeyMonitoring()` and ignored when not in Action mode (so it doesn't hijack fn-digit for users who never use Action).
   - **Confirmation panel layout**: `ActionConfirmationView` renders four sections — header tile (integration icon + "New <noun> in <Integration>" + "Action detected"), HEARD section quoting the raw transcript that was parsed, WILL DO card with editable rows (icon + value + pencil affordance), and a footer with a ghost **Dismiss** button + a filled-purple **Run action** button (default keyboard shortcut, `↵` glyph chip). The raw transcript is plumbed through via `ActionConfirmationNotification.rawTranscriptKey` so the panel can quote what we heard; `ActionConfirmationFeature.State.rawTranscript` holds it.
   - **Post-recording integration override** also lives in the panel header as a `Picker` (only shown when 2+ integrations are connected) — this is the escape hatch; the HUD chip row is the pre/during-recording one.
   - **Per-integration UI**: Apple Reminders shows Title/Due/List/Notes; Todoist shows Title/Due/Project/Priority/Notes; Calendar/Google Calendar show Title/Start/End/Calendar/Attendees/Notes; Gmail shows To/Subject/Body. The list/project picker refreshes when the integration changes.
   - **Default fallback**: if the LLM picks an unconfigured integration, the panel falls back to Apple Reminders (always available, no setup).
   - The confirmation panel uses `NotificationCenter` (`actionConfirmationExecuted` / `actionConfirmationCancelled`) to signal completion to `HexAppDelegate`. Observers must hop to `MainActor` via `Task { @MainActor in ... }` since notifications can fire from background queues — the `@MainActor @objc` annotation is a lie under Objective-C bridging.

12. **Mode cycle hotkey (macOS)**: `HexSettings.cycleModeHotkey: HotKey?` is a separate global hotkey that cycles the HUD between Auto/Dictate/Edit/Action without triggering a recording. Wired in `AppFeature.startCycleModeHotKeyMonitoring()`, which mirrors the data-race-safe pattern used for `pasteLastTranscriptHotkey`. Settings UI lives alongside the recording hotkey in `HotKeySectionView` with clear "Recording" / "Cycle Mode" labels.

13. **Auto-titles (iOS)**: New notes are created with empty `title` + `isAutoTitle = true`. `displayTitle` falls back to `Note.derivedTitle` until `NotesStore.generateTitleIfNeeded(noteID:provider:)` swaps in an LLM-generated 3–6 word title via `TextAIClient.generateTitle(for:provider:)`. Flipping `isAutoTitle = false` (either by the AI landing OR the user calling `renameNote`) locks the title so subsequent appends don't re-title. Legacy notes persisted before this field decode as `isAutoTitle = false` so their derived titles are preserved.

14. **Privacy manifests**: Both targets ship `PrivacyInfo.xcprivacy` declaring `NSPrivacyAccessedAPICategoryUserDefaults` (reason `C56D.1`) and `NSPrivacyAccessedAPICategoryFileTimestamp` (reason `C617.1`). With error monitoring enabled, both also declare `NSPrivacyCollectedDataTypeCrashData` (`Linked = false`, `Tracking = false`, purpose `AppFunctionality`). `NSPrivacyTracking = false`, no tracking domains.

15. **Action mode (iOS)**: Mirrors macOS but uses `@MainActor enum` adapters instead of TCA. Triggered via the orange action FAB in the bottom cluster (`QuillFABCluster` — see iOS UI below). Pipeline: record → WhisperKit transcribes locally → `IOSActionParsingClient.parse()` LLM-parses transcript → `ActionConfirmationSheet` (SwiftUI sheet, `ObservableObject` view-model) → user confirms → `IOSSystemActionQueueExecutor.execute()` routes to the right iOS adapter. Same `ActionIntent` model as macOS, same `ActionSystemPrompt` (in HexCore). Five integrations supported today (see #10).

16. **Offline action queue** (`HexCore/Sources/HexCore/Offline/`): persists Action-mode operations that fail because of transient network errors and replays them on reconnect. Two payload shapes:
    - `.ready(ActionIntent)` — already parsed, just needs to dispatch (e.g. Gmail draft creation hit a 503).
    - `.pendingParse(transcript:provider:)` — the LLM parse itself failed (user dictated offline), so the raw transcript is queued; on reconnect the manager parses via the registered `ActionQueueParser` and promotes to `.ready` before executing. Promotion is persisted, so a successful parse + failed execute doesn't re-pay the parse on the next pass.

    `ActionQueueManager` (actor) owns persistence (`QueuedActionStore`, file-backed JSON in app-support), retry policy (exponential backoff with jitter, `RetryPolicy.default`), and a `NetworkMonitor` observer that triggers `processQueue()` on reconnect. Each app target installs an `ActionQueueExecutor` + `ActionQueueParser` at launch (`SystemActionQueueExecutor` / `SystemActionQueueParser` on macOS, `IOSSystemActionQueueExecutor` / `IOSActionQueueParser` on iOS). `QueueableErrorClassifier` decides which errors are transient (URLError transport failures, 5xx, 408, 429); permission/auth/cancel errors are NOT queued. UI: `OfflineQueueSectionView` (macOS Settings → General) + `OfflineQueueView` (iOS Settings → Offline) show pending items with retry/discard. The macOS menu-bar dropdown shows "N pending offline action(s)" via `MenuBarPendingActionsButton` when count > 0.

17. **Error monitoring** (`HexCore/Sources/HexCore/Errors/` + per-target adapter): protocol-based (`ErrorMonitoringService`) with two implementations — `NoOpErrorMonitoring` (default; DEBUG builds echo to `HexLog.app`) and `SentryErrorMonitoring` (live; in `Hex/Clients/`, shared with iOS via `membershipExceptions` in pbxproj, `#if canImport(Sentry)` guards so the codebase compiles before/after the SDK is added). **Opt-in only** — `SentryErrorMonitoring.configure()` gates the SDK init on `ErrorMonitoringSettings.crashReportingEnabledKey` (defaults to false). Settings toggle in macOS General + iOS Privacy section; flipping it re-runs `ErrorMonitoring.configure()` so the SDK starts/stops live. Capture sites are deliberately sparse: AI processing failures, Google OAuth refresh failures, Gmail draft creation failures. Never include response bodies in captured context (they can echo user content).

18. **Search**: iOS `NotesListView` has a custom search field (not `.searchable` — it gets re-tinted by iOS in unwanted ways) styled as a frosted capsule matching the header buttons; matches title/body/location case-insensitively. macOS `HistoryView` uses `.searchable` (placement `.toolbar`) and matches transcript text + source app name.

19. **Live transcript HUD card (macOS)**: While recording, the HUD shows a fixed-width (520pt) card under the pill with the live partial transcript. Powered by `SpeechRecognitionClient` (`Hex/Clients/SpeechRecognitionClient.swift`) — a TCA `@DependencyClient` that wraps Apple's `SFSpeechRecognizer` plus a dedicated `AVAudioEngine` running in parallel with `RecordingClient` (which is `AVAudioRecorder`-based). On macOS multiple consumers can read from the same input device, so the speech engine and the file-based recorder don't interfere. The recognizer prefers on-device recognition when supported. The authoritative transcript is still produced by WhisperKit/Parakeet on stop — SFSpeech is preview-only.
    - **Authorization** is requested on `.task` (silently no-ops if denied). `Hex/Info.plist` declares `NSSpeechRecognitionUsageDescription`.
    - **Wiring**: `TranscriptionFeature.handleStartRecording` opens an `AsyncStream<String>` from `speechRecognition.startRecognition(localeIdentifier)`; each yielded partial dispatches `partialTranscriptUpdated(text)` which writes `state.partialTranscript`. The stream is torn down via `CancelID.liveTranscription` plus an explicit `stopRecognition()` call on stop/discard.
    - **Adaptive height**: `LiveTranscriptCard` uses `.lineLimit(4, reservesSpace: false)` with `.truncationMode(.head)` so the card grows from one line up to four, then truncates from the head — the latest words are always visible without an internal ScrollView.

20. **Cloud Sync (cross-device notes)**: Opt-in sync of iOS notes + macOS transcripts via Google Cloud, riding on the existing Google OAuth tokens — no Firebase SDK, just Firestore + GCS REST APIs. Architecture lives in `HexCore/Sources/HexCore/CloudSync/` so both apps share it.
    - **GCP project**: `quill-495210`. Firestore database id `quill-db` (Native mode). GCS bucket `quill-49521-notes` (uniform access). Constants in `CloudSyncConstants`.
    - **OAuth scopes added**: `datastore` + `devstorage.read_write` to both `GoogleOAuthClient` and `IOSGoogleOAuthClient`. Existing users must re-auth Google to grant.
    - **Data layout** (Firestore): `users/{sanitizedEmail}/notes/{id}`, `.../transcripts/{id}`, `.../tombstones/{id}`, `.../photoManifests/{id}`. Email sanitizer in `CloudPhotoPath.sanitize` — collision-prone (`.`/`_` substitution) but fine for single-user; revisit if multi-user.
    - **Photos**: JPEGs at `gs://quill-49521-notes/users/{email}/photos/{noteId}/{photoId}.jpg`. Photo manifests in Firestore tell the receiving device what to download. **Important: GCS object names with slashes MUST be percent-encoded as `%2F`** in the URL path — `.urlPathAllowed` includes `/` so we use a custom `objectNameAllowed` CharacterSet that strips it. Without this, `GET /b/{bucket}/o/{objectPath}` returns 404 because GCS interprets the slashes as nested API segments.
    - **Conflict resolution**: last-writer-wins by `updatedAt` (single-user app). `CloudSyncManager.fullSync` does bidirectional merge with a re-entrancy guard.
    - **Tombstones for deletes**: instead of relying on "doc missing means deleted" (which loses to a stale upload), every delete writes a `SyncTombstone {id, deletedAt, sourceDevice}`. Receiving devices fetch tombstones first during sync, skip uploading anything tombstoned, and locally remove notes whose tombstone `deletedAt > local.updatedAt`.
    - **Per-note debounce on upload**: `NotesStore.syncNoteToCloud` keeps a `pendingUploads: [UUID: Task]` map and cancels the prior pending upload for the same note before scheduling a new one with a 500ms sleep. Without this, rapid mutations (typing in NoteEditSheet, AI title landing right after a record append) raced PATCHes and the *latest-arrival* won, not the *latest-issued*.
    - **Stable device ID**: `DeviceIdentity.id` (private to NotesStore) combines `identifierForVendor` + `UIDevice.current.model`, cached in `UserDefaults` under `quill.deviceID`. Don't use `UIDevice.current.name` — without the `com.apple.developer.device-information.user-assigned-device-name` entitlement (Apple grants on request only), it returns a generic "iPhone" on iOS 16+.
    - **Sync triggers**: `scenePhase == .active` on iOS (not `App.init` — competes with model warm-up + TCC prompts at launch). Per-mutation upload on every `save()` for individual notes. macOS uploads transcripts on save when `hexSettings.cloudSyncEnabled` is on; user-driven "Sync Now" buttons exist on both platforms with a published `SyncStatus` enum that drives a status row UI.
    - **Settings UI**: iOS `SettingsView` shows the toggle + status row only when `IOSGoogleOAuthClient.isAuthorized()`. macOS `CloudSyncSectionView` lives in General settings, gated on `MacCloudSync.isGoogleAuthorized()` (which reads the cached email from UserDefaults — the OAuth client is async, this is the sync probe).
    - **macOS Notes view**: A third sidebar pill (Settings/History/**Notes**) hosts `NotesView` — a two-pane viewer that renders cloud-synced iOS notes with inline photos via `MacPhotoStore` (cache at `~/Library/Application Support/com.joevasquez.Quill/SyncedPhotos/{noteId}/{photoId}.jpg`). Read-only V1.
    - **Shared rendering**: `NoteContent` (segment tokenizer) and `NoteTextView` (markdown bullets/headings) live in HexCore so iOS and macOS render note bodies identically.
    - **`HexSettings.cloudSyncEnabled`**: defaults `false`. Field added to the schema in the standard pattern; legacy settings files decode cleanly via the existing `decodeIfPresent ?? default` strategy.

## Models (2025‑11)

- Default: Parakeet TDT v3 (multilingual) via FluidAudio
- Additional curated: Whisper Small (Tiny), Whisper Medium (Base), Whisper Large v3
- Note: Distil‑Whisper is English‑only and not shown by default

### Storage Locations

- WhisperKit models
  - `~/Library/Application Support/com.joevasquez.Quill/models/argmaxinc/whisperkit-coreml/<model>`
- Parakeet (FluidAudio)
  - We set `XDG_CACHE_HOME` on launch so Parakeet caches under the app container:
  - `~/Library/Containers/com.joevasquez.Quill/Data/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml`
  - Legacy `~/.cache/fluidaudio/Models/…` is not visible to the sandbox; re‑download or import.

### Progress + Availability

- WhisperKit: native progress
- Parakeet: best‑effort progress by polling the model directory size during download
- Availability detection scans both `Application Support/FluidAudio/Models` and our app cache path

## Building & Running

- macOS 14+, Xcode 15+

### Packages

- WhisperKit: `https://github.com/argmaxinc/WhisperKit`
- FluidAudio: `https://github.com/FluidInference/FluidAudio.git` (link `FluidAudio` to Hex target)

### Entitlements (Sandbox)

- `com.apple.security.app-sandbox = true`
- `com.apple.security.network.client = true` (HF downloads)
- `com.apple.security.files.user-selected.read-write = true` (optional import)
- `com.apple.security.automation.apple-events = true` (media control)
- `com.apple.security.personal-information.calendars = true` — needed by Action mode's `RemindersAdapter` to call `EKEventStore.requestFullAccessToReminders()` (paired with `NSRemindersUsageDescription` in Info.plist).
- `com.apple.security.cs.disable-library-validation = true` — required because Sparkle.framework's XPC services (`spks` update installer, `spki` status checker) are signed by a different team identifier, and Inject uses unsigned dylibs for hot-reload in debug builds. Without this, the sandbox rejects the library loads at runtime.

### Cache root (Parakeet)

Set at app launch and logged:

```
XDG_CACHE_HOME = ~/Library/Containers/com.joevasquez.Quill/Data/Library/Application Support/com.joevasquez.Quill/cache
```

FluidAudio models reside under `Application Support/FluidAudio/Models`.

21. **Orb display mode (macOS)**: Alternative HUD skin toggled via Settings → General → Display Mode (`HexSettings.displayMode: .hud | .orb`). The orb is a luminous sphere whose hue encodes the mode (Auto=steel-blue 220°, Dictate=blue 248°, Edit=violet 305°, Action=teal 188°, Success=green 150°) and whose motion encodes the phase (idle→listening→transcribing→result). All rendering is native SwiftUI — no WKWebView.
    - **Architecture**: `OrbView` (`Hex/Features/Transcription/OrbView.swift`) takes the same inputs as `TranscriptionIndicatorView` (status, mode, meter, partialTranscript, etc.). `TranscriptionView.body` conditionally renders one or the other based on `store.hexSettings.displayMode`. Both are hosted in the same `HUDPanel`.
    - **Colour animation**: SwiftUI can't interpolate `Color` inside a `RadialGradient`. The orb uses a white gradient base + `.colorMultiply(orbColor)` so the tint animates. `@State displayedHue` and `displayedSaturation` update via `withAnimation` on `onChange(of: targetHue/targetSaturation)` for smooth hue sweeps between modes.
    - **Orbiting particles**: 6 small circles on tilted elliptical paths. The correct SwiftUI transform chain is `.offset(x: radius)` → `.rotationEffect(spin)` → `.scaleEffect(x:1, y:0.5)` → `.rotationEffect(tilt)` — matching the CSS prototype's `rotate(tilt) scaleY(0.5)` container transform. Using `rotation3DEffect` instead produces incorrect linear paths.
    - **Dark backdrop**: A frosted glass card (`ultraThinMaterial` + black overlay) behind the orb ensures contrast against any desktop wallpaper.
    - **Shared sub-views**: `LiveTranscriptCard` and `IntegrationToggleButton` (in `TranscriptionIndicatorView.swift`) are `internal` access so both display modes can reference them.
    - **Act-mode satellite ring**: When the orb is in Action mode, the idle ambient particles are replaced by a ring of `OrbSatelliteTile` buttons — one per connected integration — arranged on a circle (`OrbSize.satelliteRingRadius = 90pt`) around the orb centre. The active target satellite is highlighted with its accent colour (from `Integration.satelliteHue`), scaled 1.16×, and connected to the orb by a dashed `Canvas`-drawn tether line. A keyword-based destination classifier (`OrbView.intuitTarget(from:integrations:)`) scans the partial transcript live during recording, updating the highlighted satellite as words arrive (app names beat verbs). Clicking a satellite calls `onToggleActionIntegration`, which sets `lockedActionIntegration` in `TranscriptionFeature` — locking it for the rest of the utterance so later words don't move the target. `Integration.intuitKeywords` (in HexCore) holds the per-integration keyword arrays used by the classifier.
    - **Auto mode integration**: When the orb is in Auto mode, it shows a neutral steel-blue hue (220°, saturation 0.3) at idle. During recording, `autoDetectedMode` drives the hue — the orb smoothly transitions to the detected mode's colour. The mode badge shows "Auto · Dictate/Edit/Action" with the detected mode's accent colour. The satellite ring appears when Auto detects Action mode. The compact idle layout (narrower `orbField` and `orbCaption`) expands horizontally and vertically when recording begins.

22. **Auto mode (macOS)**: Fourth mode in the cycle (Auto → Dictate → Edit → Action) that auto-detects intent from the transcript and context. The default `selectedMode` is `.auto`. Auto mode is macOS-only for now.
    - **Classifier**: `AutoModeClassifier` (`Hex/Features/Transcription/AutoModeClassifier.swift`) is a stateless keyword-based classifier with two entry points:
      - `classifyPartial(_:)` — runs on every `partialTranscriptUpdated` during recording to update the orb's live badge. Checks action keywords first (more specific), then edit keywords, default dictate.
      - `resolve(transcript:hasSelection:hasIntegrations:)` — final decision at transcription-result time with full context. Action requires connected integrations + action keywords. Edit requires a captured text selection + edit keywords. Default is dictate.
    - **Edit keywords**: "shorten", "rewrite", "translate", "fix", "proofread", "tighten", "summarize", "make more professional", "clean up", "fix grammar", "convert to", etc.
    - **Action keywords**: "add to", "remind me", "todoist", "send email", "schedule", "gmail", integration names, etc.
    - **State**: `TranscriptionFeature.State.autoDetectedMode` tracks the live-detected mode. Reset to `.dictate` on recording start and when cycling into Auto.
    - **Selection capture**: `handleStopRecording` captures selection (AX + clipboard fallback) when `selectedMode == .auto`, not just `.edit`. This is safe because capture happens at stop time, not start time (Lesson #1).
    - **Pipeline branching**: `handleTranscriptionResult` computes `effectiveMode` via `AutoModeClassifier.resolve()` when in Auto, then routes to the existing Branch 1 (inline edit), Branch 2 (edit no selection), Branch 3 (action), or Branch 4 (dictate). Existing mode behaviour is unchanged for non-Auto modes.
    - **Stash/replay**: The clipboard-fallback race guard (`editClipboardFallbackPending` + `pendingTranscriptionForEdit`) applies to Auto mode identically — if Parakeet transcribes faster than the clipboard fallback, the result is stashed and replayed when the clipboard resolves.
    - **Mode enum**: `TranscriptionIndicatorView.Mode` gains `.auto` (rawValue "Auto", icon `sparkles`, accentColor `.gray`). `.next` cycles Auto → Dictate → Edit → Action → Auto.
    - **HUD pill**: Shows "Auto · Dictate/Edit/Action" chip with the detected mode's accent colour during recording. At idle shows the sparkles icon with grey accent.

## UI

- **Settings tabs (macOS)**: Four tabs in the sidebar — General, Recording, AI Processing, Integrations. Each is a wrapper view in `SettingsTabs.swift` that composes existing section views into a `Form { … }.formStyle(.grouped)`. The "About" section (version, changelog, replay tutorial) and "Transforms" (word remappings) are folded into General and Recording respectively — no standalone tabs. Cloud Sync settings live in the Notes pane, not General.
- **AI Formatting Modes**: The AI tab's "Formatting Modes" section unifies the built-in mode picker, auto-select-by-app toggle, and the user's custom modes library in one section. `CustomModeEditorMac` (the sheet for creating/editing custom modes) is defined in `AIProcessingSectionView.swift` as a non-private struct shared by both the inline section and the legacy `CustomModesSectionView`.
- **Notes pane (macOS)**: Sidebar shows `NotesSidebarList` with `.searchable` (case-insensitive match on title/body/location). Detail pane is `NotesView` with a "New Note" toolbar button, a rich `NoteEditorView` with markdown live-highlighting via `MarkdownHighlighter` (NSTextStorage attributes — bold, italic, strikethrough, code, headings, bullets — markers fade to near-invisible while content gets typographic treatment). Cloud sync controls (toggle + status + Sync Now) appear in the detail pane's landing view when no note is selected and Google is connected.
- **Markdown editor architecture**: `MarkdownTextEditor` is an `NSViewRepresentable` wrapping `NSTextView`. It exposes a `textView` binding so the formatting toolbar (Bold ⌘B, Italic ⌘I, Strikethrough, Code, Heading, Bullet) can call `wrapSelection(prefix:suffix:)` and `insertAtLineStart(_:)`. Highlighting is reapplied after every `textDidChange` via `MarkdownHighlighter.highlight(_:)`, with undo registration suspended during attribute application.
- Settings → Transcription Model shows a compact list with radio selection, accuracy/speed dots, size on right, and trailing menu / download‑check icon.
- Context menu offers Show in Finder / Delete.
- **`AppPickerButton`**: Shared `NSOpenPanel`-based app-picker component (`AppPickerButton.swift`) used by both `AppModeRuleRow` (per-app AI mode overrides) and `AppPasteDelayRow` (per-app paste delay). Extracted to eliminate duplicate `PickedApp` structs and `pickApp()` methods.
- **API key auto-save**: The AI provider section uses a 1-second debounced auto-save (`autoSaveAPIKey`) instead of a manual "Save" button — the key is written to keychain after the user stops typing.
- **Display Mode picker**: Settings → General → App section includes a segmented picker ("Standard HUD" / "Orb") that toggles `HexSettings.displayMode`. The orb renders in the same `HUDPanel` as the standard pill — switching is instant with no panel recreation.
- **GoogleOAuthSheet**: Shows "Done" (with `.defaultAction` shortcut) after successful sign-in instead of "Cancel".

## iOS Companion App

The iOS app lives in the `Quill iOS/` folder (note: folder name has a space — the Xcode build setting is `INFOPLIST_FILE = "Quill iOS/Info.plist"`). It's a lightweight companion, not a feature-parity port of macOS.

### Scope

- On-device transcription via WhisperKit (Core ML). No FluidAudio / Parakeet on iOS yet.
- AI post-processing of transcripts via `TextAIClient` (Anthropic or OpenAI).
- Local note store with inline photos; photos are analyzed by a vision model (`PhotoAnalysisClient`).
- PDF export of a note (text + inline photos + AI analyses).
- Editable note titles, share menu (text-only or PDF), location-tagged note creation.
- API keys stored via `KeychainStore` (direct Security-framework calls; see the keychain note below).
- No hotkeys, no auto-paste, no menu bar. Tap feather mic/camera → speak/snap → get structured note → share/export.

### Structure

- `QuilliOSApp.swift` — `@main` entry point.
- `ContentView.swift` — main screen. Purple header with feather logo + list/new/gear buttons, active-note strip (tap title to rename), mode chip row, note canvas with inline photos + AI-analysis cards, floating mic + camera FAB cluster at bottom-right, status pill above it.
- `SettingsView.swift` — sheet with Whisper model selector, AI provider picker, API key field.
- `NotesListView.swift` — sheet listing all saved notes with rename/delete.
- `QuillIOSSettings.swift` — `@AppStorage` keys and defaults.
- `PhotoPicker.swift` — `PHPickerViewController` (library) and `UIImagePickerController` (camera) wrappers.
- `ShareSheet.swift` — `UIActivityViewController` wrapper driven by `ShareRequest` (Identifiable items wrapper).
- `NotePDFExporter.swift` — `ImageRenderer` → `CGContext` PDF of a note, including photo-analysis blocks.
- `Models/Note.swift` — `id`, `title`, `body` (flat string with inline photo tokens), timestamps, optional `location`. `wordCount` and `displayTitle` strip photo tokens before computing.
- `Models/NoteContent.swift` — tokenizer. Photos embed as `![photo](<uuid>)` in `body`. `segments(from:)` splits into `.text` / `.photo` segments for rendering; `stripPhotos(from:)` for share/copy/preview.
- `Models/PhotoAnalysis.swift` — Codable sidecar (`summary`, `keyDetails[]`, optional `transcribedText`, `analyzedAt`, `model`).
- `Clients/IOSRecordingClient.swift` — `AVAudioRecorder` wrapper with metering and permission handling.
- `Clients/NotesStore.swift` — JSON-persisted `[Note]` + active-note ID in UserDefaults. Also owns published `photoAnalyses: [UUID: PhotoAnalysis]`, `analyzingPhotoIDs`, `analysisErrors`. Loads analyses from disk on init so views refresh automatically.
- `Clients/PhotoStore.swift` — persists `Application Support/photos/<note-id>/<photo-id>.jpg` and sidecar `<photo-id>.json`. Downscales to 1568 px long edge at JPEG 0.75 with `UIGraphicsImageRendererFormat.scale = 1` (forcing scale-1 is critical — the default uses the screen scale and re-inflates the image).
- `Clients/PhotoAnalysisClient.swift` — ships a JPEG to Anthropic or OpenAI with a JSON-only system prompt, parses the structured response. Recompresses on the fly (`compressForVision`) if the on-disk image is over 4 MB (Anthropic caps at 5 MB).
- `Clients/TextAIClient.swift` — iOS-specific text post-processor. Mirrors the shared macOS `AIProcessingClient` but reads the API key via `KeychainStore` and logs per-call so "AI didn't run" failures are visible.
- `Clients/KeychainStore.swift` — direct Security-framework helpers (`SecItemAdd` / `SecItemCopyMatching`). See the keychain note below for why this exists.
- `Clients/LocationClient.swift` — one-shot best-effort reverse geocode used when a note is created.
- `CustomModesView.swift` — Settings sub-screen for managing user-authored AI modes. Persists via `@AppStorage` under `CustomAIModesStorage.userDefaultsKey`. Modes surface as chips in the main screen's mode row (see `CustomModeChip` in ContentView).
- `IntegrationsView.swift` — Settings sub-screen listing the integrations catalog (`HexCore/Models/Integration.swift`). Frontend-only; connection state persisted via `IntegrationConnectionStore` in UserDefaults. Free tier capped at `IntegrationLimits.freeTierMaxConnections = 2`.
- `QuillDeepLinkRouter.swift` — `@MainActor ObservableObject` that parses incoming `quill://` URLs (from the widget) into a `QuillDeepLink` enum. `ContentView` observes `pendingLink` and routes: `.record` starts a new note + recording, `.notes` shows the notes list.

#### Reusable iOS UI components (`Quill iOS/Views/`)

These exist so individual screens stop reinventing the same chrome. When in doubt, use them; if a screen needs something subtly different, copy + tweak rather than parameterize each component to death.

- `QuillHeaderBar.swift` — purple gradient band with rounded bottom corners (24pt `UnevenRoundedRectangle`), Quill wordmark + feather, three trailing 36pt frosted-circle buttons (notes list / new / settings). All button actions are passed in as closures so the host owns the navigation state.
- `QuillActiveNoteStrip.swift` — under-header strip with the note title, lavender-chip edit-text icon, location/time/word-count metadata, and an optional `recordingElapsed: TimeInterval?` that swaps the right edge for a pulsing red dot + `M:SS` timer.
- `QuillFABCluster.swift` — bottom-right cluster. Single `+` button at rest; tap fans up into a vertical stack of dictate (top, with the `QuillModeDropdown` floating in to its leading edge), photo, action FABs. While recording, the `+` itself flips to a red `stop.fill` button — single-tap to stop.
- `QuillModeDropdown.swift` — single pill that opens a system Menu listing built-in + custom AI modes. Modes that need an LLM are greyed out + show "Needs API key" when the current provider has no key in Keychain; tapping a greyed-out mode surfaces an alert pointing to Settings instead of silently selecting nothing.
- `QuillEmptyHome.swift` — pre-recording landing ("Ready when you are." + three teaching chips), shown when there's no active note and the user isn't recording.
- `QuillRecordingState.swift` — split into `QuillRecordingTranscriptCard` (white card in the scroll area; internally scrolling at `maxHeight: 280` with auto-scroll-to-bottom on transcript change) + `WaveformBottomBar` (lavender-gradient card pinned to the bottom via `.safeAreaInset`, 32 vertical purple bars driven by `vm.meterLevel` via `.onChange` — **don't** use `Timer.publish` + `onReceive` here, the closure captures `meterLevel` once and never sees fresh values).

### Widget (iOS home-screen)

The widget extension lives in `QuillWidget/` as a separate target (`QuillWidgetExtension`), **NOT** in `Quill iOS/`. Created through Xcode's `File → New → Target → Widget Extension` flow; the resulting `PBXNativeTarget` / sync group / exception set / embed build phase are all in `project.pbxproj`.

- `QuillWidget/QuillWidgetBundle.swift` — `@main WidgetBundle` entry.
- `QuillWidget/QuillWidget.swift` — small + medium widget families. Small = feather + "Quill" + "Dictate" CTA. Medium = same on the left, latest-note card on the right. Both use a purple gradient `containerBackground`. The feather is drawn as a SwiftUI `FeatherShape: Shape` (filled vector path), not the PNG asset — the PNG is a thin outline that collapses to an illegible stroke at widget icon sizes.
- `QuillWidget/Assets.xcassets/` — standard widget assets. The sync group includes a `PBXFileSystemSynchronizedBuildFileExceptionSet` excluding `Info.plist` from the target's Copy Bundle Resources phase (otherwise it collides with `INFOPLIST_FILE` → `QuillWidget/Info.plist`).
- `HexCore/Models/QuillWidgetSnapshot.swift` — tiny Codable blob (title + preview + updatedAt) written by the main app into App Group `group.com.joevasquez.Quill` UserDefaults. Both targets need the **App Groups** capability with this group in their `*.entitlements`.
- Deep links: tapping the small family or the left half of the medium family opens `quill://record` → `ContentView` starts a **new** note + begins recording. Tapping the right half of the medium family opens `quill://notes` → presents the notes list.
- `NotesStore.updateWidgetSnapshot()` fires on every `save()` and calls `WidgetCenter.shared.reloadAllTimelines()`.

### Keychain (iOS)

The shared `KeychainClient` (in `Hex/Clients/`) uses `@DependencyClient`, which is unreliable on the iOS target under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: `save(...)` returned success but nothing was actually persisted, and subsequent reads returned `errSecItemNotFound (-25300)`. **Do not use `KeychainClient.liveValue.save/read` on iOS.** Use `KeychainStore` in `Quill iOS/Clients/` for all keychain access from the iOS app. `KeychainStore` also splits save vs. lookup queries — `kSecAttrAccessible` is applied only on save (it is not a reliable filter on `SecItemCopyMatching`).

### Photo flow

1. Tap camera FAB → confirmation dialog (Take Photo / Choose from Library).
2. If recording, the dialog first stops recording so the dictated text is committed before the photo lands.
3. `NotesStore.insertPhotoIntoActiveNote(_:locationIfCreating:)` saves the JPEG and appends a `![photo](<uuid>)` token to the active note's `body`.
4. `analyzePhoto(noteID:photoID:provider:)` fires in the background — writes a `<photo-id>.json` sidecar and updates `photoAnalyses`. Views refresh automatically.

### Shared Code via `HexCore`

The iOS target imports `HexCore` for:
- `AIProcessingMode`, `AIProvider` (enums used by `TextAIClient` / `PhotoAnalysisClient`).

`Hex/Clients/KeychainClient.swift` is still included (via the iOS-target file-system-synchronized group exceptions) because `KeychainKey.openAIAPIKey` / `.anthropicAPIKey` constants live there, but iOS code should not call `KeychainClient.liveValue` methods — use `KeychainStore` instead.

macOS-only clients (`SleepManagementClient`, `PermissionClient`) have iOS stub `liveValue`s so `HexCore` compiles for both platforms.

### Settings Model

iOS uses `@AppStorage` with plain `UserDefaults` keys (namespaced as `quill.*`), **not** the macOS `HexSettings` struct. Keep the two in sync manually if adding shared settings.

Defaults: model = `openai_whisper-tiny.en`, mode = `off`, provider = `anthropic`.

### Permissions

`Quill iOS/Info.plist` declares:
- `NSMicrophoneUsageDescription` — recording.
- `NSSpeechRecognitionUsageDescription` — live partial transcript while recording.
- `NSCameraUsageDescription` — in-note photos.
- `NSPhotoLibraryUsageDescription` — library-sourced photos.
- `NSLocationWhenInUseUsageDescription` — optional, tags new notes with a rough place name.

### Xcode project

The iOS target is a `PBXFileSystemSynchronizedRootGroup` — new files in `Quill iOS/` are auto-included, no `pbxproj` edits needed. Shared files from `Hex/Clients/` are pulled into the iOS target via an explicit `membershipExceptions` list in `project.pbxproj`. Xcode occasionally normalizes bundle-ID quoting in the `pbxproj` on build; revert those with `git checkout -- Hex.xcodeproj/project.pbxproj` to keep diffs clean.

## Lessons Learned (for agents)

1. **Never do AX work in `handleStartRecording`.** macOS Accessibility queries (`AXUIElementCopyAttributeValue`) can block, time out (0.5s per call), or silently corrupt the TCA effect chain when called synchronously inside the reducer at recording-start. This caused Edit mode to fail to record while Dictate/Action worked fine — same `beginRecording()` call, but the AX calls before it poisoned the path. The fix: defer all AX/clipboard work to `handleStopRecording`, where it can't block the recording effect.

2. **`@DependencyClient` macro name collisions.** The TCA `@DependencyClient` macro generates underscore-prefixed backing stores for each property (e.g., `_captureSelectionViaClipboard`). If you define a free function with that same underscore-prefixed name, the compiler silently picks the wrong one. Name helper functions distinctly (e.g., `clipboardFallbackCapture()` instead of `_captureSelectionViaClipboard()`).

3. **Race conditions with async clipboard fallback + hotkey release.** If recording start is deferred behind an `async` clipboard capture (~150ms), the user can release the hotkey during that window. `isRecording` is still `false`, so the release is ignored. Recording then starts with no future release event to stop it. Fix: always start recording synchronously first, run fallback captures in parallel.

4. **Non-activating panels preserve focus.** `HUDPanel` is `NSPanel` with `.nonactivatingPanel` — it doesn't steal focus from the source app. This is why selection capture at stop-time works: the source app is still frontmost with text highlighted.

5. **`setFrameOrigin` positions the BOTTOM-LEFT corner, not top-left.** macOS uses a bottom-up Y axis. `HUDPanel.centerOnMainScreen` originally did `y = maxY - 80` intending "80pt below the screen top" — but that put the panel *bottom* 80pt below the top, which placed the rest of the 240pt panel ABOVE the visible screen. The bug went unnoticed for ages because anyone with a saved drag position (`com.joevasquez.Quill.hudPosition` in UserDefaults) bypassed `centerOnMainScreen` entirely; it only surfaced after we added a bounds-check that routed offscreen-saved positions back through the broken default. Fix: use `screen.visibleFrame` (excludes menu bar/dock) and subtract `frame.height` so the panel TOP, not bottom, lands at the desired offset.

6. **`HUDPanel.restorePosition` validates against `NSScreen.screens`.** A saved drag position from a previously-attached external display is now silently invalid after disconnect. Without bounds-checking the saved point against any current screen's frame, `setFrameOrigin` accepts any nonsense coordinates and the panel vanishes with no recovery path. Use `screen.frame.intersects(candidateRect)` rather than `contains(point)` so a deliberately edge-flushed pill isn't re-centered just because one pixel is off the screen.

7. **GCS object names with `/` MUST be percent-encoded as `%2F`.** When uploading via the JSON Cloud Storage REST API's `/b/{bucket}/o/{name}` endpoint, the `name` is URL-path data and slashes must encode. `.urlPathAllowed` includes `/` so it does nothing — use a custom CharacterSet that strips `/` from `urlPathAllowed`. Without this, GCS interprets the path segments as nested API paths and returns 404. (Upload via `?uploadType=media&name=...` works because URL query parameters get encoded correctly automatically.)

8. **`UIDevice.current.name` returns "iPhone" on iOS 16+.** The user-assigned device name is now gated behind a special entitlement (`com.apple.developer.device-information.user-assigned-device-name`) that Apple grants on request only. Use `identifierForVendor` + the model name for cross-device identification — see `DeviceIdentity.id` in `NotesStore`.

9. **macOS Keychain prompts on every settings tab switch.** The system keychain password dialog fires on *every* `SecItemCopyMatching` call in sandboxed debug builds with ad-hoc signing. Three places were reading the keychain repeatedly: (a) `GoogleOAuthClient.refreshIfNeeded()` read three items (access token, refresh token, expiry) on every cloud sync, (b) `GoogleOAuthClient.isAuthorized()` read the refresh token on every call, (c) `AIProcessingSectionView.onAppear` re-loaded the API key on every AI tab visit. Fix: add an in-memory `TokenCache` to `GoogleOAuthClient` that loads from keychain once per launch and serves all subsequent reads from RAM. `isAuthorized()` now checks UserDefaults (the cached email) instead of keychain. The `SettingsFeature.task` action is guarded by `hasRunTask` so it only fires once, and it eagerly loads the API key on first run.

10. **SwiftUI `onChange` fires during initial value assignment.** When a `NoteEditorView` opens, `loadFields()` sets `editingTitle` and `editingBody`, which triggers `onChange(of:)` handlers that call `onMarkDirty()` — marking every note as dirty the instant it's selected. Fix: gate `onChange` handlers with a `hasInitialized` flag that's set to `false` before assignment and flipped back via `DispatchQueue.main.async` after the assignments complete (so the `onChange` closures triggered by the assignments see `false`).

11. **SettingsFeature `.task` runs per tab, not once.** Each settings tab wrapper has `.task { await store.send(.task).finish() }`. Without a guard, switching between General → Recording → AI → Integrations fires `.task` four times, launching duplicate long-running effects (key-event listeners, device monitors, model fetches). Fix: add `state.hasRunTask` and return `.none` on subsequent calls.

12. **Parakeet transcription can beat the clipboard fallback.** Parakeet TDT v3 transcribes in ~0.07s with a warm model — faster than the 150ms clipboard fallback (Cmd+C simulation) used when AX selection reading fails. Without guarding against this race, `handleTranscriptionResult` sees `inlineEditSelection == nil` and falls through to the Dictate path, pasting raw instruction text instead of processing it as an Edit command. Fix: `editClipboardFallbackPending` flag + `pendingTranscriptionForEdit` stash. When the transcription arrives before the clipboard result, the result is stashed and replayed once the clipboard fallback resolves. The stash stores the raw (uncleaned) result so the full `handleTranscriptionResult` pipeline (WhisperOutputCleaner, voice commands, word remapping) runs exactly once on replay.

13. **CGEvent key injection can leave modifiers stuck in VDI apps.** Citrix Viewer, Microsoft RDP, and VMware Horizon bridge CGEvent keystrokes to a remote session over the network. When Quill simulates Cmd+C (clipboard fallback) or Cmd+V (paste), the remote app may process the key-down but swallow or delay the key-up. This leaves the Command key "held" in the remote session — all subsequent clicks become Cmd+Click (no-op in most apps) and typing is interpreted as shortcuts. The mouse still moves (cursor tracking is separate from keyboard state). Fix: after every CGEvent key sequence, post a `flagsChanged` event with empty flags (`CGEvent.flags = []`) to explicitly clear all modifier state. Applied in `clipboardFallbackCapture`, `postCmdV`, `sendKeyboardCommand`, and `sendUndoToSourceApp`.

14. **`AIProcessingClient.process()` returns input unchanged on missing API key — it doesn't throw.** For Dictate mode this is fine (raw text paste). For inline Edit mode it's catastrophic: the returned "input" is `InlineEditPrompt.userMessage(instruction:selection:)` — a formatted LLM prompt containing both the instruction and the selection — which gets pasted over the user's selected text. Fix: callers (Branch 1 and Branch 2 in `handleTranscriptionResult`) now pre-check the API key via `keychain.read()` before calling `aiProcessing.process()`, and surface a clear HUD message ("Add an API key in Settings → AI") instead of silently failing.

## Enhancement Opportunities

1. **WhisperKit streaming for the live preview**: We use SFSpeechRecognizer for the live transcript card (see Implementation Detail #19). It's good but English-biased and not always identical to what WhisperKit/Parakeet ultimately produce. A WhisperKit streaming API or a lightweight second-model instance would give a preview that matches the final transcript more closely.

2. **Per-app AX skip list**: Some apps (Chrome, Electron) never respond to `kAXSelectedTextAttribute`. Could maintain a bundle-ID skip list to go straight to clipboard fallback, saving the AX timeout.

3. **Edit mode undo stack**: Currently tracks one pending edit (Accept/Undo pill). Could support multi-level undo for consecutive edits to the same selection.

4. **macOS Notes: record directly into a note**: The "New Note" button creates an empty note and selects it, but the user still has to use the global hotkey to dictate. A dedicated "Dictate into this note" button in the Notes editor toolbar could start a recording scoped to the active note, appending the transcript on stop.

5. **macOS Notes: delete note with cloud tombstone**: `NotesView.deleteNote` currently removes the note from the local array only. It doesn't write a `SyncTombstone` to Firestore, so the note will reappear on the next cloud sync. Wire up `MacCloudSync.writeTombstone(id:)` from the delete action.

6. **macOS Notes: photo download on demand**: The notes detail pane shows placeholder cards for photos that haven't been downloaded from GCS yet. Could add a "Download" button or auto-fetch visible photos when the note is selected.

8. **Auto mode improvements**: Auto mode (see Implementation Detail #22) uses keyword matching. Future improvements: (a) NLU-based classifier instead of keyword lists for better accuracy; (b) confidence thresholds — if the classifier is uncertain, ask the user via the mode badge ("Dictate?") rather than silently committing; (c) per-app Auto overrides (e.g., always Edit in VS Code when text is selected); (d) iOS port — the classifier is cross-platform (in `AutoModeClassifier.swift`) but the iOS UI doesn't have the mode cycle yet.

7. **Keychain migration to `kSecUseDataProtectionKeychain`**: The current `SecItemAdd` / `SecItemCopyMatching` calls use the legacy macOS keychain, which is why the system password dialog appears. Adding `kSecUseDataProtectionKeychain: true` to queries would use the modern Data Protection keychain (no password prompts, syncs better with sandboxed apps). Requires testing that existing items are migrated or re-saved.

## Troubleshooting

- Repeated mic prompts during debug: ensure Debug signing uses "Apple Development" so TCC sticks
- Sandbox network errors (‑1003): add `com.apple.security.network.client = true` (already set)
- Parakeet not detected: ensure it resides under the container path above; downloading from Hex places it correctly.
- **Edit mode not recording**: If Edit mode silently fails to record while Dictate works, check that `handleStartRecording` does NOT call any AX functions. All selection capture must happen in `handleStopRecording`. See "Lessons Learned" above.

## Changelog Workflow Expectations

1. **Always add a changeset:** Any feature, UX change, or bug fix that ships to users must come with a `.changeset/*.md` fragment. The summary should mention the user-facing impact plus the GitHub issue/PR number (for example, "Improve Fn hotkey stability (#89)").
2. **Use non-interactive changeset creation:** AI agents should use the non-interactive script:
   ```bash
   bun run changeset:add-ai patch "Your summary here"
   bun run changeset:add-ai minor "Add new feature"
   bun run changeset:add-ai major "Breaking change"
   ```
3. **Only create changesets, don't process them:** Agents should only create changeset fragments. The release tool is responsible for running `changeset version` to collect changesets into `CHANGELOG.md` and syncing to `Hex/Resources/changelog.md`.
4. **Reference GitHub issues:** When a change addresses a filed issue, link it in code comments and the changeset entry (`(#123)`) so release notes and Sparkle updates point users back to the discussion. If the work should close an issue, include "Fixes #123" (or "Closes #123") in the commit or PR description so GitHub auto-closes it once merged.

## Git Commit Messages

- Use a concise, descriptive subject line that captures the user-facing impact (roughly 50–70 characters).
- Follow up with as much context as needed in the body. Include the rationale, notable tradeoffs, relevant logs, or reproduction steps—future debugging benefits from having the full story directly in git history.
- Reference any related GitHub issues in the body if the change tracks ongoing work.

## Releasing a New Version

Two release scripts live at `tools/scripts/`. Both are bash, both read prerequisites from the keychain / env.

### macOS (DMG via GitHub Releases + Sparkle)

#### End-to-end release flow

This is the complete sequence for shipping a new macOS version. The release script handles archive → sign → notarize → DMG → Sparkle signing → appcast generation. Post-script steps (commit, tag, push, GitHub Release upload) are manual.

```bash
# 1. Create a changeset for user-facing changes
bun run changeset:add-ai minor "Summary of changes"

# 2. Bump version — folds changesets into CHANGELOG.md, bumps package.json
bun run changeset:version

# 3. Sync version into Info.plist and pbxproj (changeset only bumps package.json)
#    - Update CFBundleShortVersionString in Hex/Info.plist
#    - Increment CFBundleVersion (build number) in Hex/Info.plist
#    - Update MARKETING_VERSION in Hex.xcodeproj/project.pbxproj (4 occurrences for macOS)
#    - Update CURRENT_PROJECT_VERSION in Hex.xcodeproj/project.pbxproj (4 occurrences for macOS)
#    - Copy CHANGELOG.md to Hex/Resources/changelog.md (embedded resource)

# 4. Commit all version bumps + changelog
git add -A && git commit -m "Bump version to X.Y.Z"

# 5. Run the release script (archive, sign, notarize, DMG, Sparkle)
bash tools/scripts/release.sh

# 6. The script regenerates appcast.xml with only the new version.
#    Manually re-add the previous version's <item> block so users can
#    roll back. The old entry is in git history if needed.

# 7. Commit appcast, tag, push
git add appcast.xml
git commit -m "Update appcast for vX.Y.Z"
git tag vX.Y.Z
git push origin main vX.Y.Z

# 8. Upload DMG to GitHub Release (or create if new)
gh release create vX.Y.Z --repo joevasquez/Quill \
  --title "Quill vX.Y.Z" \
  --notes-file build/release/release-notes.md \
  build/release/Hex-latest.dmg

# If re-uploading a notarized build to an existing release:
gh release upload vX.Y.Z build/release/Hex-latest.dmg --clobber --repo joevasquez/Quill
```

#### Prerequisites (one-time)

1. **Developer ID Application certificate** in the login keychain. Verify: `security find-identity -p codesigning -v`. Should show `Developer ID Application: Joseph Vasquez (ND4KZ9EE2W)`.

2. **Notarization credentials** stored under profile `QUILL_NOTARY`. **Use the App Store Connect API key** (not Apple ID + app-specific password — that approach fails with Joe's account):
   ```bash
   xcrun notarytool store-credentials QUILL_NOTARY \
     --key ~/.appstoreconnect/private_keys/AuthKey_3QDATSKTNN.p8 \
     --key-id 3QDATSKTNN \
     --issuer 69a6de80-182b-47e3-e053-5b8c7c11a4d1
   ```
   The `.p8` key file lives at `~/.appstoreconnect/private_keys/AuthKey_3QDATSKTNN.p8`. This is the same key used for TestFlight uploads. No Apple ID password needed.

3. **Sparkle signing tools** at `bin/sign_update` and `bin/generate_appcast`. Already committed to the repo. The EdDSA private key lives in the keychain (created by `generate_keys` during initial Sparkle setup).

#### What the script does

1. Archives via `xcodebuild -scheme Quill -configuration Release`
2. Exports with Developer ID signing (automatic signing style, team `ND4KZ9EE2W`)
3. Zips the `.app` and submits to Apple notary service (waits for `Accepted`)
4. Staples the notarization ticket to the `.app`
5. Creates a DMG (`Hex-latest.dmg` — stable name for download URLs)
6. Submits + staples the DMG itself (both `.app` and DMG are independently notarized)
7. Extracts release notes from `CHANGELOG.md` for the current version
8. Signs the DMG with `bin/sign_update` (EdDSA signature for Sparkle verification)
9. Runs `bin/generate_appcast` to produce `appcast.xml`

Output:
- `build/release/Hex-latest.dmg` — signed, notarized, stapled DMG (~14 MB)
- `build/release/release-notes.md` — extracted notes for this version
- `appcast.xml` — updated at repo root (needs manual commit + push)

#### Sparkle auto-update flow

- `Info.plist` contains `SUFeedURL` pointing to `https://raw.githubusercontent.com/joevasquez/Hex/main/appcast.xml`
- `Info.plist` contains `SUPublicEDKey` (EdDSA public key for signature verification)
- Sparkle checks the appcast periodically; when `sparkle:version` > installed build number, it offers the update
- The `enclosure` URL points to the GitHub Release asset: `https://github.com/joevasquez/Hex/releases/download/vX.Y.Z/Hex-latest.dmg`
- `sparkle:edSignature` in the appcast must match what `bin/sign_update` produced for the exact DMG file uploaded to GitHub — if you re-build or re-notarize, the signature changes and the appcast must be regenerated

#### Appcast maintenance

`generate_appcast` scans `build/release/` and writes a fresh `appcast.xml` with only the builds it finds. Since we only have the current build in that directory, the generated appcast has one `<item>`. To preserve rollback capability, manually add the previous version's `<item>` block back before committing. The old entries are always in git history.

### iOS (TestFlight)

```bash
bash tools/scripts/testflight.sh
```

Auto-bumps `CFBundleVersion` in `Quill iOS/Info.plist` (App Store Connect requires strictly-higher build numbers). If the upload fails, revert with `git checkout "Quill iOS/Info.plist"`.

**Prerequisites** (one-time):
1. Apple Distribution cert in the login keychain, OR Xcode signed into the Apple ID so `-allowProvisioningUpdates` can mint one.
2. App Store Connect API key `.p8` file at `~/.appstoreconnect/private_keys/AuthKey_3QDATSKTNN.p8` (same key as notarization).
3. App Store Connect app record with bundle ID `com.joevasquez.Quill.iOS`.

**Env overrides**:
- `QUILL_ASC_KEY_ID` (default `3QDATSKTNN`)
- `QUILL_ASC_ISSUER_ID` (default `69a6de80-182b-47e3-e053-5b8c7c11a4d1`)

**What it does**: archives → exports App Store-signed `.ipa` → uploads to App Store Connect via `xcrun altool`. After upload, TestFlight processes it (a few minutes) and notifies testers.

Output:
- `build/testflight/Quill-iOS-<build>.ipa`

### Pre-release checklist

1. Working tree clean (commit or stash first).
2. Changeset exists for any user-facing change:
   ```bash
   bun run changeset:add-ai patch "Your summary here"
   ```
3. `bun run changeset:version` → bumps package.json + writes CHANGELOG.md. Commit the result.
4. Manually sync version to `Hex/Info.plist`, `Hex.xcodeproj/project.pbxproj`, and `Hex/Resources/changelog.md`.
5. macOS: `bash tools/scripts/release.sh`. iOS: `bash tools/scripts/testflight.sh`.
6. After a successful macOS build: commit appcast, tag, push, upload DMG to GitHub Releases.

### Troubleshooting

- **"Working tree is not clean"**: commit or stash before releasing.
- **`notarytool profile 'QUILL_NOTARY' not found`**: re-run the `store-credentials` command above with the `.p8` API key. Do NOT use Apple ID + app-specific password — it doesn't work with Joe's account setup. The API key approach is simpler and more reliable.
- **Notarization returns `Invalid`**: check `xcrun notarytool log <submission-id> --keychain-profile QUILL_NOTARY` for details. Common causes: unsigned frameworks, hardened-runtime violations, or missing `--options=runtime` in codesign.
- **Build fails on `xcodebuild`**: ensure `xcode-select` points at `/Applications/Xcode.app/Contents/Developer`, not `/Library/Developer/CommandLineTools`. Both scripts pin `DEVELOPER_DIR` at the top to defend against this.
- **Sparkle update not showing**: verify (a) `appcast.xml` is committed and pushed to `main`, (b) the `sparkle:edSignature` matches the uploaded DMG, (c) `sparkle:version` (build number) is strictly greater than the installed version. If you re-notarized and re-uploaded the DMG, the file changed — re-run `bin/sign_update` and `bin/generate_appcast` and push the updated appcast.
- **TestFlight rejects upload with "build number must be higher"**: the auto-bump should handle this; if it didn't, manually bump `CFBundleVersion` in `Quill iOS/Info.plist` and re-run.
