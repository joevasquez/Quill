//
//  SystemActionQueueExecutor.swift
//  Quill (macOS)
//
//  Implements `ActionQueueExecutor` by routing a queued ActionIntent to
//  the right TCA-backed adapter. Installed once at app launch by
//  `HexAppDelegate`. The actual queueing decision (and the enqueue call
//  itself) happens in `ActionConfirmationFeature.execute` — this just
//  knows how to replay an item.
//

import Dependencies
import Foundation
import HexCore

public final class SystemActionQueueExecutor: ActionQueueExecutor {
  public init() {}

  public func execute(_ intent: ActionIntent) async throws {
    @Dependency(\.reminders) var reminders
    @Dependency(\.calendarAdapter) var calendarAdapter
    @Dependency(\.todoist) var todoist
    @Dependency(\.gmailAdapter) var gmailAdapter
    @Dependency(\.googleCalendarAdapter) var googleCalendarAdapter

    // MCP calls route by server name, not integration.
    if intent.actionType == .mcpCall {
      _ = try await MCPActionExecutor.execute(intent)
      return
    }
    // A composed reply has no side effect to replay — it only ever existed
    // to be shown and copied. Reaching here means the *parse* was queued
    // offline and resolved to a compose, so the text has nowhere to go: log
    // it rather than throwing, since there's nothing to retry.
    if intent.actionType == .composeReply {
      HexLog.action.notice("Queued action resolved to a composed reply — nothing to replay, dropping")
      return
    }
    // Open actions are macOS-native (NSWorkspace), not integration-routed.
    if intent.actionType == .open {
      _ = try await OpenActionExecutor.execute(intent)
      return
    }

    switch intent.targetIntegration {
    case .appleReminders:
      _ = try await reminders.createReminder(intent)
    case .calendar:
      _ = try await calendarAdapter.createEvent(intent)
    case .todoist:
      _ = try await todoist.createTask(intent)
    case .gmail:
      _ = try await gmailAdapter.createDraft(intent)
    case .googleCalendar:
      _ = try await googleCalendarAdapter.createEvent(intent)
    default:
      // Match the live confirmation panel's error so logs are consistent.
      throw ActionConfirmationError.unsupportedIntegration(intent.targetIntegration)
    }
  }
}
