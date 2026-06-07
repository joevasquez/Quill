import Foundation

/// A third-party surface Quill can send dictations to. Frontend-only
/// placeholder as of 0.9 — shipping the catalog + connection state
/// first so the Settings UI can show what's planned and start
/// collecting user intent. Actual OAuth flows and per-integration
/// send adapters land in a follow-up.
public struct Integration: Identifiable, Equatable, Hashable, Sendable {
  public enum Identifier: String, CaseIterable, Sendable {
    case todoist
    case appleReminders
    case calendar
    case googleCalendar
    case gmail
    case notion
    case things
    case slack
    case linear
  }

  public let identifier: Identifier
  public let name: String
  public let systemImage: String
  public let tintHex: String  // hex color string for the icon tile
  public let tagline: String
  public let requiresPro: Bool

  public var id: String { identifier.rawValue }

  /// OKLCH-style hue (0–360) for the orb satellite ring accent colour.
  public var satelliteHue: Double {
    switch identifier {
    case .todoist:        return 12
    case .appleReminders: return 25
    case .calendar:       return 255
    case .googleCalendar: return 145
    case .gmail:          return 330
    case .notion:         return 0
    case .things:         return 220
    case .slack:          return 290
    case .linear:         return 250
    }
  }

  /// Keywords the destination classifier scans for when intuiting the
  /// target app from partial transcript text. Ordered by priority —
  /// explicit app names should appear before generic verbs.
  public var intuitKeywords: [String] {
    switch identifier {
    case .todoist:        return ["todoist"]
    case .appleReminders: return ["remind", "reminder", "reminders"]
    case .calendar:       return ["calendar", "schedule", "meeting", "invite", "event", "block"]
    case .googleCalendar: return ["google cal", "gcal", "google calendar"]
    case .gmail:          return ["gmail", "email", "e-mail", "mail", "draft"]
    case .notion:         return ["notion"]
    case .things:         return ["things"]
    case .slack:          return ["slack", "message", "dm"]
    case .linear:         return ["linear", "issue", "ticket", "bug"]
    }
  }

  public static let all: [Integration] = [
    .init(
      identifier: .todoist,
      name: "Todoist",
      systemImage: "checkmark.circle.fill",
      tintHex: "#E44332",
      tagline: "Turn dictations into tasks with natural due dates — \"remind me Friday to review the launch deck\".",
      requiresPro: false
    ),
    .init(
      identifier: .appleReminders,
      name: "Apple Reminders",
      systemImage: "list.bullet.circle.fill",
      tintHex: "#FF9500",
      tagline: "Native iCloud Reminders — picked list, smart due dates from your dictation.",
      requiresPro: false
    ),
    .init(
      identifier: .calendar,
      name: "Apple Calendar",
      systemImage: "calendar",
      tintHex: "#FF2D55",
      tagline: "Create calendar events from dictation — \"schedule a meeting with John on Friday at 2pm\".",
      requiresPro: false
    ),
    .init(
      identifier: .googleCalendar,
      name: "Google Calendar",
      systemImage: "calendar.badge.clock",
      tintHex: "#4285F4",
      tagline: "Direct Google Calendar API — create events, check availability, manage calendars.",
      requiresPro: true
    ),
    .init(
      identifier: .gmail,
      name: "Gmail",
      systemImage: "envelope.fill",
      tintHex: "#EA4335",
      tagline: "Draft emails from dictation — \"email Mike about the quarterly review\" becomes a Gmail draft.",
      requiresPro: true
    ),
    .init(
      identifier: .notion,
      name: "Notion",
      systemImage: "n.square.fill",
      tintHex: "#000000",
      tagline: "Append dictations to a chosen Notion database (journal, meeting log, inbox).",
      requiresPro: true
    ),
    .init(
      identifier: .things,
      name: "Things",
      systemImage: "star.circle.fill",
      tintHex: "#1A6DFF",
      tagline: "Send dictated to-dos into your Things inbox via the Things URL scheme.",
      requiresPro: true
    ),
    .init(
      identifier: .slack,
      name: "Slack",
      systemImage: "message.circle.fill",
      tintHex: "#4A154B",
      tagline: "Post dictated messages to a channel or DM — \"send Amanda 'can we move tomorrow to 3pm?'\".",
      requiresPro: true
    ),
    .init(
      identifier: .linear,
      name: "Linear",
      systemImage: "cube.fill",
      tintHex: "#5E6AD2",
      tagline: "Capture issues from a dictation — project / team / priority parsed automatically.",
      requiresPro: true
    ),
  ]
}

/// The user's connection state per integration. Persisted as a simple
/// `Set<Integration.Identifier>` under `connectedIntegrations` in
/// `HexSettings` (macOS) or UserDefaults (iOS).
public enum IntegrationConnectionStore {
  public static let userDefaultsKey = "quill.connectedIntegrations"

  public static func encode(_ ids: Set<Integration.Identifier>) -> Data {
    let strings = ids.map { $0.rawValue }
    return (try? JSONEncoder().encode(strings)) ?? Data()
  }

  public static func decode(_ data: Data?) -> Set<Integration.Identifier> {
    guard let data, !data.isEmpty,
          let strings = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return Set(strings.compactMap { Integration.Identifier(rawValue: $0) })
  }
}

/// Free-tier policy. Limits the number of simultaneously-connected
/// integrations so Pro has a concrete upsell hook. Surface in UI as
/// a message + disable the Connect button when at cap.
public enum IntegrationLimits {
  public static let freeTierMaxConnections = 2
}
