//
//  IOSSuggestionSources.swift
//  Quill (iOS)
//
//  Read-only context fetchers for the proactive-suggestion pass. Each
//  returns a `SuggestionSourceContext` (or nil when there's nothing to
//  read), and every one is best-effort: a failed or empty source just
//  drops out of the pass rather than failing it.
//
//  Two hard rules:
//  1. NEVER prompt for permissions from here — this runs on app foreground.
//     EventKit sources bail unless access was already granted.
//  2. Read-only. Nothing here mutates any source.
//

import EventKit
import Foundation
import HexCore
import os

private let sourcesLogger = HexLog.aiProcessing

@MainActor
enum IOSSuggestionSources {
  /// A meeting for the Dictate × Calendar strip (not Pro-gated — it's a
  /// Dictate convenience, not a suggestion).
  struct UpcomingMeeting: Identifiable, Equatable {
    let id: String
    let time: String
    let title: String
    let detail: String
    let isNow: Bool
  }

  private static let store = EKEventStore()

  // MARK: - EventKit access (silent — never prompts)

  private static var hasCalendarRead: Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess
  }

  private static var hasRemindersRead: Bool {
    EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
  }

  // MARK: - Calendar

  /// A calendar event from either backend — EventKit (Apple Calendar, when
  /// read access was already granted) or the Google Calendar REST API (when
  /// Google is connected). Google-only users get calendar suggestions and
  /// the meetings strip without ever granting local calendar access.
  private struct MergedEvent {
    let start: Date
    let end: Date
    let title: String
    let location: String?
  }

  private static func mergedEvents(
    from start: Date,
    to end: Date,
    includeGoogle: Bool
  ) async -> [MergedEvent] {
    var events: [MergedEvent] = []

    if hasCalendarRead {
      let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
      events += store.events(matching: predicate)
        .filter { !$0.isAllDay }
        .map { MergedEvent(start: $0.startDate, end: $0.endDate, title: $0.title ?? "(untitled)", location: $0.location) }
    }

    if includeGoogle {
      let hours = max(1, Int(ceil(end.timeIntervalSince(start) / 3600)))
      events += await IOSGoogleCalendarAdapter.upcomingEvents(from: start, hours: hours)
        .filter { $0.start < end }
        .map { MergedEvent(start: $0.start, end: $0.end, title: $0.title, location: $0.location) }
    }

    // The same meeting often exists in both backends (a Google account
    // added to the iOS Calendar app) — dedupe by title + start minute.
    var seen = Set<String>()
    return events
      .sorted { $0.start < $1.start }
      .filter { event in
        let key = "\(event.title.lowercased())|\(Int(event.start.timeIntervalSince1970 / 60))"
        return seen.insert(key).inserted
      }
  }

  /// Events in the next 48 hours, from EventKit and/or Google.
  static func calendarContext(includeGoogle: Bool) async -> SuggestionSourceContext? {
    let now = Date()
    guard let end = Calendar.current.date(byAdding: .hour, value: 48, to: now) else { return nil }
    let events = (await mergedEvents(from: now, to: end, includeGoogle: includeGoogle)).prefix(20)
    guard !events.isEmpty else { return nil }

    let formatter = DateFormatter()
    formatter.dateFormat = "EEE h:mm a"
    let lines = events.map { event -> String in
      let start = formatter.string(from: event.start)
      let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
      var line = "- \(start) · \(event.title) (\(minutes) min)"
      if let location = event.location, !location.isEmpty {
        line += " @ \(location)"
      }
      return line
    }
    return SuggestionSourceContext(
      source: .calendar,
      text: "Events in the next 48 hours:\n" + lines.joined(separator: "\n")
    )
  }

  /// Today's remaining meetings for the Dictate strip.
  static func upcomingMeetings(includeGoogle: Bool) async -> [UpcomingMeeting] {
    let now = Date()
    guard let dayEnd = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: now),
          let lookBack = Calendar.current.date(byAdding: .hour, value: -2, to: now)
    else { return [] }

    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm"
    return (await mergedEvents(from: lookBack, to: dayEnd, includeGoogle: includeGoogle))
      .filter { $0.end > now }
      .prefix(6)
      .map { event in
        UpcomingMeeting(
          id: "\(event.title)|\(event.start.timeIntervalSince1970)",
          time: formatter.string(from: event.start),
          title: event.title,
          detail: event.location ?? "",
          isNow: event.start <= now && event.end > now
        )
      }
  }

  // MARK: - Reminders

  /// Incomplete reminders that are overdue or due within 24h.
  static func remindersContext() async -> SuggestionSourceContext? {
    guard hasRemindersRead else { return nil }
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil,
      ending: Calendar.current.date(byAdding: .hour, value: 24, to: Date()),
      calendars: nil
    )
    let reminders: [EKReminder] = await withCheckedContinuation { continuation in
      store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
    }
    guard !reminders.isEmpty else { return nil }

    let today = Calendar.current.startOfDay(for: Date())
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    let lines = reminders.prefix(20).map { reminder -> String in
      guard let components = reminder.dueDateComponents,
            let due = Calendar.current.date(from: components)
      else { return "- \(reminder.title ?? "(untitled)")" }
      let overdue = due < today ? " [OVERDUE]" : ""
      return "- \(reminder.title ?? "(untitled)") (due \(formatter.string(from: due)))\(overdue)"
    }
    return SuggestionSourceContext(
      source: .reminders,
      text: "Open reminders due soon or overdue:\n" + lines.joined(separator: "\n")
    )
  }

  // MARK: - Todoist

  static func todoistContext() async -> SuggestionSourceContext? {
    let snapshot = await IOSTodoistAdapter.tasksSnapshot()
    guard !snapshot.isEmpty else { return nil }
    return SuggestionSourceContext(source: .todoist, text: snapshot)
  }

  // MARK: - MCP (Dex, Gmail-via-MCP)

  /// Generic read pass over connected MCP servers whose brand maps to a
  /// suggestion source (Dex CRM, a Gmail MCP server). Calls up to two
  /// read-shaped tools per server — tools whose names start with list/get
  /// and whose schemas require nothing we can't supply.
  static func mcpContexts() async -> [SuggestionSourceContext] {
    var contexts: [SuggestionSourceContext] = []
    for server in MCPServersStorage.load() where server.isEnabled {
      guard let source = suggestionSource(for: server) else { continue }
      let token = await IOSMCPOAuthClient.resolveAuthToken(for: server)

      var tools = await MCPToolCatalog.shared.cachedTools(for: server.id)?.tools
      if tools == nil {
        tools = try? await MCPToolCatalog.shared.refresh(server: server, authToken: token)
      }
      guard let tools, !tools.isEmpty else { continue }

      let readTools = tools.filter { isCallableReadTool($0) }.prefix(2)
      guard !readTools.isEmpty else { continue }

      var sections: [String] = []
      for tool in readTools {
        do {
          let client = try MCPClient(url: server.url, authToken: token)
          try await client.connect()
          let result = try await client.callTool(
            name: tool.name,
            arguments: defaultArguments(for: tool)
          )
          if !result.isEmpty {
            sections.append("\(tool.name):\n\(String(result.prefix(1800)))")
          }
        } catch {
          sourcesLogger.info("Suggestion MCP read \(tool.name, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
        }
      }
      if !sections.isEmpty {
        contexts.append(
          SuggestionSourceContext(source: source, text: sections.joined(separator: "\n\n"))
        )
      }
    }
    return contexts
  }

  /// Brand-match a server to a suggestion source; unknown brands don't feed
  /// suggestions in v1 (the source registry is closed).
  private static func suggestionSource(for server: MCPServerConfig) -> SuggestionSource? {
    let brand = ConnectionDirectory.brand(forServerNamed: server.name, url: server.url)
    let name = (brand?.name ?? server.name).lowercased()
    return SuggestionSource(rawValue: name)
  }

  /// A tool we can safely call blind: read-shaped name, and every required
  /// argument is one we know how to fill.
  private static func isCallableReadTool(_ tool: MCPTool) -> Bool {
    let name = tool.name.lowercased()
    let readPrefixes = ["list", "search", "get"]
    let interesting = ["contact", "reminder", "email", "thread", "message", "task", "event", "note"]
    guard readPrefixes.contains(where: { name.contains($0) }),
          interesting.contains(where: { name.contains($0) })
    else { return false }
    // Detail lookups need an id we don't have.
    if name.contains("get_") && !name.contains("list") { return false }
    return requiredArguments(of: tool).allSatisfy { fillableArguments.keys.contains($0) }
  }

  private static let fillableArguments: [String: Any] = ["limit": 15, "pageSize": 15]

  private static func requiredArguments(of tool: MCPTool) -> [String] {
    guard let schemaJSON = tool.inputSchemaJSON,
          let data = schemaJSON.data(using: .utf8),
          let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }
    return schema["required"] as? [String] ?? []
  }

  private static func defaultArguments(for tool: MCPTool) -> [String: Any] {
    guard let schemaJSON = tool.inputSchemaJSON,
          let data = schemaJSON.data(using: .utf8),
          let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let properties = schema["properties"] as? [String: Any]
    else { return [:] }
    // Pass only arguments the schema actually declares.
    return fillableArguments.filter { properties.keys.contains($0.key) }
  }
}
