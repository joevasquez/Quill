//
//  IOSGoogleCalendarAdapter.swift
//  Quill (iOS)
//
//  iOS port of `Hex/Clients/GoogleCalendarAdapter.swift`. Same Calendar v3
//  REST flow (build event JSON → POST events) using
//  `IOSGoogleOAuthClient` for the access token. Used by
//  `ActionConfirmationViewModel` for Google Calendar events and by
//  `IOSSystemActionQueueExecutor` for queued replays.
//

import Foundation
import HexCore
import os

private let actionLogger = HexLog.action

struct IOSGoogleCalendar: Equatable, Sendable, Identifiable {
  let id: String
  let name: String
}

/// A read-only upcoming event, used by the suggestion pass and the
/// Dictate × Calendar strip. Distinct from EventKit's `EKEvent` so
/// Google-only users (no local calendar access) still get both features.
struct IOSGoogleCalendarEvent: Equatable, Sendable {
  let start: Date
  let end: Date
  let title: String
  let location: String?
}

@MainActor
enum IOSGoogleCalendarAdapter {
  /// Fetches the user's calendar list. Returns `[]` on any failure
  /// (no Google session, network error, etc.) so the UI can render an
  /// empty picker rather than blocking.
  static func fetchCalendars() async -> [IOSGoogleCalendar] {
    guard let accessToken = try? await IOSGoogleOAuthClient.refreshIfNeeded() else {
      return []
    }
    return await fetchCalendarList(accessToken: accessToken)
  }

  /// Read-only: timed events on the primary calendar in the next `hours`.
  /// The existing `calendar.events` OAuth scope already permits reads —
  /// no re-consent needed. Best-effort: `[]` on any failure.
  static func upcomingEvents(from: Date = Date(), hours: Int = 48, maxResults: Int = 20) async -> [IOSGoogleCalendarEvent] {
    guard let accessToken = try? await IOSGoogleOAuthClient.refreshIfNeeded() else { return [] }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    guard let end = Calendar.current.date(byAdding: .hour, value: hours, to: from) else { return [] }

    var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
    components.queryItems = [
      URLQueryItem(name: "timeMin", value: iso.string(from: from)),
      URLQueryItem(name: "timeMax", value: iso.string(from: end)),
      URLQueryItem(name: "singleEvents", value: "true"),
      URLQueryItem(name: "orderBy", value: "startTime"),
      URLQueryItem(name: "maxResults", value: String(maxResults)),
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
      // All-day events carry "date" instead of "dateTime" — skip them,
      // matching the EventKit fetcher's !isAllDay filter.
      guard let startObj = item["start"] as? [String: Any],
            let endObj = item["end"] as? [String: Any],
            let startString = startObj["dateTime"] as? String,
            let endString = endObj["dateTime"] as? String,
            let start = iso.date(from: startString),
            let endDate = iso.date(from: endString)
      else { return nil }
      return IOSGoogleCalendarEvent(
        start: start,
        end: endDate,
        title: (item["summary"] as? String) ?? "(untitled)",
        location: item["location"] as? String
      )
    }
  }

  static func createEvent(_ intent: ActionIntent) async throws -> String {
    let accessToken = try await IOSGoogleOAuthClient.refreshIfNeeded()

    // Resolve the calendar by name when the user picked one in the
    // confirmation panel. Fallback to "primary" if the name doesn't
    // resolve, mirroring the macOS adapter behavior.
    let calendarId: String
    if let listName = intent.listName, !listName.isEmpty {
      let calendars = await fetchCalendarList(accessToken: accessToken)
      if let match = calendars.first(where: {
        $0.name.localizedCaseInsensitiveCompare(listName) == .orderedSame
      }) {
        calendarId = match.id
      } else {
        calendarId = "primary"
        actionLogger.info("Google Calendar '\(listName, privacy: .public)' not found (iOS); using primary")
      }
    } else {
      calendarId = "primary"
    }

    let startDate: Date
    let endDate: Date
    if let s = intent.startDate, let e = intent.endDate {
      startDate = s
      endDate = e
    } else if let dueDateString = intent.dueDate, !dueDateString.isEmpty,
              let parsed = parseDateAndTime(dueDateString) {
      startDate = parsed
      let minutes = intent.duration ?? 60
      endDate = parsed.addingTimeInterval(Double(minutes) * 60)
    } else {
      let fallback = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
      startDate = fallback
      endDate = fallback.addingTimeInterval(3600)
    }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]

    var eventBody: [String: Any] = [
      "summary": intent.title,
      "start": ["dateTime": iso.string(from: startDate)],
      "end": ["dateTime": iso.string(from: endDate)],
    ]
    if let notes = intent.notes, !notes.isEmpty {
      eventBody["description"] = notes
    }
    if let attendees = intent.attendees, !attendees.isEmpty {
      eventBody["attendees"] = attendees.map { ["email": $0] }
    }

    let encodedCalendarId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
    let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarId)/events")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15
    request.httpBody = try JSONSerialization.data(withJSONObject: eventBody)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      let bodyText = String(data: data, encoding: .utf8) ?? ""
      actionLogger.error("Google Calendar event creation failed (iOS) \(code, privacy: .public): \(bodyText, privacy: .private)")
      captureError(
        IOSActionError.apiError("Google Calendar", code),
        context: ErrorContext.feature("google_calendar")
          .tag("platform", "ios")
          .tag("op", "create_event")
          .tag("status", String(code))
      )
      throw IOSActionError.apiError("Google Calendar", code)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let eventId = json["id"] as? String
    else {
      throw IOSActionError.invalidResponse("Google Calendar")
    }

    actionLogger.info("Created Google Calendar event (iOS) id=\(eventId, privacy: .public)")
    return eventId
  }
}

private func fetchCalendarList(accessToken: String) async -> [IOSGoogleCalendar] {
  let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
  var request = URLRequest(url: url)
  request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
  request.timeoutInterval = 15

  guard let (data, response) = try? await URLSession.shared.data(for: request),
        let http = response as? HTTPURLResponse,
        http.statusCode == 200,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let items = json["items"] as? [[String: Any]]
  else {
    return []
  }

  return items.compactMap { item in
    guard let id = item["id"] as? String,
          let name = item["summary"] as? String
    else { return nil }
    return IOSGoogleCalendar(id: id, name: name)
  }
}
