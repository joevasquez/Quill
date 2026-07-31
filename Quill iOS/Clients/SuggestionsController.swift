//
//  SuggestionsController.swift
//  Quill (iOS)
//
//  ObservableObject bridge over the shared `SuggestionStore` actor (same
//  relationship NotesStore has with its persistence) plus the generation
//  trigger. `regenerateIfStale()` runs on every app foregrounding — it is
//  entirely self-gating (Pro plan, master toggle, per-source opt-ins,
//  connected sources, TTL) so the call site stays a one-liner, mirroring
//  `NotesStore.syncNow()`.
//

import Combine
import Foundation
import HexCore
import os

private let suggestLogger = HexLog.aiProcessing

@MainActor
final class SuggestionsController: ObservableObject {
  static let shared = SuggestionsController()

  @Published private(set) var current: [Suggestion] = []
  @Published private(set) var isGenerating = false
  /// Today's remaining meetings for the Dictate × Calendar strip. Not
  /// Pro-gated — it's a Dictate convenience, refreshed on foreground.
  @Published private(set) var meetings: [IOSSuggestionSources.UpcomingMeeting] = []
  /// True when the last pass found NOTHING readable — connected sources
  /// exist in name but none produced context (e.g. Gmail connected
  /// natively, whose scope is compose-only). Drives an honest empty state
  /// instead of a misleading "all caught up".
  @Published private(set) var hadNoReadableSources = false

  /// Don't re-run the LLM pass more often than this, no matter how often
  /// the app foregrounds.
  static let staleTTL: TimeInterval = 30 * 60

  private var hasLoadedPersisted = false

  private init() {}

  // MARK: - Gating

  var isPro: Bool {
    UserDefaults.standard.string(forKey: QuillIOSSettingsKey.selectedPlan) == "pro"
  }

  var isEnabled: Bool {
    UserDefaults.standard.object(forKey: QuillIOSSettingsKey.suggestionsEnabled) as? Bool ?? true
  }

  private var sourceOverrides: [String: Bool] {
    SuggestionSourcePrefs.decode(
      UserDefaults.standard.data(forKey: QuillIOSSettingsKey.suggestionSourcePrefs) ?? Data()
    )
  }

  private func sourceEnabled(_ source: SuggestionSource) -> Bool {
    SuggestionSourcePrefs.isEnabled(source, overrides: sourceOverrides)
  }

  // MARK: - Foreground pass

  /// Refresh the meetings strip and, when everything lines up, run a
  /// suggestion generation pass. Safe to call on every foregrounding.
  func refreshOnForeground() async {
    meetings = await IOSSuggestionSources.upcomingMeetings(
      includeGoogle: connectedIntegrations.contains(.googleCalendar)
    )
    await loadPersistedIfNeeded()
    await regenerateIfStale()
  }

  func regenerateIfStale() async {
    await regenerate(force: false)
  }

  /// User-initiated refresh (the page's refresh button) — skips the TTL so
  /// "why is nothing here" is always answerable right now.
  func regenerateNow() async {
    await regenerate(force: true)
  }

  private func regenerate(force: Bool) async {
    guard isEnabled, isPro, !isGenerating else { return }
    if !force {
      guard await SuggestionStore.shared.isStale(ttl: Self.staleTTL) else { return }
    }

    isGenerating = true
    defer { isGenerating = false }

    let contexts = await fetchContexts()
    hadNoReadableSources = contexts.isEmpty
    guard !contexts.isEmpty else {
      suggestLogger.info("Suggestions: no readable sources — skipping generation")
      return
    }

    do {
      let provider = AIProvider(
        rawValue: UserDefaults.standard.string(forKey: QuillIOSSettingsKey.aiProvider)
          ?? QuillIOSSettingsKey.defaultProvider
      ) ?? .anthropic

      let fresh = try await SuggestionEngine.generate(
        contexts: contexts,
        capabilities: await capabilitiesContext()
      ) { userMessage, systemPrompt in
        let credential = try await IOSActionParsingClient.resolveCredential(for: provider)
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
      // Best-effort: keep whatever we had. A failed pass retries after TTL.
      suggestLogger.error("Suggestions: generation failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - User actions

  func dismiss(_ suggestion: Suggestion) {
    current.removeAll { $0.id == suggestion.id }
    Task { await SuggestionStore.shared.dismiss(suggestion) }
  }

  /// A suggestion whose actions ran successfully is consumed for good.
  func consume(_ suggestion: Suggestion) {
    current.removeAll { $0.id == suggestion.id }
    Task { await SuggestionStore.shared.consume(suggestion) }
  }

  /// Master-toggle-off clears everything (Settings calls this).
  func clearAll() {
    current = []
    Task { await SuggestionStore.shared.clearAll() }
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

  /// Gather context from every enabled + connected source, best-effort.
  private func fetchContexts() async -> [SuggestionSourceContext] {
    let connected = connectedIntegrations
    var contexts: [SuggestionSourceContext] = []

    if sourceEnabled(.calendar),
       connected.contains(.calendar) || connected.contains(.googleCalendar),
       let calendar = await IOSSuggestionSources.calendarContext(
         includeGoogle: connected.contains(.googleCalendar)
       ) {
      contexts.append(calendar)
    }
    if sourceEnabled(.reminders), connected.contains(.appleReminders),
       let reminders = await IOSSuggestionSources.remindersContext() {
      contexts.append(reminders)
    }
    if sourceEnabled(.todoist), connected.contains(.todoist),
       let todoist = await IOSSuggestionSources.todoistContext() {
      contexts.append(todoist)
    }
    // MCP-backed sources (Dex, Gmail-via-MCP) — the fetcher brand-matches
    // servers to sources; filter to the user's opt-ins here.
    let mcp = await IOSSuggestionSources.mcpContexts()
      .filter { sourceEnabled($0.source) }
    contexts.append(contentsOf: mcp)

    return contexts
  }

  /// What the engine may route actions to: connected native integrations
  /// plus the MCP tool context the action planner already uses.
  private func capabilitiesContext() async -> String {
    let connected = IntegrationConnectionStore.decode(
      UserDefaults.standard.data(forKey: IntegrationConnectionStore.userDefaultsKey) ?? Data()
    )
    var lines = ["Available destinations:"]
    if connected.contains(.appleReminders) { lines.append("- appleReminders (createReminder)") }
    if connected.contains(.todoist) { lines.append("- todoist (createTask)") }
    if connected.contains(.calendar) { lines.append("- calendar (createEvent)") }
    if connected.contains(.googleCalendar) { lines.append("- googleCalendar (createEvent)") }
    if connected.contains(.gmail) { lines.append("- gmail (createDraft)") }
    if lines.count == 1 { lines.append("- none (only mcpCall available)") }

    var context = lines.joined(separator: "\n")
    if let mcpContext = await MCPToolCatalog.shared.promptContext(servers: MCPServersStorage.load()) {
      context += "\n\n" + mcpContext
    }
    return context
  }
}
