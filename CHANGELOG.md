# Changelog

## 0.26.0

### Minor Changes

- bc6a757: Show the Action workflow inside the app: when the Home pane is open, the confirmation card renders under the command bar instead of dropping out of the menu bar
- bc6a757: VoiceOver labels across the Mac app (6 to 41), plus Reduce Motion on every animation and Reduce Transparency on card surfaces
- bc6a757: Add an Actions pane recording every agent run with a per-step trace (tool, arguments, raw result, and the before/after of a chained step's resolve pass)
- bc6a757: Adopt Liquid Glass on iOS 26: the capture cluster now morphs out of the + button, and the search field, note composer, and mode rail use system glass
- bc6a757: Consolidate the corner-radius scale: one 5-step token set replaces 14 ad-hoc radii across 269 call sites, and Radius.card no longer contradicts cardCornerRadius
- bc6a757: Mac Home: move the Act/Notes toggle above the input bar, bring the iOS destination chip row to macOS in Act mode, and add @-mention tagging so a typed command can pin the exact integration or MCP server it should run against. The input bar now grows to four lines as you type. Chip mutes and @ pins both reach the planner — muted apps and their MCP tools are withheld from the prompt entirely, and a single pin hard-overrides the parsed target.
- bc6a757: iOS now supports Dynamic Type: 211 fixed font sizes scale with the text-size setting, and text-bearing controls grow instead of clipping

### Patch Changes

- bc6a757: The in-app Action card now follows the Appearance setting instead of rendering dark chrome on a light Home pane
- bc6a757: Fix a "Publishing changes from within view updates" warning when the Home pane appears or is navigated away from
- bc6a757: Act command bar: render @ tags as small inline pills in the typed text (macOS), close the suggestion menu once a destination is picked, position the menu below the field instead of over it, and loosen vertical spacing on the Mac Home pane.
- bc6a757: Fix chained contact lookups dropping the email address: the planner now always inserts a get-detail step between a search and any action that consumes a detail field
- bc6a757: Fix a "Modifying state during view update" warning when accepting an @ destination in the command bar, and land the caret past the inserted tag when tagging mid-sentence
- bc6a757: Pretty-print and syntax-highlight JSON results in the Actions trace viewer, with a Raw toggle for the exact text a step returned

## 0.25.0

### Minor Changes

- Gmail suggestions via Google's official Gmail MCP server: one-tap featured Gmail connection that authenticates with your existing Google sign-in (no separate OAuth), gmail.readonly scope added (re-connect Google once to grant), inbox reads feed the proactive suggestion engine.
- Plan surfaces: a dedicated Quill Pro screen (iOS Settings) and Plan tab (macOS Settings) with the shared Free vs Pro comparison, plus a richer onboarding Connect Google step listing what the sign-in unlocks — sync, Gmail/Calendar actions, Pro suggestions. Google stays optional; the plan controls moved out of General.
- Settings simplified: macOS hides expert knobs (clipboard/paste mechanics, word corrections, per-app AI overrides, settings export/import/reset) behind one 'Show advanced settings' switch, drops the read-only Status and Keyboard Shortcuts mirror sections, and finally exposes Cloud Sync. Cloud sync failures now report the real reason instead of a bare HTTP code, and MCP auth errors no longer blame your token when the service itself is unavailable. iOS reads its version from the bundle and drops debug logging from the keychain path.
- macOS Home pane: the main window now opens to a Home tab mirroring iOS — proactive suggestions (Pro) with Review routing into the confirmation panel, plus your three most recent synced notes with one-click jump to the Notes editor.
- macOS Home becomes a doing surface: type-a-command field + Dictate button (new note, auto-starts dictation), meeting strip with NOW tag pre-titling notes, staggered suggestion cards, Connect Sources CTA, and suggestions refresh on app activation. Notes: deleting now removes cloud photos too, and missing photos download on open. Connections: Gmail is one row — compose (native) + inbox reading (MCP) with a one-click Enable. History wears the brand wash.
- iOS proactive suggestions (Pro): Quill reads your connected sources on app open and offers ready-to-run action cards — reviewed in the pre-filled confirmation sheet, never auto-executed. Plus the Dictate meeting strip, collapsed Act app summary, and the Dictate format dropdown.

### Patch Changes

- Fix hotkey capture: the key listener rode on a once-only, view-tied effect, so the first Settings tab switch killed it and nothing could re-arm it — new shortcuts silently wouldn't record. It's now scoped to the capture itself. General's shortcut summary also gets a 'Change shortcuts…' row that jumps to the editor. iOS Settings regrouped from 16 stacked sections into 8, behind five focused sub-screens.
- Suggestions page is always reachable: a lightbulb button joins the home top bar when Pro is on (the peek bar only appears when there's something to tease), and the page gains a refresh button that re-checks sources immediately, bypassing the 30-minute throttle.
- Restore the Keyboard Shortcuts summary in General (it was the only signpost to the hotkey editor) and always list Cycle Mode and Paste Last, showing 'Not set' when unassigned. Suggestion generation is no longer cancelled when you navigate away from Home mid-pass.
- Point cloud sync at a new Firestore database (quill-sync). The previous database was destroyed with the GCP project; undeleting the project restored its metadata but not its data, and Firestore permanently reserves a deleted database's ID, so the old name could not be reused.
- macOS window simplified: Home is the hub — sidebar toggle removed, Home/History show no sidebar, Home's toolbar has Notes/History/Settings icons, and every other pane gets a back-to-Home button. Settings keeps its sub-tab list and Notes its note list.
- Suggestions moved to a dedicated page: home shows a quiet one-tap peek bar (stacked source icons + count + top headline) above the renamed Recent Notes rail, and the full-screen Suggestions page hosts the inbox-style cards, empty state, and Pro upsell. Review still opens the same pre-filled confirmation sheet.
- macOS notes are cached locally: the list renders instantly on launch instead of waiting for a cloud round-trip, unsynced edits survive quitting the app, and syncs now merge (local edits that haven't uploaded are preserved and pushed, rather than being silently reverted by the incoming cloud copy).
- Suggestions now read Google Calendar events (existing scope, no re-consent), the Dictate meeting strip works for Google-only calendars, and the empty state explains that Gmail/Dex suggestions need their MCP servers instead of claiming you're caught up.
- Subscription tab (renamed from Plan) with side-by-side Free vs Pro cards and one-click plan switching; Pro removes the free connection cap and its warning on both platforms; suggestions fixed for Pro users (the AI proxy truncated long responses — truncated output no longer poisons the refresh timer, the proxy honors a larger output budget, and the prompt keeps output compact); calmer Home layout with uniform section labels and slim note rows.
- iOS note view: tap the title to rename, and the header's rename button is now the share menu (text-only or PDF).
- macOS Notes: the Edit-with-AI bar collapses to a single header line (persisted), and edits auto-sync ~7 seconds after you stop typing — no more manual Sync Now for routine edits. Home: bigger centered Actions | Notes switcher with live count bubbles (suggestions / today's meetings), the meeting strip lives in the Notes tab, and the layout breathes more.
- Suggestions no longer fail wholesale when the model invents a field — bad items are dropped, good ones survive, and failures log the raw payload. macOS Home splits into Actions | Notes sub-tabs (persisted), with the Notes tab showing eight recent notes and an All Notes shortcut.
- macOS Home polish: sidebar toggle suppressed on Home and History, and Home gains the Quill brand header — feather wordmark, time-of-day greeting, and a soft violet wash.

## 0.24.0

### Minor Changes

- 911afb6: macOS: add an Appearance control (Auto/Light/Dark) in Settings → General, matching iOS — Auto follows your Mac's system setting, and the override applies across every window (Settings, Notes, the HUD/orb).
- 911afb6: macOS: bring the iOS in-note AI editing to the Mac Notes editor — one-tap Edit chips (Shorten by 20%, Make it bullets, Summarize, Turn into email, Extract action items, More formal, Fix grammar) plus a free-form command field, with an inline red/green diff and Undo/Keep before anything is committed. Your most-used commands float to the front, and the command list is shared with iOS so both platforms stay in sync.
- d432d35: iOS: the capture sheet now has clear Pause and Stop buttons — tapping the orb to stop wasn't discoverable. Pause suspends the recording (resume to continue); Stop finishes and processes. The keyboard (type-a-command) button is hidden in Dictate mode, where typing a command doesn't apply.
- d432d35: Mac Connections pane catches up with iOS: click any row to expand its tools/actions, search filter that matches tool names, one alphabetical list, tighter rows, and the add-time OAuth probe for servers like Dex that serve their catalog anonymously

### Patch Changes

- d432d35: iOS: tapping a note in the notes list now opens the note — it used to set it active and drop you back on the home screen (a leftover from before home became a launcher). The list's compose button opens the new note too.
- 911afb6: macOS: brighten the Edit-with-AI command chips so they're legible on dark backgrounds (they were amber-on-dark and hard to read)
- d432d35: Detail lookups now chain automatically: asking for a contact's email runs the search, then fetches the full record with the found id — search tools only return summaries, so single-step lookups couldn't answer detail questions
- d432d35: iOS: copy button on every action result card, not just the extracted answer
- d432d35: iOS: fix an intermittent "No speech detected" right after recording — the audio format was read a beat too early (while the mic route was still settling), which could hand back a 0 Hz placeholder and write a silent file. The recording format is now taken from the real audio buffers, so the first take is as reliable as the retry.

## 0.23.0

### Minor Changes

- iOS: add an Appearance setting (Auto/Light/Dark) and remember the last capture mode across launches — the home rail and Settings stay in sync
- 52455cb: iOS agent parity refresh: MCP servers with OAuth sign-in, multi-step actions with dependent-step chaining and answer extraction, routines, agent memory, and Pro-plan AI routing on iPhone
- 52455cb: Branded action steps: MCP calls show their service's icon and color in the confirmation panel, offline queue, and the Mac orb's satellite ring (which now includes MCP servers with live voice targeting)
- 52455cb: One-button capture on iOS: the mic auto-routes commands to the agent (long-press to force), single and multi actions share one confirmation sheet with a parsing preview and a Save-to-note-instead undo
- Rebuild the Quill colour system on OKLCH and adopt the new mode palette on both platforms — Auto is now violet (and carries the brand hue), Dictate blue, Edit amber, Act teal
- 52455cb: Mac-consistent iOS design: shared color tokens (teal action accent, unified cards), MCP-first integrations screen, tappable markdown checkboxes in notes, pinned notes, and voice-targeted note appends (add milk to my groceries note)
- 52455cb: Siri and Action Button capture (New Quill note) plus on-device Apple Intelligence fallback for note cleanup and titles when no API key is set
- 9e00201: One unified Apps & services list on the Mac Integrations tab — native integrations and MCP-backed brands are the same kind of row (no more duplicate Notion/coming-soon entries)
- iOS: rebuild the notes list in the new design language — flat themed page, compose/close header, search field, hairline note cards
- 9e00201: Type a command: run agent actions from the keyboard — Type a Command in the Mac menu bar and a keyboard button in the iPhone capture cluster, using the same pipeline as voice (routines, memory, connections)
- 52455cb: Auto action routing on iOS: dictations that sound like commands are routed to the agent instead of the note (toggle in Settings)
- 52455cb: Unified Connections: native integrations and MCP services share one settings surface on Mac and iPhone — Notion, Linear, Dex, GitHub and more connect with one tap (browser sign-in), custom MCP servers remain for power users
- Rebuild the iOS home around the orb: a capture launcher with an Auto/Dictate/Act mode rail, a live capture sheet, and mode-as-colour throughout
- Connections: tap any row to expand its available tools and actions, filter the list with a search bar that also matches tool names, sort everything alphabetically, and tighten the rows
- Menu bar now always shows the current mode. The status item shows the mode name beside the feather/chip at all times, instead of only flashing it briefly on switch — which also removes the glitchy status-item resize that made mode-switching look janky. On top of that, every mode switch flashes a brief bubble at the top of the screen (like the macOS input-source HUD), so you always get a confirmation even when a full-screen app has hidden or is covering the menu bar (e.g. Citrix).
- 52455cb: Rich markdown note editor on iOS: live highlighting, keyboard formatting toolbar, and list auto-continuation (shared engine with the Mac notes editor)

### Patch Changes

- Fix silent data loss where a long dictation could lose everything but its final seconds — a duplicate hotkey press mid-recording restarted the take, resetting the timer and truncating the audio file. Starting a recording is now idempotent.
- Fix MCP servers that serve their tool catalog anonymously (like Dex) never prompting for OAuth sign-in — Quill now probes the server's OAuth metadata at add time and opens the browser sign-in immediately
- iOS: fix doubled Done buttons in the Connections and Custom Modes sheets
- iOS: surface note-edit failures in the composer — a failed Shorten/Make-it-bullets used to do nothing visible (missing API key errors were rendered on a screen the note detail covers)

## 0.22.0

### Minor Changes

- 913cc2e: Ask a question via an MCP tool and get the answer, not raw JSON: after a lookup like "find Joe in Dex and output his email address," the Action panel extracts the specific value you asked for and shows it in an Answer card with Copy and Paste — Paste drops it right where your cursor was
- 0e0e68f: Action mode can now open websites and launch apps by voice — "open LinkedIn in Chrome", "launch Spotify", "go to nytimes.com" — with an editable URL/app in the confirmation panel. Multi-step actions also show a correct icon for every step, including MCP tool steps (a distinct tool icon) and the new Open action (a globe), instead of a misleading placeholder
- 8f7c274: Chained Action steps: say "find Joe in Dex and then draft him a birthday email in Gmail" — a step can now consume an earlier step's result. The agent runs the lookup first, then a small resolve pass uses what it found to both fill the link (the recipient's email) and personalize the draft (greet Joe by name), so the previous step's output dynamically shapes the next

### Patch Changes

- b7e9270: MCP tool results in the Action confirmation panel are now formatted for readability — a contact lookup shows a clean name + title + location instead of a raw one-line JSON blob (works for any MCP server, drops ids/avatars/counts)
- de83152: Chained Action commands now show what happened: the confirmation panel lists each step's outcome — the contact that was looked up (name, title, email) and the email that was drafted (To, Subject, Body) — instead of a bare "2 created" that auto-dismissed before you could read it

## 0.21.0

### Minor Changes

- f3e9a77: New Chip display mode (Settings → General → Display Mode → Chip): a compact frosted chip showing the Quill feather at rest that morphs into a mode-hued orb while capturing, with a 4-bar listening meter and a Corner Bloom transcript card — a minimal, less-obtrusive alternative to the Orb
- fe72cd2: Agent memory extraction now runs on-device via Apple's Foundation Models when available (macOS 26+, Apple Intelligence) — learning from dictations is free and the transcript never leaves the Mac; falls back to the cloud provider otherwise
- 4cba3e8: Hermes agent layer: voice-authored routines with instant trigger phrases, on-device agent memory that learns people/projects/preferences from dictations, agent naming, and auto-run trust ladder
- 0c4478d: MCP servers that require a browser sign-in (OAuth) now work — Quill runs the full MCP auth flow (discovery, dynamic client registration, PKCE browser login, token refresh), so servers like Dex, Notion, and Linear can be connected, not just static-token servers
- 4cba3e8: Selection-aware Action mode: highlight text in any app and say "add this to my list" or "email this to Mike" — the agent resolves "this" to the highlighted text and files it as notes or email body
- d40c2c5: Chip display mode now lives in the menu bar per the design spec: the status item shows the Quill feather at rest and morphs into a mode-hued orb while capturing (mic meter while listening, green flash on completion), with the Corner Bloom transcript card dropping from the menu bar; the app menu gains a mode header, paste preview with shortcut, and a Mode submenu
- 423b5dc: Notes editor overhaul: dictate directly into a note (mic in the toolbar, ⌘⇧D) with an AI clean-up toggle; the editor now fills and scales with the window (no more nested scrolling, adaptive readable column); markdown lists auto-continue on Enter; numbered-list and quote formatting; placeholder for empty notes
- 6971a51: New Agent tab in Settings (agent identity, routines, learned memory, offline queue) with tinted sidebar icons; polished Notes editor (readable column width, larger type with line spacing, word count) and warmer empty states
- fe72cd2: MCP client: connect any Model Context Protocol server (Settings → Agent → Tools) and its tools become voice-invocable — Hermes lists them to the planner, shows the call on the confirmation card, and executes over Streamable HTTP with keychain-stored tokens

### Patch Changes

- ef0aa24: Fix Anthropic API key validation rejecting valid keys: the validator pinged a retired model (claude-sonnet-4-20250514) and treated the 404 as an invalid key; it now uses the app's current default model and only treats 401/403 as invalid
- b063f10: Harden Pro AI proxy: pin OAuth token audience to Quill's client ID, fail closed without an email allowlist, add per-user daily request cap and input size limit
- 35a5d4b: MCP servers in Settings → Agent → Tools can now be edited (name, URL, token), not just added and deleted — a pencil button on each row opens an edit sheet; the stored token is preserved unless you replace or remove it
- c53c943: Chip menu-bar mode: fix the feather rendering dark/invisible and pulsing to transparent on some displays (now a solid white feather on a consistent dark chip), and size the pill to fill the menu bar so it matches the system mic pill height
- 48dca74: Chip menu-bar mode: use the original brand feather, make the mode-name label white, and size the chip to match the system mic pill height
- 423b5dc: History polish: row actions reveal on hover, colored capsule mode badges, tinted stat icons
- 779254b: Make MCP tool calls reliable across servers: the planner now always gets each tool's argument names, types, and required flags (parsed from its schema) instead of dropping large schemas, so tools like Dex's contact search get their required 'query' argument
- d76b341: Surface why an action failed in the confirmation panel (instead of a silent auto-dismiss), and make MCP authentication failures explain that the server needs a token / that OAuth servers aren't supported yet
- 8f73fcf: Show the result of read/query MCP tools: the confirmation panel now displays what the tool returned (selectable) and copies it to the clipboard, instead of just showing 'Done' with no output
- b90a414: Orb display mode is far less obtrusive at rest: compact idle size with a quieter, smaller backdrop card that blooms to full size only while recording
- fec4379: Orb: cap the Action-mode satellite ring at 6 tiles with a +N overflow indicator, and ease the compact idle size back up for readability
- 80938c7: Chip display mode now shows the mode name (Dictate/Edit/Action/Auto) in the menu-bar chip for ~1.6s when you switch modes with the hotkey, so you always know which mode you're in
- 18f2edf: MCP tool output in the confirmation panel now has an explicit Copy button instead of auto-copying to the clipboard
- 4cba3e8: Fix iOS build broken by macOS-only Pro-plan imports in shared AIProcessingClient; route Action-mode parsing through the Pro proxy for Pro users
- b90a414: History: date-grouped transcript list, collapsible long transcripts with text selection, debounced search, and cached app icons for smooth scrolling
- 46d55d2: Fix the Chip menu-bar pill not filling the menu-bar height (it was hugging the glyph's intrinsic size); the pill now fills the bar like the system mic pill and ChipSpec.chipVMargin controls its height
- f1c90e5: Stop the macOS keychain password prompts on rebuild: secrets now use the Data Protection keychain (no prompts) with a transparent one-time migration from the legacy keychain, so existing API keys and tokens are preserved

## 0.20.0

### Minor Changes

- Add Pro plan with bundled AI Enhancement — Pro users get Anthropic-powered formatting without supplying their own API key (routed through a server-side proxy when signed in with Google)

### Patch Changes

- Add opt-in usage analytics: per-user usage snapshots sync to the cloud so engagement can be reviewed (no transcript content is uploaded)
- Fix dictation in Citrix (and other VDI) sessions getting hijacked by the inline-edit AI. VDI clients are now identified by vendor bundle-ID fragment (citrix, vmware.horizon, parallels.desktop, microsoft.rdc) so the actual Citrix Viewer session window is recognized regardless of version or rebrand, and the Cmd+C clipboard selection-capture fallback only runs in VDI apps when the user is in explicit Edit mode. Previously, Citrix's networked clipboard produced a false-positive "selection" during plain dictation, routing the transcript through the inline-edit path so the model replied conversationally instead of pasting the dictation.

## 0.19.0

### Minor Changes

- Add usage stats dashboard to History tab showing words transcribed, dictation/edit/action counts, and estimated time saved. Save edit and action transcriptions to history alongside dictations.

## 0.18.0

### Minor Changes

- Add Auto mode — a fourth mode (Auto → Dictate → Edit → Action) that auto-detects intent from voice transcripts using keyword matching, routing to Edit when text is highlighted with edit commands, Action for task/reminder keywords, and Dictate by default

### Patch Changes

- Compact orb idle layout — narrower at rest with caption closer to the orb, expanding both horizontally and vertically when recording starts

## 0.17.0

### Minor Changes

- Add Act-mode satellite ring to the Orb display — connected integrations appear as tappable tiles around the orb, with live AI-driven target highlighting from partial transcript and click-to-lock override

## 0.16.0

### Minor Changes

- Add Orb display mode — an alternative floating HUD that renders a luminous sphere with mode-encoded color, audio-reactive animations, and orbiting particles

## 0.15.0

### Minor Changes

- Fix Edit mode routing: resolve race condition where Parakeet's fast transcription (0.07s) beat clipboard selection capture, causing raw dictation text to be pasted instead of AI-processed edits

### Patch Changes

- Fix frozen input in Citrix/RDP after dictation: clear stuck modifier keys by posting an empty flagsChanged event after every CGEvent key sequence
- Add API key validation in Settings: real-time 'Key verified' / 'Invalid key' indicator, auto-trim whitespace from pasted keys, and guard Edit/Action modes against missing keys with clear HUD feedback

## 0.14.0

### Minor Changes

- Settings overhaul: consolidated 6→4 tabs, unified Formatting Modes, Notes pane with search/new-note/cloud-sync/markdown-editor, in-memory OAuth token cache to eliminate keychain prompts

## 0.13.0

### Minor Changes

- 4fc1f58: Add multi-action mode: voice commands with multiple actions (e.g. 'remind me to buy milk and schedule a meeting tomorrow at 2pm') are now parsed into separate items, each shown as an editable card in the confirmation panel. Supports independent execution with per-item success/failure tracking on both macOS and iOS.

### Patch Changes

- 3eb9989: Add per-app clipboard paste delay for remote desktop apps like Citrix, RDP, and VMware
- 3eb9989: Configure Sparkle auto-updates with EdDSA signing and appcast feed URL

## 0.12.1

### Patch Changes

- bc555a4: Fix stale transcription from previous session being pasted when recordings overlap

## 0.12.0

### Minor Changes

- a9eb5b3: Cloud Sync via GCP/Firestore: cross-device notes (iOS↔Mac), photo sync via Cloud Storage, tombstone-based deletes, iOS note editing, and macOS Notes viewer. Opt-in via Settings → Cloud Sync; requires connected Google account.
- be6c4c7: iOS confirmation sheet now opens during action parsing (transcript visible while AI works), completion badges deep-link to the integration's app, and macOS Settings → AI gains a per-app overrides list (always-honored rules that beat the default mode and the auto-select toggle).

### Patch Changes

- f60fec2: iOS task confirmation now matches macOS panel (HEARD/WILL DO sections + integration chip selector + dark-mode aware) and both platforms show a completion badge before dismissing.
- 534624f: Cloud Sync hardening: fix GCS path encoding (download/delete now work cross-device), debounce per-note uploads to prevent racing PATCHes, use stable per-install device ID, clean up orphaned photos when bodies are edited, and trigger sync on scenePhase active rather than at launch.

## 0.11.0

### Minor Changes

- Live transcript HUD card via on-device speech recognition, redesigned Action confirmation panel (HEARD/WILL DO), and HUD integration picker with fn+1..fn+9 hard-lock shortcuts in Action mode

## 0.8.0

### Minor Changes

- c9c12db: iOS: AI analyzes each attached photo — summary, key details, and transcribed text land as a card under the photo and in PDF exports
- c9c12db: iOS: add inline photos to notes — tap camera to insert a photo between dictations (groundwork for AI photo summaries)
- c0c195a: iOS Action mode (Reminders, Calendar, Todoist, Gmail, Google Calendar) with offline queue + waveform recording state + Ready-when-you-are home, Google sign-in via OAuth+PKCE on both platforms, error monitoring infrastructure (opt-in Sentry), keyword search across iOS notes + macOS history, redesigned iOS FAB cluster (single + that fans up to dictate/photo/action), date-parser fix for 'tomorrow morning at 2pm'-style phrasing.
- 99ea885: iOS: proper bullet/heading rendering, expanded note canvas, delete from main screen
- d221e9c: Inline voice commands: 'period', 'comma', 'new paragraph', etc. now work mid-sentence (not just as standalone utterances). macOS + iOS; toggleable in Settings.
- 89a1426: iOS + Mac: Custom AI modes (user-authored prompts), Mac Inline Edit commands (voice-driven in-place editing of selected text), Integrations surface (Todoist/Reminders/Notion/Things/Slack/Linear placeholders), iOS home-screen widget source + setup guide.
- c9c12db: iOS: editable note titles + export note as PDF (text + inline photos)
- a1f1329: **Action mode is live.** The third HUD pill (Dictate → Edit → Action) now turns voice commands into real tasks. Speak "Add to Todoist write email to Mike" or "Remind me to review the launch deck on Friday" and a confirmation panel drops down from the menu bar with editable fields — title, due date, list/project, priority — that you can tweak before clicking Create.

  - **Apple Reminders** is built in (no setup; uses EventKit).
  - **Todoist** is the first third-party adapter — paste your API token in Settings → Integrations → Connect (validates against `/api/v1/projects` before saving to Keychain).
  - **The LLM picks the integration from voice context** ("to Todoist", "remind me", etc.) and strips the integration phrase from the title. You can override the pick from the panel before submitting.
  - Per-integration UI: Reminders shows List + Notes; Todoist adds Project + P1–P4 priority.

  **Mode-cycle hotkey.** A second global shortcut (Settings → Recording → Hot Key → Cycle Mode) cycles the HUD pill between Dictate / Edit / Action without triggering a recording.

  **UX polish.**

  - Edit mode now shows a single Undo chip after an inline edit, auto-dismissing after 8s (the Keep button is gone — the edit auto-commits silently).
  - The Settings/History sidebar toggle now uses your system accent color instead of the old purple.
  - The volume slider in Settings → General slides out smoothly when Sound Effects is toggled off.
  - "Highlight text first" chip now fires when you trigger Edit mode without a selection — recording is cancelled instead of pasting your instruction as literal text.

  **Security & store readiness.**

  - Privacy manifests (`PrivacyInfo.xcprivacy`) shipped for both targets — required for App Store submission.
  - ATS is no longer disabled globally; Quill relies on default macOS HTTPS enforcement.
  - iOS clients now use `os.log` with `, privacy: .private` annotations everywhere transcript text could leak (was previously logging the first 400 chars of every API response via `print()`).
  - AppleScript paste-fallback escaping now handles backslashes in addition to quotes.

### Patch Changes

- 1c545cc: AI post-processing no longer treats the transcript as a conversation — wraps user content in <transcript> tags and falls back to raw text when the model still refuses. Also fixes Email mode emitting a literal "<Your name>" placeholder.
- 55c777e: macOS: paste reliably lands in the app you were dictating into. Reactivates the source app before pasting, refuses to paste into Quill itself, and always syncs the clipboard to the transcription so manual Cmd+V fallback always gives you what you just said.
- d221e9c: macOS: fix 'pastes old clipboard instead of transcription' race — bumped clipboard restore delay from 500ms to 1.5s and skip restore if clipboard changed in the interim.
- c9c12db: Fix iOS keychain read: API keys saved in Settings weren't being found by photo analysis (kSecAttrAccessible shouldn't be in lookup queries)
- 3afb124: AI post-processing is now strictly cleanup-only — never invents greetings, closings, names, or signatures. Email mode in particular no longer prepends 'Hi,' or appends 'Best,' / 'Thanks,' / a name unless the speaker dictated them.
- 713b9f7: macOS: fix unreliable paste — AX-insertion now verifies the text actually landed (some Electron / custom inputs silently drop the set), and the whole paste flow checks Accessibility permission upfront so when it's missing the text is left in the clipboard with a clear log message instead of vanishing.
- 350a124: macOS: never paste the wrong content. Switched primary paste path to Accessibility-based text insertion (bypasses the clipboard entirely), and flipped the clipboard-restore default so we don't race against slow paste handlers. Fixes a bug where a previously-copied API key could be pasted instead of the transcription.
- da470e2: macOS: fix blank menu bar icon (SF Symbol 'feather' doesn't exist — ship a real template NSImage built from the Feather asset)
- c0c195a: Settings reorganization: Recording tab is now the comprehensive recording hub (model, mic, hotkeys, during-recording behavior, output, history). General tab slimmed to permissions + sound + app toggles. AI tab restructured into Provider / Default Mode / Behavior subsections. Sidebar gets a min-width and slightly polished pill toggle so Settings/History buttons no longer get crushed at narrow widths.
- b78f049: Stop priming the sound-effects audio engine when sound effects are disabled so Hex avoids unnecessary background audio activity and sleep assertions (#200).

## 0.9.0

### New

- **Action mode is live.** The third HUD pill (Dictate → Edit → Action) now turns voice commands into real tasks. Speak "Add to Todoist write email to Mike" or "Remind me to review the launch deck on Friday" and a confirmation panel drops down from the menu bar with editable fields — title, due date, list/project, priority — that you can tweak before clicking Create. The LLM picks the integration from your voice context ("to Todoist", "remind me", etc.) and strips the integration phrase from the title, so the Title field reads "Write email to Mike" rather than the full transcript.
- **Apple Reminders integration.** Built-in, no setup. Uses EventKit with the new `com.apple.security.personal-information.calendars` entitlement and `NSRemindersUsageDescription`.
- **Todoist integration.** Settings → Integrations → Connect on the Todoist row prompts for an API token (get one at todoist.com → Settings → Integrations → Developer). Token validates against `GET /api/v1/projects` before saving to the Keychain. Per-integration UI: Reminders shows List + Notes; Todoist adds Project + P1–P4 priority and uses Todoist's natural-language `due_string` so "next Friday at 3pm" works without local date parsing.
- **Override the LLM's pick.** When 2+ integrations are connected, the confirmation panel header becomes a dropdown — pick the integration before submitting and the field set + list/project picker refresh accordingly.
- **Mode-cycle hotkey.** A second global shortcut (Settings → Recording → Hot Key → Cycle Mode) cycles the HUD pill between Dictate / Edit / Action without triggering a recording. Useful if your recording hotkey is a single modifier and you want to switch modes from the keyboard.

### UX

- **Edit mode: single Undo chip.** After an inline edit lands, only an Undo button is shown (the green Keep button is gone — the edit auto-commits silently after 8 seconds).
- **Edit mode: "Highlight text first" chip.** If you trigger Edit mode without a text selection in the focused app, the chip appears, recording is cancelled, and the cancel sound plays. Previously the dictation was pasted as literal text into the wrong place.
- **Sidebar Settings/History toggle** now uses your system accent color instead of the old purple gradient — harmonizes with the sidebar's default selection styling.
- **Volume slider in General settings** now slides out smoothly when Sound Effects is toggled off (replaces the disabled-but-still-visible slider).

### Security & store readiness

- **Privacy manifests** (`PrivacyInfo.xcprivacy`) shipped for both macOS and iOS — declares UserDefaults + file-timestamp API usage. Required for App Store submission on iOS 17+.
- **App Transport Security**: removed the `NSAllowsArbitraryLoads` override; Quill now relies on default macOS HTTPS enforcement.
- **iOS clients no longer leak transcripts to system logs.** `TextAIClient.swift`, `PhotoAnalysisClient.swift`, and `KeychainStore.swift` now use `os.log` with `, privacy: .private` annotations on anything that could contain transcript text or PII (the previous code logged the first 400 chars of every API response via `print()`).
- **AppleScript paste-fallback** now escapes backslashes in addition to quotes — prevents malformed scripts when a transcription contains either character.

### Internal

- New TCA reducer `ActionConfirmationFeature` and dependency clients `ActionParsingClient`, `RemindersAdapter`, `TodoistAdapter`.
- `ActionConfirmationPanel` is a key-capable `NSPanel` anchored below the menu bar (separate from the non-activating HUD).
- New `cycleModeHotkey: HotKey?` field on `HexSettings` with a fully-wired schema entry; `AppFeature.startCycleModeHotKeyMonitoring()` mirrors the data-race-safe pattern used for the existing paste-last-transcript hotkey.

## 0.8.7

### Fixes

- **macOS: paste reliably lands in the right app, every time.** The remaining unreliability — "sometimes my transcription shows up, sometimes I paste my previous clipboard" — traced to three compounding bugs:
  1. The paste targeted _whichever app was frontmost when transcription finished_, not the app the user was dictating into. If you Cmd-Tabbed away while Whisper or AI post-processing was running (1–3 seconds), the paste landed in the wrong window.
  2. The Accessibility-insertion path bypasses the clipboard entirely, so if AX landed in the wrong element and you tried to `Cmd+V` manually in your actual target, you pasted whatever was in the clipboard _before_ Quill ran (API keys, etc.).
  3. Nothing stopped a paste from writing into Quill's own Settings / History window.
- **Fix:** Quill now remembers which app you started recording in and reactivates it before pasting (with a short settle-time for focus to update), refuses to paste into itself, and after every successful paste syncs the transcription into the clipboard — so manual `Cmd+V` fallback always gives you the dictation, never stale content.

## 0.8.6

### Fixes

- **macOS: paste is now reliable** (follow-up to the 0.8.5 Accessibility switch).
  - Some apps (certain Electron inputs, custom-drawn text fields) were accepting our AX insert call without actually applying it — the paste appeared to succeed but nothing showed up. The AX path now reads the element's value before and after the insert and falls through to the clipboard path if nothing changed.
  - Accessibility permission is now checked **once** at the start of the paste flow. When it's missing, both the AX-insertion path and the Cmd+V injection path are known to silently fail, so Quill skips them and simply leaves the transcription in the clipboard with a clear log line ("Accessibility permission not granted — user must press Cmd+V manually"). No more disappearing dictations.
  - The clipboard-restore step is also skipped when permission is missing, so your transcription stays in the clipboard instead of being overwritten by your previous contents after a failed auto-paste.

## 0.8.5

### Fixes

- **macOS: never paste the wrong content.** A race in the clipboard-paste path could result in Quill pasting whatever you previously had in your clipboard (e.g. an API key) instead of your transcription when the target app was slow to process `Cmd+V`. Two changes make this foolproof:
  1. The primary paste path is now **Accessibility-based text insertion** — Quill writes the transcription directly into the focused text field via `AXUIElementSetAttributeValue`, which never touches the clipboard. Works in all browsers, native AppKit apps, and most Electron apps.
  2. When the fallback clipboard path does run, the default is now to **keep the transcription in the clipboard** rather than race to restore your previous clipboard. If you want the old behavior (restore previous clipboard), toggle "Copy to Clipboard" off in Settings — but that path no longer puts you at risk of pasting stale content, because it also bumps the restore delay to 3 s and verifies the clipboard wasn't stomped in the interim.

## 0.8.4

### Fixes

- **AI modes no longer invent content.** The post-processor was adding greetings, closings, and signatures the speaker never dictated — e.g. `"Please suggest times for next week"` came back wrapped in a `Hi,` / `Best,\nJoe` template. Every mode is now strictly cleanup-only: grammar, punctuation, paragraphing, and (for Notes) bullet formatting. Greetings like `Hi Amanda,` and closings like `Best,` are only emitted when the speaker actually dictated them. Two explicit examples in the system prompt show what NOT to do.

## 0.8.3

### Fixes

- **AI no longer answers questions in your dictation.** If you dictated "Do you have an interest in joining for an introduction call?", some modes would respond as the AI ("I am a text post-processor, I cannot join calls…") instead of just punctuating the question. The user message is now wrapped in `<transcript>` tags that the system prompt treats as data, with a concrete example showing that questions inside should be punctuated, not answered. As a safety net, obvious refusal responses ("I am a…", "I cannot…", "As an AI…") are detected and the raw transcript is used instead so no dictation is ever lost.
- **Email mode no longer emits `<Your name>`.** The closing used to include a literal placeholder; it now ends at `Best,` and lets you type your own signature. Also stops emitting other angle-bracketed placeholders like `<recipient-name>` / `<subject>`.

## 0.8.2

### New

- **Inline voice commands.** Phrases like `period`, `comma`, `question mark`, `colon`, `semicolon`, `new paragraph`, `new line`, and `full stop` are now converted to punctuation and line breaks _mid-sentence_ — not only when spoken alone. So "hello comma world period new paragraph welcome" becomes `Hello, world.\n\nWelcome` before AI post-processing runs. Standalone `undo`, `redo`, and `select all` still trigger the corresponding editor commands. Toggleable under Settings → AI Enhancement → Voice Commands.

### Fixes

- **Paste reliability.** Fixed a race where releasing the record hotkey in a slow-to-respond app (Chrome, Arc, Slack, Electron apps, first paste after launch) could paste your _previous_ clipboard contents instead of the transcription. The clipboard restore now waits 1.5 s instead of 500 ms and skips the restore entirely if anything else has written to the clipboard in the meantime.

## 0.8.1

### Fixes

- **Menu bar icon restored.** The blank slot some users saw in the menu bar was caused by a reference to an SF Symbol (`feather`) that doesn't exist in Apple's catalog, so the label rendered nothing. The menu bar now uses the same white-feather asset as the app icon, drawn as a proper template `NSImage` so it auto-tints for light and dark menu bars.
- Stop priming the sound-effects audio engine when sound effects are disabled so Quill avoids unnecessary background audio activity and sleep assertions (#200).

## 0.8.0 — Quill

Quill is a rebrand of Hex under new stewardship — same on-device dictation, new name, and a meaningful new capability set.

### Rebrand

- Project renamed from **Hex** to **Quill**; new bundle identifier `com.joevasquez.Quill`, new menu bar icon (feather), updated copyright and About screen. Existing Hex users see Quill as a separate app with its own settings.

### New features

- **AI post-processing** — transform transcripts with OpenAI or Anthropic using one of six modes: Clean (grammar + punctuation), Email, Notes (bullets), Message (casual), Code (comments/docs), or Off. Bring your own API key; stored in the macOS Keychain.
- **Context-aware mode selection** — per-app rules assign a default AI mode based on the frontmost app (e.g. Mail → Email, Slack → Message, VS Code → Code). Configurable in Settings.
- **Voice commands** — phrases like "new paragraph", "period", "select all", and "undo" are detected inline and executed as editing commands instead of being pasted as text.
- **File transcription** — drag audio or video files into the History view to transcribe them to text.
- **Quill iOS companion app** — standalone iOS app for voice notes on the go. Records on-device with Whisper, optional AI clean-up, share via iOS share sheet. Not bundled with this macOS release.

### Fixes

- Fixed a crash when saving an API key to the Keychain.
- Fixed Swift 6 concurrency warnings across the macOS target (reduced lock contention on the hotkey hot path).
- Added watchdog instrumentation to the global hotkey event tap — if a handler ever stalls the tap, a diagnostic log line now identifies which handler instead of silently freezing input.

### Under the hood

- `HexCore` package is now cross-platform (macOS + iOS). macOS-only clients gated with `#if os(macOS)`.
- Menu bar icon rendered as an SF Symbol template so it respects light/dark menu bar tinting automatically.

## 0.7.3

### Patch Changes

- 7340d1e: Restore double-tap lock audio capture (#193)

## 0.7.2

### Patch Changes

- 55249a6: Keep the ends of recordings from getting clipped in super fast mode.
- d9e40cc: Use the capture engine for normal recordings to reduce startup drift
- d9e40cc: Keep the microphone picker visible and refresh it when audio devices change

## 0.7.1

### Patch Changes

- ed69836: Suppress startup windows when Hex launches as a hidden login item (#146)

## 0.7.0

### Minor Changes

- c5d5162: Add Super Fast mode to keep the mic warm and prepend a short in-memory buffer

## 0.6.10

### Patch Changes

- c018c40: Add setting to disable double-tap lock for hands-free recording
- 7af7cd9: Update dependencies: TCA 1.23, Sparkle 2.8, swift-dependencies 1.11

## 0.6.9

### Patch Changes

- 74893ab: Support escape sequences (\n, \t, \\) in word remappings for newlines, tabs, and literal backslashes (#140)

## 0.6.8

### Patch Changes

- e2000d8: Fix Icon Composer app icon not displaying (#148)
- 75bc323: Update macOS Tahoe app icon (#145)

## 0.6.7

### Patch Changes

- cc99650: Prepare release metadata for 0.6.6

## 0.6.6

### Patch Changes

- 3b6c966: Improve transcript modifications layout and remove log export settings
- 3b6c966: Add opt-in regex word removals for transcripts (#121)

## 0.6.5

### Patch Changes

- 140c205: Fix Sparkle auto-update for sandboxed app by adding required XPC entitlements and SUEnableInstallerLauncherService. Users on 0.6.3 will need to manually download this update.

## 0.6.4

### Patch Changes

- c00f79e: Reduce code duplication: add ModelPatternMatcher, FileManager helpers, settingsCaption style, notification constants, and Core Audio helper
- 658a755: Fix silent recordings caused by device-level microphone mute - automatically detects and fixes muted input devices before recording

## 0.6.3

### Patch Changes

- b4c54ce: Fix microphone priming and media pause races
- 5217d3f: Add word remappings and remove LLM UI (#000)
- 4d38708: Add persistent MCP config editing for Claude Code modes
- bbd0b80: Show system default mic name in picker
- bbd0b80: Fix Parakeet polling cleanup and organize paste flow
- 3413d68: Rename Transformations tab to Modes
- 4d38708: Fix microphone freezing and speech cutoff when using custom microphone. Only switch input device when actually needed, re-prime recorder after device changes, and add cleanup on app termination.

## 0.6.2

### Patch Changes

- 7e325ad: Fix Sequoia hotkey deadlock by removing Input Monitoring guard that prevented CGEventTap creation. Tap creation triggers permission prompt naturally. Re-add 'force quit Hex now' voice escape hatch from v0.5.8 (#122 #124)
- 7e325ad: Add missing-model callout and focus settings when transcription starts without a model

## 0.6.0

### Patch Changes

- 3bf2fb0: Fix voice prefix matching with punctuation - now strips punctuation (.,;:!?) when matching prefixes

## 0.5.13

### Patch Changes

- 083513c: Add comprehensive documentation to HotKeyProcessor and extract magic numbers into named constants (HexCoreConstants)

## 0.5.12

### Patch Changes

- 471310c: Fix Input Monitoring permission enforcement for hotkey reliability

## 0.5.11

### Patch Changes

- 1deda2a: Route Advanced → Export Logs through the new swift-log diagnostics file so Sequoia permission bugs (#122 #124) can be diagnosed locally without relying on macOS unified logs.

## 0.5.10

### Patch Changes

- 3560bdb: Keep hotkeys alive on Sequoia and add voice force-quit plus Advanced log export (#122 #124)

## 0.5.9

### Patch Changes

- 6c2f1bd: Add comprehensive permissions logging for improved debugging and log export support

## 0.5.8

### Patch Changes

- 03b81c7: Let the hotkey tap start even when Input Monitoring is missing so Sequoia users get prompts again, while keeping the accessibility watchdog (#122 #124). Add a spoken “force quit Hex now” escape hatch in case permissions clobber input.

## 0.5.7

### Patch Changes

- 539b0a4: Pad sub-1.5s Parakeet recordings so FluidAudio accepts them

## 0.5.6

### Patch Changes

- a1eb1d0: Restore hotkeys when Input Monitoring permission is missing (#122, #124)
- 1ee452a: Add non-interactive changeset creation for AI agents
- 68475f5: Fix clipboard restore timing for slow apps – increased delay from 100ms to 500ms to prevent paste failures in apps that read clipboard asynchronously

## 0.5.5

### Patch Changes

- 0045f28: Fix recording chime latency by switching to AVAudioEngine with pre-loaded buffers
- 7f6c5db: Actually request macOS Input Monitoring permission when installing the key event tap so Sequoia users can record hotkeys again (#122, #124).

## 0.5.4

### Patch Changes

- Fix hotkey monitoring on macOS Sequoia 15.7.1 by properly handling Input Monitoring permissions (#122, #124)

## 0.5.3

### Patch Changes

- Fix Sparkle update delivery by regenerating appcast with correct bundle versions and updating release tooling to prevent duplicate CFBundleVersion issues

## 0.5.2

### Patch Changes

- Fix Sparkle update delivery by regenerating appcast with correct bundle versions and updating release tooling to prevent duplicate CFBundleVersion issues

## 0.5.1

### Patch Changes

- Fix Sparkle appcast generation by cleaning duplicate bundle versions and updating release pipeline to preserve last 3 DMGs for delta generation

## 0.5.0

### Minor Changes

- 049592c: Add support for multiple Parakeet model variants: choose between English-only (v2) or multilingual (v3) based on your transcription needs.

### Patch Changes

- aca9ad5: Fix microphone access retained when recording canceled with ESC (#117)
- 049592c: Polish paste-last-transcript hotkey UI with improved layout and clearer instructions.
- 049592c: Improve hotkey reliability with accessibility trust monitoring and automatic recovery from tap disabled events (#89, #81, #87).
- 049592c: Improve media pausing reliability by using MediaRemote API instead of simulated keyboard events.
- 049592c: Fix menu bar rendering issue where items appeared as single embedded view instead of separate clickable menu items.
- 1b9bd52: Optimize recorder startup by keeping AVAudioRecorder primed between sessions, eliminating ~500ms latency for successive recordings
- 55fb4f8: Add a sound effects volume slider beneath the toggle so users can fine-tune feedback relative to the existing 20% baseline, keeping 100% at the legacy loudness (#000).

## 0.4.0

### Minor Changes

- e50478d: Add Parakeet TDT v3 plus the first-run model bootstrap, faster recording pipeline, and solid Fn/modifier hotkeys so the next release captures all of the recent feature work (#71, #97, #113, #89, #81, #87).

### Patch Changes

- ea42b5b: Move `HexSettings` + `RecordingAudioBehavior` into HexCore and add fixtures/tests so we can migrate historic settings blobs safely before shipping new media-ducking options.
- e50478d: Adopt Changesets for SemVer + changelog management, wire release.ts to fail without pending fragments, and sync the aggregated release notes into the bundled changelog + GitHub releases.
- 2fbbe7a: Wait for NSPasteboard changeCount to advance before pasting so panel apps always receive the latest transcript (#69, #42).

All notable changes to Hex are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Added NVIDIA Parakeet TDT v3 support with a redesigned model manager so you can swap between Parakeet and curated Whisper variants without juggling files (#71).
- Added first-run model bootstrap: Hex now automatically downloads the recommended model, shows progress/cancel controls, and prevents transcription from starting until a model is ready (#97).
- Added a global hotkey to paste the last transcript plus contextual actions to cancel or delete model downloads directly from Settings, making recovery workflows faster.

### Improved

- Model downloads now surface the failing host/domain in their error message so DNS or network issues are easier to debug (#112).
- Recording starts ~200–700 ms faster: start sounds play immediately, media pausing runs off the main actor, and transcription errors skip the extra cancel chime for less audio clutter (#113).
- The transcription overlay tracks the active window so UI hints stay anchored to whichever app currently has focus.
- HexSettings now lives inside HexCore with fixture-based migration tests, giving us a single source of truth for future settings changes.

### Fixed

- Printable-key hotkeys (for example `⌘+'`) can now trigger short recordings just like modifier-only chords, so quick phrases aren’t discarded anymore (#113).
- Fn and other modifier-only hotkeys respect left/right side selection, ignore phantom arrow events, and stop firing when combined with other keys, resolving long-standing regressions (#89, #81, #87).
- Paste reliability: Hex now waits for the clipboard write to commit before firing ⌘V, so panel apps like Alfred, Raycast, and IntelliBar always receive the latest transcript instead of the previous clipboard contents (#69, #42).

## 1.4

### Patch Changes

- Bump version for stable release

## 0.1.33

### Added

- Add copy to clipboard option
- Add support for complete keyboard shortcuts
- Add indication for model prewarming

### Fixed

- Fix issue with Hex showing in Mission Control and Cmd+Tab
- Improve paste behavior when text input fails
- Rework audio pausing logic to make it more reliable

## 0.1.26

### Added

- Add changelog
- Add option to set minimum record time
