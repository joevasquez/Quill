import Foundation

public struct ActionIntent: Codable, Equatable, Sendable {
  public enum ActionType: String, Codable, Sendable {
    case createReminder
    case createTask
    case createEvent
    case createDraft
    case sendEmail
    /// Invoke a tool on a user-connected MCP server. Uses the mcp* fields
    /// below; `targetIntegration` is ignored for this type.
    case mcpCall
  }

  public var actionType: ActionType
  public var targetIntegration: Integration.Identifier
  public var title: String
  public var dueDate: String?
  public var notes: String?
  public var listName: String?
  /// Todoist priority: 1 (lowest) … 4 (highest). nil → use service default.
  public var priority: Int?
  /// Calendar event duration in minutes. nil → default 60.
  public var duration: Int?
  /// Calendar event attendee emails.
  public var attendees: [String]?
  /// Calendar event start date — set by the confirmation panel after the user edits the date picker. Takes precedence over `dueDate`/`duration` when present.
  public var startDate: Date?
  /// Calendar event end date — set by the confirmation panel.
  public var endDate: Date?
  /// Email recipient (name or address). Parsed from "email Mike" or "email john@acme.com".
  public var recipient: String?
  /// Email subject line, if dictated explicitly.
  public var subject: String?
  /// MCP call fields (actionType == .mcpCall): the user-assigned server
  /// name, the tool to invoke, and its arguments. Arguments are stored as
  /// strings and coerced to the tool's schema types at call time.
  public var mcpServerName: String?
  public var mcpTool: String?
  public var mcpArguments: [String: String]?

  public init(
    actionType: ActionType,
    targetIntegration: Integration.Identifier = .appleReminders,
    title: String,
    dueDate: String? = nil,
    notes: String? = nil,
    listName: String? = nil,
    priority: Int? = nil,
    duration: Int? = nil,
    attendees: [String]? = nil,
    startDate: Date? = nil,
    endDate: Date? = nil,
    recipient: String? = nil,
    subject: String? = nil,
    mcpServerName: String? = nil,
    mcpTool: String? = nil,
    mcpArguments: [String: String]? = nil
  ) {
    self.actionType = actionType
    self.targetIntegration = targetIntegration
    self.title = title
    self.dueDate = dueDate
    self.notes = notes
    self.listName = listName
    self.priority = priority
    self.duration = duration
    self.attendees = attendees
    self.startDate = startDate
    self.endDate = endDate
    self.recipient = recipient
    self.subject = subject
    self.mcpServerName = mcpServerName
    self.mcpTool = mcpTool
    self.mcpArguments = mcpArguments
  }
}

extension Integration.Identifier: Codable {}
