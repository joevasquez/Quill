//
//  QuilliOSApp.swift
//  Quill (iOS)
//
//  Created by Joe Vasquez.
//

import HexCore
import SwiftUI

@main
struct QuilliOSApp: App {
  /// Published signal the root `ContentView` observes to know when a
  /// `quill://` deep link has arrived — currently fired by the home-
  /// screen widget to request "start recording immediately" or "open
  /// the notes list". See `QuillDeepLink` for the routing table.
  @ObservedObject private var deepLinkRouter = QuillDeepLinkRouter.shared

  @AppStorage(QuillIOSSettingsKey.hasCompletedOnboarding)
  private var hasCompletedOnboarding: Bool = false

  /// Theme override, applied to the whole scene. Empty (the default) is
  /// Auto — `QuillAppearance.colorScheme` hands `nil` back to SwiftUI so
  /// the device decides.
  @AppStorage(QuillIOSSettingsKey.appearance)
  private var appearanceRaw: String = QuillAppearance.system.rawValue

  init() {
    // Install Sentry-backed error monitoring up front so launch-time
    // crashes get captured (it stays inert until the user opts in via
    // Settings → Privacy → Send anonymous crash reports).
    ErrorMonitoring.installLiveService(SentryErrorMonitoring())
    ErrorMonitoring.configure()
    // Install the offline action queue executor + parser so any actions
    // queued by ActionConfirmationViewModel (post-parse adapter failure)
    // OR by RecordingViewModel.stopAndParseAction (pre-parse network
    // failure) are retried automatically when connectivity returns.
    Task {
      await ActionQueueManager.shared.install(
        executor: IOSSystemActionQueueExecutor(),
        parser: IOSActionQueueParser()
      )
    }
    // Warm the MCP tool catalog for enabled servers so the first Action
    // parse after launch can already offer mcpCall tools (mirrors macOS
    // `HexAppDelegate.refreshMCPCatalog`). Failures are fine — the
    // catalog just stays empty for that server until a manual refresh.
    Task { @MainActor in
      for server in MCPServersStorage.load() where server.isEnabled {
        let token = await IOSMCPOAuthClient.resolveAuthToken(for: server)
        _ = try? await MCPToolCatalog.shared.refresh(server: server, authToken: token)
      }
    }
    // Backfill `IntegrationConnectionStore` from OAuth state. Users who
    // signed in to Google before the store was being updated have valid
    // keychain tokens but no `.gmail`/`.googleCalendar` entries in the
    // store, which leaves them invisible in the Action confirmation
    // dropdown until they re-sign-in. This one-time sync repairs them.
    Self.syncGoogleIntegrationsFromOAuth()
    // Cloud sync intentionally NOT triggered here — it's wired to
    // `scenePhase == .active` below so it (a) doesn't compete with
    // launch-time work like model warm-up + TCC prompts, and (b)
    // automatically refreshes when the user foregrounds the app.
  }

  /// Reflect the OAuth-authorized state of Google into the integration
  /// connection set. Idempotent — a no-op when the store is already in
  /// sync. Runs on every launch (cheap), not just first launch.
  @MainActor
  private static func syncGoogleIntegrationsFromOAuth() {
    let key = IntegrationConnectionStore.userDefaultsKey
    let raw = UserDefaults.standard.data(forKey: key)
    var current = IntegrationConnectionStore.decode(raw)
    let authorized = IOSGoogleOAuthClient.isAuthorized()

    if authorized {
      let needsInsert = !current.contains(.gmail) || !current.contains(.googleCalendar)
      guard needsInsert else { return }
      current.insert(.gmail)
      current.insert(.googleCalendar)
      UserDefaults.standard.set(IntegrationConnectionStore.encode(current), forKey: key)
    } else {
      // OAuth tokens were cleared (e.g. user revoked access via
      // accounts.google.com). Clean the store to match so the rows
      // don't lie.
      let needsRemove = current.contains(.gmail) || current.contains(.googleCalendar)
      guard needsRemove else { return }
      current.remove(.gmail)
      current.remove(.googleCalendar)
      UserDefaults.standard.set(IntegrationConnectionStore.encode(current), forKey: key)
    }
  }

  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(deepLinkRouter)
        .onOpenURL { url in
          deepLinkRouter.handle(url)
        }
        // First-launch walk-through. Modal full-screen so the user
        // can't tap around the main UI before granting at least
        // microphone permission. The bound flag flips to true once
        // they finish or skip-through; resetting it (Settings →
        // Productivity → Replay Tutorial) re-enters the flow.
        .fullScreenCover(isPresented: Binding(
          get: { !hasCompletedOnboarding },
          set: { newValue in hasCompletedOnboarding = !newValue }
        )) {
          OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
        }
        .preferredColorScheme(
          (QuillAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
        )
    }
    .onChange(of: scenePhase) { _, newPhase in
      // Cloud sync runs on every foregrounding rather than just first
      // launch — keeps the local copy fresh after a long backgrounded
      // gap and gives the system breathing room at launch (model
      // warm-up, TCC prompts) since `init()` no longer fires sync.
      // No-op when sync is disabled or Google isn't connected.
      if newPhase == .active {
        Task { await NotesStore.shared.syncNow() }
        // Proactive suggestions (Pro): refresh the meetings strip and, when
        // Pro + toggle + connected sources + TTL all line up, run a
        // generation pass. Self-gating, like syncNow().
        Task { await SuggestionsController.shared.refreshOnForeground() }
      } else {
        // Live recognition revisions are normally saved on a short debounce.
        // Flush immediately before iOS can suspend us so an interrupted
        // recording is recoverable on the next launch.
        NotesStore.shared.flushPendingTranscriptionDrafts()
      }
    }
  }
}
