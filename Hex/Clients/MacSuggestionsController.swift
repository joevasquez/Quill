//
//  MacSuggestionsController.swift
//  Quill (macOS)
//
//  ObservableObject bridge over the shared `SuggestionStore` actor plus
//  the generation trigger — the macOS mirror of the iOS
//  `SuggestionsController`. Self-gating (Pro plan, connected sources,
//  30-min TTL) so call sites stay one-liners.
//
//  Consume-on-run: the macOS confirmation panel is driven by
//  NotificationCenter with no correlation id, so accepting a suggestion
//  records it as pending and the `.actionConfirmationExecuted` observer
//  consumes it. Only one panel exists at a time (posting replaces it),
//  so the pending suggestion is unambiguous.
//

import Combine
import ComposableArchitecture
import Foundation
import HexCore
import os

private let macSuggestLogger = HexLog.aiProcessing

@MainActor
final class MacSuggestionsController: ObservableObject {
  static let shared = MacSuggestionsController()

  @Published private(set) var current: [Suggestion] = []
  @Published private(set) var isGenerating = false
  /// True when the last pass found NOTHING readable — drives the honest
  /// empty state instead of a misleading "all caught up".
  @Published private(set) var hadNoReadableSources = false
  /// Today's remaining meetings for the Home "Dictate into a meeting"
  /// strip. Not Pro-gated — it's a capture convenience.
  @Published private(set) var meetings: [MacSuggestionSources.UpcomingMeeting] = []

  static let staleTTL: TimeInterval = 30 * 60

  private var hasLoadedPersisted = false
  /// The suggestion whose intents are currently in the confirmation
  /// panel, awaiting Run/Dismiss.
  private var pendingRun: Suggestion?
  private var observers: [NSObjectProtocol] = []

  private init() {
    // Consume the pending suggestion when its panel run finishes; keep it
    // when the panel is cancelled.
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .actionConfirmationExecuted, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self, let ran = self.pendingRun else { return }
          self.pendingRun = nil
          self.consume(ran)
        }
      }
    )
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .actionConfirmationCancelled, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.pendingRun = nil }
      }
    )
  }

  // MARK: - Gating

  var isPro: Bool {
    @Shared(.hexSettings) var hexSettings: HexSettings
    guard hexSettings.selectedPlan == "pro" else { return false }
    let email = UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey)
    return email?.isEmpty == false
  }

  // MARK: - Triggers

  /// The in-flight pass. Owned by the controller — NOT by whichever view
  /// or effect asked for it. A generation pass makes several network
  /// round-trips (MCP reads, then the LLM), and `HomeView`'s `.task` is
  /// cancelled the moment you navigate to another pane, which was killing
  /// reads mid-flight ("dex_list_contacts failed: cancelled").
  private var generationTask: Task<Void, Never>?

  /// Safe to call whenever the Home pane appears / the app foregrounds.
  /// Returns as soon as the pass is *scheduled*, so the caller's
  /// lifetime can't cancel it.
  func refreshOnAppear() async {
    await loadPersistedIfNeeded()
    start(force: false)
  }

  /// User-initiated refresh — skips the TTL.
  func regenerateNow() async {
    start(force: true)
  }

  private func start(force: Bool) {
    // One pass at a time; a manual refresh doesn't stack on the
    // automatic one.
    guard generationTask == nil else { return }
    generationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.generationTask = nil }
      self.meetings = await MacSuggestionSources.upcomingMeetings(
        includeGoogle: self.connectedIntegrations.contains(.googleCalendar)
      )
      await self.regenerate(force: force)
    }
  }

  private func regenerate(force: Bool) async {
    guard isPro, !isGenerating else { return }
    if !force {
      guard await SuggestionStore.shared.isStale(ttl: Self.staleTTL) else { return }
    }

    isGenerating = true
    defer { isGenerating = false }

    let contexts = await fetchContexts()
    hadNoReadableSources = contexts.isEmpty
    guard !contexts.isEmpty else {
      macSuggestLogger.info("Suggestions (macOS): no readable sources — skipping generation")
      return
    }

    do {
      let fresh = try await SuggestionEngine.generate(
        contexts: contexts,
        capabilities: await capabilitiesContext()
      ) { userMessage, systemPrompt in
        let credential = try await Self.resolveCredential()
        return try await LLMTransport.complete(
          userMessage: userMessage,
          systemPrompt: systemPrompt,
          credential: credential,
          maxTokens: 3000,
          timeout: 30
        )
      }
      await SuggestionStore.shared.replaceAll(fresh)
      current = await SuggestionStore.shared.current()
    } catch {
      macSuggestLogger.error("Suggestions (macOS): generation failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - User actions

  /// Accept: hand the suggestion's pre-built intents to the existing
  /// confirmation panel (review-before-run, never auto-executed) and
  /// remember it so the executed notification can consume it.
  func review(_ suggestion: Suggestion) {
    pendingRun = suggestion
    ActionConfirmationNotification.postMulti(
      intents: suggestion.intents,
      // The headline is what the user saw and accepted — without it the
      // trace would have a blank request line for every suggestion run.
      rawTranscript: suggestion.headline,
      autoExecute: false,
      trigger: .suggestion
    )
  }

  func dismiss(_ suggestion: Suggestion) {
    current.removeAll { $0.id == suggestion.id }
    Task { await SuggestionStore.shared.dismiss(suggestion) }
  }

  func consume(_ suggestion: Suggestion) {
    current.removeAll { $0.id == suggestion.id }
    Task { await SuggestionStore.shared.consume(suggestion) }
  }

  // MARK: - Internals

  private func loadPersistedIfNeeded() async {
    guard !hasLoadedPersisted else { return }
    hasLoadedPersisted = true
    current = await SuggestionStore.shared.current()
  }

  private var connectedIntegrations: Set<Integration.Identifier> {
    IntegrationConnectionStore.decode(
      UserDefaults.standard.data(forKey: IntegrationConnectionStore.userDefaultsKey) ?? Data()
    )
  }

  private var mcpServers: [MCPServerConfig] {
    @Shared(.hexSettings) var hexSettings: HexSettings
    return hexSettings.mcpServers
  }

  /// Gather context from every connected source, best-effort. Per-source
  /// defaults follow `SuggestionSource.enabledByDefault` (Reminders off);
  /// macOS has no per-source Settings UI yet.
  private func fetchContexts() async -> [SuggestionSourceContext] {
    let connected = connectedIntegrations
    var contexts: [SuggestionSourceContext] = []

    if SuggestionSource.calendar.enabledByDefault,
       connected.contains(.calendar) || connected.contains(.googleCalendar),
       let calendar = await MacSuggestionSources.calendarContext(
         includeGoogle: connected.contains(.googleCalendar)
       ) {
      contexts.append(calendar)
    }
    if SuggestionSource.reminders.enabledByDefault, connected.contains(.appleReminders),
       let reminders = await MacSuggestionSources.remindersContext() {
      contexts.append(reminders)
    }
    if SuggestionSource.todoist.enabledByDefault, connected.contains(.todoist),
       let todoist = await MacSuggestionSources.todoistContext() {
      contexts.append(todoist)
    }
    contexts.append(contentsOf: await MacSuggestionSources.mcpContexts(servers: mcpServers))

    return contexts
  }

  private func capabilitiesContext() async -> String {
    let connected = connectedIntegrations
    var lines = ["Available destinations:"]
    if connected.contains(.appleReminders) { lines.append("- appleReminders (createReminder)") }
    if connected.contains(.todoist) { lines.append("- todoist (createTask)") }
    if connected.contains(.calendar) { lines.append("- calendar (createEvent)") }
    if connected.contains(.googleCalendar) { lines.append("- googleCalendar (createEvent)") }
    if connected.contains(.gmail) { lines.append("- gmail (createDraft)") }
    if lines.count == 1 { lines.append("- none (only mcpCall available)") }

    var context = lines.joined(separator: "\n")
    if let mcpContext = await MCPToolCatalog.shared.promptContext(servers: mcpServers) {
      context += "\n\n" + mcpContext
    }
    return context
  }

  /// Pro proxy when active, else BYOK — mirrors the private helpers in
  /// `ActionParsingClient`.
  private static func resolveCredential() async throws -> LLMCredential {
    @Shared(.hexSettings) var hexSettings: HexSettings
    let email = UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey)
    if hexSettings.selectedPlan == "pro", email?.isEmpty == false {
      @Dependency(\.googleOAuth) var googleOAuth
      let accessToken = try await googleOAuth.refreshIfNeeded()
      return .proProxy(accessToken: accessToken)
    }

    @Dependency(\.keychain) var keychain
    let provider = hexSettings.aiProvider
    let account = provider == .openAI ? KeychainKey.openAIAPIKey : KeychainKey.anthropicAPIKey
    guard let key = await keychain.read(account), !key.isEmpty else {
      throw LLMTransportError.invalidResponse
    }
    return .byok(apiKey: key, provider: provider)
  }
}
