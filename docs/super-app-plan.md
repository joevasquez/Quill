# Quill Super-App Plan — Security, Performance, Accounts, and the Granola-Inspired Roadmap

_Drafted 2026-07-04. Source: full-code security audit, performance audit, and Granola competitive research._

> **Build status 2026-07-06:** Shipped in working tree — proxy hardening (audience pinning, fail-closed allowlist, daily cap; **needs redeploy with `ALLOWED_EMAILS` set**), Routines (voice-authored + trigger fast-path + auto-run trust ladder), agent memory v1 (local-first extraction → planner context injection), agent naming, Settings → General agent section, Pro-proxy routing for Action parsing, and a fix for the iOS build broken at HEAD. Both platforms build; HexCore tests pass. Still open: GCP IAM verification (Joe), accounts/Firebase Auth (Phase 1), performance sprint (Phase 2), mined routine suggestions + MCP client (Phases C/D).

## Where Quill stands today

Strong foundation: on-device ASR (Parakeet/Whisper), four-mode HUD (Auto/Dictate/Edit/Action), five working integrations, cross-device notes sync, offline action queue, Pro plan plumbing, usage analytics. The two structural gaps are (1) **identity** — everything is keyed off a raw Google OAuth token and a client-controlled email string, and (2) **no server-side trust boundary** — the clients talk directly to Firestore/GCS/the AI proxy with nothing enforcing who-can-touch-what. The account system requested below is not just a feature; it is the fix for the worst security findings.

---

## Part 1 — Security findings (fix before wider distribution)

### CRITICAL

**C1. The AI proxy is an open Anthropic-spending endpoint.**
`tools/cloud-functions/quill-ai-proxy/index.js:44-69` validates the caller by hitting Google's `userinfo` endpoint — which accepts *any* valid Google access token from *any* app. Combined with `--allow-unauthenticated` (deploy.sh:44), CORS `*`, optional `ALLOWED_EMAILS`, and no rate limiting, anyone with any Google account can spend the server-side Anthropic budget.
*Fix:* verify token audience via `oauth2.googleapis.com/tokeninfo` (`aud` must equal Quill's OAuth client ID); make the allowlist/entitlement check mandatory; add per-user daily token caps. Superseded properly by Firebase Auth in Phase 1 (proxy verifies a Firebase ID token instead).

**C2. Pro is a client-side flag.**
`AIProcessingClient.swift:122-127` — `selectedPlan == "pro"` in local settings is the only gate. Anyone can edit `hex_settings.json` and route through the proxy. *Fix:* server-side entitlement doc (`users/{uid}/entitlement`) writable only by admin; proxy checks it.

### HIGH

**H1. No server-side tenant isolation for cloud sync.**
`FirestoreClient.swift` / `CloudStorageClient.swift` send the user's own OAuth token (project-wide `datastore` + `devstorage.read_write` scopes) straight to the REST APIs; the `users/{sanitizedEmail}/...` path is fully client-controlled. Firestore Security Rules do NOT apply to IAM-authenticated REST calls. If project access was granted via `allAuthenticatedUsers` (the only way arbitrary users get in without per-user provisioning), **every user can read/overwrite every other user's notes, transcripts, and photos** by editing the email in the path.
*Immediate action:* run `gcloud projects get-iam-policy quill-495210` and `gcloud storage buckets get-iam-policy gs://quill-49521-notes` (gcloud not installed on the dev machine — check the Cloud Console). If `allUsers`/`allAuthenticatedUsers` appears anywhere, remove it now.
*Real fix:* Phase 1 — Firebase Auth ID tokens + Firestore/Storage Security Rules.

**H2. Email sanitizer collides.** `a.b@x.com` and `a_b@x.com` → same doc path (`FirestoreClient.swift:302-305`). *Fix:* key by Firebase `uid` (Phase 1).

**H3. `disable-library-validation` ships in Release.** Needed for Sparkle XPC + Inject, but widens dylib-injection surface. *Fix:* try gating to Debug (Inject is debug-only); verify Sparkle still works, else document the residual risk.

### MEDIUM

- **M1.** Analytics rides the same unenforced Firestore path — inherits H1's fix.
- **M2.** ~20 `print()` statements on iOS (NotesStore, SettingsView, ContentView) bypass `HexLog` privacy annotations. Mechanical cleanup.
- **M3.** Transcripts/notes/queued actions stored as plaintext JSON. Acceptable for local-first, but add `FileProtectionType.complete` on iOS and document it.

### Confirmed-good
Keychain accessibility (`WhenUnlockedThisDeviceOnly`, no iCloud sync), PKCE with no client secret in source, narrow Gmail/Calendar scopes, no secrets or token logging found.

---

## Part 2 — Performance findings

Top five by user impact (full details from the audit inline):

1. **Prewarm the transcription model.** The model loads lazily inside `transcribe()` (`TranscriptionClient.swift:234, 248-257`) — the first dictation of the day stalls for the multi-second Core ML load *after* the user finishes speaking. Fire a prewarm effect at launch (once `ensureSelectedModelReadiness` confirms disk availability) and again at record-start (the recording window is free loading time).
2. **Idle Orb animations burn CPU all day.** In Orb mode the always-visible HUD runs 8+ `repeatForever` animations over a blurred, shadowed layer even when idle (`OrbView.swift:586-611, 721-802`). Pause animations after idle timeout / display sleep / occlusion. Also: draw the 44-bar meter ring in a single `Canvas` instead of 44 views.
3. **History storage doesn't scale.** `maxHistoryEntries` defaults to unlimited; whole-history JSON is re-encoded per dictation; float WAVs (~3.8 MB/min) accumulate forever. Ship a default cap (~1000), batch prune deletions, and consider AAC for retained audio. Debounce HistoryView search and memoize per-row NSWorkspace icon lookups (`HistoryFeature.swift:310-313, 425-434`).
4. **Cloud sync is O(everything).** `fullSync` fetches every doc every time and uploads serially one request per note (`CloudSyncManager.swift:174-194`). Add `where updatedAt > lastSyncCursor` structured queries + Firestore `batchWrite` (500/req) or bounded task-group concurrency. Fix O(n²) merge matching with dictionaries. On iOS, merge all cloud notes then `save()` once (currently one full-file rewrite + widget reload *per note*, `NotesStore.swift:383-386, 588`).
5. **Paste before persist.** `finalizeRecordingAndStoreTranscript` awaits history save (incl. synchronous WAV move) before `pasteboard.paste` (`TranscriptionFeature.swift:1434-1455`). Reorder — free latency on every dictation.

Also queued: KeychainClient in-memory cache (same pattern as GoogleOAuthClient's TokenCache — removes an IPC round-trip per Edit/Action dictation), unload the non-selected ASR engine on model switch + respond to memory pressure (Whisper Large + Parakeet can be co-resident today, ~4 GB), drop `.prettyPrinted/.sortedKeys` from iOS notes encoder, debounce widget snapshot reloads, delete dead `startLiveTranscriptionEffect`.

---

## Part 3 — Accounts (Phase 1, the linchpin)

**Recommendation: Google Identity Platform (Firebase Auth) via REST — no Firebase SDK.**

Why this and not rolling our own or adding the SDK:
- It lives in the existing GCP project (`quill-495210`), supports **email/password + Google sign-in + Sign in with Apple** out of the box, and issues **ID tokens (JWTs)** that Firestore and Firebase Storage accept directly — which finally makes **Security Rules enforceable**, killing H1/H2/C2 in one move.
- It has a complete REST API (`identitytoolkit.googleapis.com` for sign-up/sign-in/IdP exchange, `securetoken.googleapis.com` for refresh), matching Quill's existing SDK-free REST pattern (`FirestoreClient`, `CloudStorageClient` barely change — swap the Bearer token and re-point storage at `firebasestorage.googleapis.com`).
- **App Store note:** offering Google sign-in on iOS triggers guideline 4.8 — we must also offer **Sign in with Apple**. Firebase Auth supports it natively; plan for all three (Apple, Google, email/password).

Build steps:
1. Enable Identity Platform on `quill-495210`; turn on Email/Password, Google, Apple providers.
2. `HexCore/CloudSync/AuthClient.swift` — shared REST client: `signUp`, `signIn`, `signInWithIdp` (exchanges the existing ASWebAuthenticationSession Google credential), `refresh`, `sendPasswordReset`, `deleteAccount`. Tokens in keychain via existing patterns; in-memory cache like `TokenCache`.
3. Key all cloud data by **`uid`** (`users/{uid}/notes/...`); write `firestore.rules` + `storage.rules` (`request.auth.uid == uid`), commit them to the repo, deploy. Migrate existing data (small user set) with a one-time script.
4. **Keep the existing Google OAuth flow** for Gmail/Calendar scopes — Firebase auth and Google-service authorization are separate concerns. When a user signs in with Google, run one combined consent so it feels like a single flow; the OAuth token continues to power Gmail/Calendar adapters, while the Firebase ID token powers sync/proxy/entitlements. Drop the `datastore`/`devstorage` scopes from the OAuth request entirely.
5. Rework the AI proxy: verify the Firebase ID token (public JWKS, check `aud` = project), read `users/{uid}/entitlement` for Pro, add per-uid daily token quota. `ALLOWED_EMAILS` becomes a break-glass override, not the security model.
6. UI: macOS onboarding + Settings → Account section; iOS Settings → Account. Anonymous/local-only use stays fully supported — accounts are only required for cloud sync + Pro.

Verification: a second test account must get `PERMISSION_DENIED` reading the first account's `users/{uid}` subtree via raw REST; proxy must reject (401/403) any non-Quill token and any non-Pro uid.

---

> **2026-07-05 pivot:** Parts 4–5 below were rewritten. The original draft centered on a Granola-style Meeting Mode; the new direction is **Hermes — a personal voice agent with memory, workflows, and routines**. Meeting Mode is parked (it becomes just another thing Hermes can do later). Parts 1–3 (security, performance, accounts) are unchanged and remain prerequisites — memory is the most intimate data Quill will ever store, so per-user isolation must land first.

## Part 4 — Hermes: everyone gets their own agent

### The one-sentence pitch

Quill stops being a dictation app with actions bolted on, and becomes **the voice interface to a personal agent that knows you** — it remembers what you say, executes multi-step work across your tools, and turns your repeated behavior into one-phrase routines. On-device ASR means the trigger surface (your voice, all day) never leaves your Mac.

### Why nobody else can do this

Every adjacent player is missing at least one leg of the stool:

| | Voice-native | OS-level context (frontmost app, selection) | Personal memory | Real execution (tools) | Learned routines |
|---|---|---|---|---|---|
| Siri / Apple Intelligence | ✅ | partial | ❌ | weak | ❌ |
| ChatGPT / Claude apps | partial | ❌ | chat-scoped | via MCP, no OS hooks | ❌ |
| Raycast AI | ❌ (text launcher) | partial | ❌ | ✅ | ❌ |
| Lindy / Dust / Zapier agents | ❌ (web) | ❌ | workspace | ✅ | manual builder |
| Wispr Flow / superwhisper | ✅ | ❌ | ❌ | ❌ | ❌ |
| Granola | ❌ (meetings) | ❌ | meeting-scoped | ❌ (notes out) | recipes (manual) |
| **Quill + Hermes** | ✅ | ✅ (AX plumbing exists) | ✅ | ✅ (adapters + queue exist) | ✅ |

The moat is the *combination*: a global hotkey that captures intent in ~1s from inside any app, on-device transcription, an agent that carries persistent memory of the person, and an execution layer that actually does the work. Quill has already built the two hardest legs (voice capture UX, execution/queue infrastructure).

### The five product pillars

**1. Named agent identity — the orb becomes someone.**
At onboarding you name your agent (default suggestion: Hermes — messenger of the gods; users can pick anything). The existing orb display mode stops being a "skin" and becomes the agent's embodiment: its colors are the agent's state, the satellite ring is the agent reaching for tools, the result pulse is the agent reporting back. This is a narrative unification of things already built — near-zero engineering, large perceived-product delta. All copy shifts from "Action mode" to "*Ask Hermes*."

**2. Workflows — multi-step plans, not single intents.**
Today `ActionParsingClient` produces one `ActionIntent`. Hermes produces a **plan**: an ordered list of steps across integrations, each riding an existing adapter.
> "Wrap up the Kearney project — email Mike the summary from my last note, create follow-up tasks for the three open items, and block an hour Friday to review."
→ Gmail draft + 3 Todoist tasks + Calendar event, rendered in the confirmation panel as a checklist with live per-step progress (pending → running → ✓/✕), partial-failure handling, and per-step editing before run. The offline action queue generalizes into the workflow engine — it already has persistence, retry policy, and transient-error classification.

**3. Memory — earned from what you say, not what you type into a settings form.**
Every dictation is behavioral signal: who you mention, which projects recur, your terminology, which integration you route what to. After each transcript, a background extraction pass distills **memory candidates** into three layers:
- **Profile** — stable facts & preferences ("tasks go to Todoist P2 by default," "signs emails 'Best, Joe'").
- **Entity graph** — people, projects, aliases, associated integrations/lists, recency ("Mike" = Mike Chen, Kearney project, mike@…, last mentioned Tuesday).
- **Episodic** — recent dictations, actions taken, outcomes.

Memory powers disambiguation ("remind me to follow up with Mike" needs zero clarifying questions), pre-fills (the right Todoist project, the right calendar), and Granola-style **briefs** in the confirmation panel ("last email you sent Mike," "3 open Kearney tasks"). Critically: a **"What Hermes knows about me"** screen where every memory is visible, editable, and deletable — trust is the product. Extraction can run on-device (Apple Foundation Models) for free users; Pro uses the proxy. Memory syncs cross-device under `users/{uid}/memory` — which is exactly why accounts (Part 3) come first.

**4. Routines — workflows that crystallize out of your own behavior.**
Three ways a routine is born:
- **Voice-authored** (the killer demo): *"Hermes, new routine: when I say 'ship it', create my release checklist in Todoist and email the team that the build is up."* Natural-language workflow authoring — no builder UI, ever.
- **Promoted**: after any executed workflow, one tap — "Save as routine" → name + trigger phrase.
- **Mined** (the nobody-else-does-this one): Hermes notices you dictate a standup summary every Monday and send it to the same place, and *proposes* the routine. Your agent learns your job.

Routines are parameterized templates (`{date}`, `{selection}`, `{last_note}`) with trigger phrases matched *before* the LLM call — instant, free, offline-capable. A trust ladder governs autonomy: always-confirm → auto-run for this routine → daily digest of what ran.

**5. Reach — text triggers, scheduled execution, and unbounded tools via MCP.**
- **Command bar**: a text field in the menu-bar dropdown (and iOS) feeding the identical pipeline — voice-first, not voice-only.
- **Time-shifted workflows**: "Monday at 9, send Mike the draft" → the queue gains scheduled triggers (persistence/retry already exist).
- **Commitment inbox**: the extractor flags promises in your own dictations ("I'll get this to you by Friday") and tracks them — your agent holds you to your word.
- **MCP client**: adapters unify behind an `AgentTool` protocol; then Quill speaks Model Context Protocol as a *client*, so any MCP server becomes an integration. The hand-built catalog (Notion, Slack, Linear "coming soon") becomes unbounded overnight — and "voice-native MCP client for macOS" is a category nobody occupies. (Later: expose your Hermes *as* an MCP server so Claude/ChatGPT can query your memory/notes — Granola did this for meetings; we do it for your whole voice layer.)

### What survives from the Granola research

- **The enhancement reveal** → Hermes's post-run report moment (plan checklist completing, orb pulse).
- **Briefs** → memory-powered context in the confirmation panel before execution.
- **Recipes/templates** → routines gallery, persona-seeded at onboarding.
- **Retention-based free tier** → free = dictation + single actions + 30-day memory/history; Pro = persistent memory, workflows, routines, bundled AI, MCP.
- **Privacy positioning** → "Your voice never leaves your Mac" now extends to "your agent's memory lives in *your* space, visible and deletable" — vs. every cloud agent product.

## Part 5 — Execution plan

Phases 0–2 from the original plan are unchanged and still come first (0 = proxy/IAM hardening, 1 = accounts + security rules, 2 = performance sprint). The agent work then proceeds:

**Phase A — Workflow engine + agent identity (3–4 weeks)**
1. `AgentTool` protocol in HexCore; wrap the five existing adapters (name, description-for-LLM, parameter schema, execute). → verify: all existing single-intent Action flows pass through the new layer unchanged.
2. `WorkflowPlan { steps: [WorkflowStep { tool, intent, dependsOn }] }` model + planner: evolve `ActionParsingClient` into `HermesPlannerClient` — LLM returns single intent *or* multi-step plan (schema-constrained JSON, same prompt lineage as `ActionSystemPrompt`).
3. Workflow engine on top of `ActionQueueManager` (sequential execution v1, per-step retry/offline via existing `QueueableErrorClassifier`).
4. Confirmation panel → plan checklist with live per-step status + per-step edit; orb satellite ring animates the active step.
5. Naming/onboarding: name your agent; copy sweep Action mode → agent framing.
✅ Demo gate: the "wrap up the Kearney project" utterance executes 3 steps across Gmail/Todoist/Calendar with visible progress, and a mid-flight network drop resumes from the queue.

**Phase B — Memory v1 (3–4 weeks)**
1. `HexCore/Memory/`: `MemoryStore` (local + `users/{uid}/memory` Firestore sync), `MemoryExtractor` (post-transcription background pass, on-device Foundation Models where available, proxy for Pro), `MemoryRetriever` (assembles planner context: profile + top-k entities + recent episodes).
2. Wire retrieval into `HermesPlannerClient` — disambiguation + pre-fill.
3. Briefs in the confirmation panel (recent related entity activity).
4. "What Hermes knows about me" screen (macOS Settings tab + iOS): view/edit/delete every memory; global off switch.
✅ Gate: "remind me to follow up with Mike" resolves the right Mike/project/list with no questions; deleting a memory verifiably changes the next plan.

**Phase C — Routines (2–3 weeks)**
1. `Routine` model (name, trigger phrases, plan template, parameters, autonomy level) + fast-path phrase matching before any LLM call.
2. Voice-authored routine creation + "save as routine" post-run.
3. Trust ladder (confirm → auto-run per routine → daily digest).
4. Pattern mining v1: simple recurrence detection over episodic memory → suggestion cards.
✅ Gate: "ship it" runs a 2-step routine in <2s with no LLM call; a mined suggestion appears after 3 similar Monday dictations.

**Phase D — Reach (ongoing after C)**
Text command bar → scheduled workflows → commitment inbox → MCP client (this is the big one — sized separately when we get there) → ask-your-history chat → Hermes-as-MCP-server. Meeting capture re-enters here as "a tool Hermes can hold," not a standalone mode.

**Monetization switch flips at end of Phase B** (memory is the retention hook): free tier keeps dictation + single actions; Pro = persistent memory + workflows + routines + bundled AI.

**Marketing throughline:** *"Stop dictating to your computer. Start delegating to your agent — and your voice never leaves your Mac."*

---

## Appendix — Prerequisite phases (unchanged from original plan)

**Phase 0 — Stop the bleeding (days, do first)**
1. Check GCP IAM on project/bucket; remove any `allUsers`/`allAuthenticatedUsers`. ✅ when verified in console.
2. Patch proxy: tokeninfo `aud` check + mandatory allowlist + per-email daily cap. Redeploy. ✅ when a non-Quill token gets 403.
3. iOS `print()` → `HexLog` sweep (M2). Gate `disable-library-validation` to Debug if Sparkle tolerates it (H3).

**Phase 1 — Accounts + trust boundary (2–3 weeks)**
Build order: AuthClient (REST) → sign-in UI (Apple + Google + email/password on both platforms) → re-key Firestore/Storage by uid + security rules (committed to repo) → migrate data → proxy verifies Firebase ID token + entitlement doc → drop datastore/storage OAuth scopes. ✅ when the cross-account PERMISSION_DENIED test passes and Pro is server-enforced.

**Phase 2 — Performance sprint (1–2 weeks, can interleave with Phase 1)**
Model prewarm → paste-before-persist → history cap + search/icon fixes → idle-orb animation pause → incremental/batched sync → keychain cache → memory-pressure model unload. ✅ criteria: first-dictation latency ≈ warm latency; idle CPU in Orb mode ≈ 0%; sync of unchanged data ≤ 2 requests.
