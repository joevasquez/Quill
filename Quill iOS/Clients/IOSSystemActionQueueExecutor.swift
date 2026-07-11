//
//  IOSSystemActionQueueExecutor.swift
//  Quill (iOS)
//
//  iOS-side ActionQueueExecutor — routes an ActionIntent to the right
//  executor. Installed once at app launch by `QuilliOSApp.init`, and used
//  directly by the confirmation sheets.
//
//  Routing is actionType-first: `.mcpCall` and `.open` carry a placeholder
//  `targetIntegration` (the shared planner schema requires one) so they
//  must be dispatched on `actionType` BEFORE the integration switch.
//  Everything else routes by integration: Reminders, Apple Calendar,
//  Todoist, Gmail, and Google Calendar.
//

import Foundation
import HexCore

@MainActor
public final class IOSSystemActionQueueExecutor: ActionQueueExecutor {
  public init() {}

  public func execute(_ intent: ActionIntent) async throws {
    _ = try await Self.executeReturningOutput(intent)
  }

  /// Executes the intent and returns its text output — MCP tool results
  /// and open-summaries feed dependent steps and the completion panel;
  /// integration adapters return a short created-item summary.
  static func executeReturningOutput(_ intent: ActionIntent) async throws -> String {
    switch intent.actionType {
    case .mcpCall:
      return try await IOSMCPActionExecutor.execute(intent)
    case .open:
      return try await IOSOpenActionExecutor.execute(intent)
    default:
      break
    }

    switch intent.targetIntegration {
    case .appleReminders:
      _ = try await IOSRemindersAdapter.createReminder(intent)
    case .calendar:
      _ = try await IOSCalendarAdapter.createEvent(intent)
    case .todoist:
      _ = try await IOSTodoistAdapter.createTask(intent)
    case .gmail:
      _ = try await IOSGmailAdapter.createDraft(intent)
    case .googleCalendar:
      _ = try await IOSGoogleCalendarAdapter.createEvent(intent)
    default:
      throw IOSActionError.invalidResponse(intent.targetIntegration.rawValue)
    }
    return intent.title
  }
}
