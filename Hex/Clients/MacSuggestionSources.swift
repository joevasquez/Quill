//
//  MacSuggestionSources.swift
//  Quill (macOS)
//
//  Read-only context fetchers for the proactive-suggestion pass — the
//  macOS mirror of `IOSSuggestionSources`. Every fetcher is best-effort
//  (a failed or empty source drops out of the pass), read-only, and
//  silent: EventKit sources bail unless access was already granted, so
//  a background pass never triggers a permission prompt.
//

import Dependencies
import EventKit
import Foundation
import HexCore
import os

private let macSourcesLogger = HexLog.aiProcessing

@MainActor
enum MacSuggestionSources {
  private static let store = EKEventStore()

  private static var hasCalendarRead: Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess
  }

  private static var hasRemindersRead: Bool {
    EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
  }

  // MARK: - Calendar (EventKit + Google REST, merged)

  struct MergedEvent {
    let start: Date
    let end: Date
    let title: String
    let location: String?
  }

  /// Events from Apple Calendar (when read access is already granted)
  /// and/or Google Calendar, deduped (a Google account added to the macOS
  /// Calendar app produces the same meeting twice) by title + start minute.
  static func mergedEvents(from start: Date, to end: Date, includeGoogle: Bool) async -> [MergedEvent] {
    var events: [MergedEvent] = []
    if hasCalendarRead {
      let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
      events += store.events(matching: predicate)
        .filter { !$0.isAllDay }
        .map { MergedEvent(start: $0.startDate, end: $0.endDate, title: $0.title ?? "(untitled)", location: $0.location) }
    }
    if includeGoogle {
      events += await googleUpcomingEvents(from: start, to: end)
        .map { MergedEvent(start: $0.start, end: $0.end, title: $0.title, location: $0.location) }
    }

    var seen = Set<String>()
    return events
      .sorted { $0.start < $1.start }
      .filter { event in
        let key = "\(event.title.lowercased())|\(Int(event.start.timeIntervalSince1970 / 60))"
        return seen.insert(key).inserted
      }
  }

  /// A meeting for the Home pane's "Dictate into a meeting" strip.
  struct UpcomingMeeting: Identifiable, Equatable {
    let id: String
    let time: String
    let title: String
    let detail: String
    let isNow: Bool
  }

  /// Today's remaining meetings (including one already in progress).
  static func upcomingMeetings(includeGoogle: Bool) async -> [UpcomingMeeting] {
    let now = Date()
    guard let dayEnd = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: now),
          let lookBack = Calendar.current.date(byAdding: .hour, value: -2, to: now)
    else { return [] }

    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return (await mergedEvents(from: lookBack, to: dayEnd, includeGoogle: includeGoogle))
      .filter { $0.end > now }
      .prefix(5)
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

  /// Events in the next 48 hours for the suggestion engine.
  static func calendarContext(includeGoogle: Bool) async -> SuggestionSourceContext? {
    let now = Date()
    guard let end = Calendar.current.date(byAdding: .hour, value: 48, to: now) else { return nil }
    let merged = (await mergedEvents(from: now, to: end, includeGoogle: includeGoogle)).prefix(20)
    guard !merged.isEmpty else { return nil }

    let formatter = DateFormatter()
    formatter.dateFormat = "EEE h:mm a"
    let lines = merged.map { event -> String in
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

  private struct GoogleEvent {
    let start: Date
    let end: Date
    let title: String
    let location: String?
  }

  /// Timed events on the primary Google calendar — read-only port of
  /// `IOSGoogleCalendarAdapter.upcomingEvents`.
  private static func googleUpcomingEvents(from: Date, to end: Date) async -> [GoogleEvent] {
    @Dependency(\.googleOAuth) var googleOAuth
    guard let accessToken = try? await googleOAuth.refreshIfNeeded() else { return [] }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]

    var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
    components.queryItems = [
      URLQueryItem(name: "timeMin", value: iso.string(from: from)),
      URLQueryItem(name: "timeMax", value: iso.string(from: end)),
      URLQueryItem(name: "singleEvents", value: "true"),
      URLQueryItem(name: "orderBy", value: "startTime"),
      URLQueryItem(name: "maxResults", value: "20"),
    ]
    guard let url = components.url else { return [] }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15

    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse, http.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["items"] as? [[String: Any]]
    else { return [] }

    return items.compactMap { item in
      // All-day events carry "date" instead of "dateTime" — skip them.
      guard let startObj = item["start"] as? [String: Any],
            let endObj = item["end"] as? [String: Any],
            let startString = startObj["dateTime"] as? String,
            let endString = endObj["dateTime"] as? String,
            let start = iso.date(from: startString),
            let endDate = iso.date(from: endString)
      else { return nil }
      return GoogleEvent(
        start: start,
        end: endDate,
        title: (item["summary"] as? String) ?? "(untitled)",
        location: item["location"] as? String
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

  /// Read-only snapshot of active tasks — port of
  /// `IOSTodoistAdapter.tasksSnapshot` on the macOS keychain path.
  static func todoistContext(limit: Int = 25) async -> SuggestionSourceContext? {
    @Dependency(\.keychain) var keychain
    guard let token = await keychain.read(KeychainKey.todoistAPIToken), !token.isEmpty else { return nil }

    var request = URLRequest(url: URL(string: "https://api.todoist.com/api/v1/tasks")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15

    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse, http.statusCode == 200
    else { return nil }

    var tasks: [[String: Any]] = []
    if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      tasks = array
    } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = dict["results"] as? [[String: Any]] {
      tasks = results
    }
    guard !tasks.isEmpty else { return nil }

    let today = Calendar.current.startOfDay(for: Date())
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"

    func dueDate(_ task: [String: Any]) -> Date? {
      guard let due = task["due"] as? [String: Any],
            let dateString = due["date"] as? String
      else { return nil }
      return dayFormatter.date(from: String(dateString.prefix(10)))
    }
    let sorted = tasks.sorted { a, b in
      switch (dueDate(a), dueDate(b)) {
      case (let x?, let y?): return x < y
      case (_?, nil): return true
      default: return false
      }
    }

    let lines = sorted.prefix(limit).compactMap { task -> String? in
      guard let content = task["content"] as? String, !content.isEmpty else { return nil }
      guard let due = dueDate(task) else { return "- \(content) (no due date)" }
      let overdue = due < today ? " [OVERDUE]" : ""
      return "- \(content) (due \(dayFormatter.string(from: due)))\(overdue)"
    }
    guard !lines.isEmpty else { return nil }
    return SuggestionSourceContext(
      source: .todoist,
      text: "Active Todoist tasks:\n" + lines.joined(separator: "\n")
    )
  }

  // MARK: - MCP (Dex, Gmail-via-MCP)

  /// Generic read pass over connected MCP servers whose brand maps to a
  /// suggestion source — mirror of the iOS fetcher, using the macOS
  /// token/keychain path.
  static func mcpContexts(servers: [MCPServerConfig]) async -> [SuggestionSourceContext] {
    var contexts: [SuggestionSourceContext] = []
    for server in servers where server.isEnabled {
      guard let source = suggestionSource(for: server) else { continue }
      let token = await MCPOAuthClient.resolveAuthToken(for: server)

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
          macSourcesLogger.info("Suggestion MCP read \(tool.name, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
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
    return fillableArguments.filter { properties.keys.contains($0.key) }
  }
}
