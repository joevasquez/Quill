import Foundation
import HexCore

extension NSNotification.Name {
  /// Posted when app mode settings change (dock icon visibility, etc.)
  static let updateAppMode = NSNotification.Name("UpdateAppMode")
  /// Posted when an action intent is parsed and ready for user confirmation.
  static let presentActionConfirmation = NSNotification.Name("PresentActionConfirmation")
  /// Posted when multiple action intents are parsed and ready for user confirmation.
  static let presentMultiActionConfirmation = NSNotification.Name("PresentMultiActionConfirmation")
  /// Posted when an action is successfully executed.
  static let actionConfirmationExecuted = NSNotification.Name("ActionConfirmationExecuted")
  /// Posted when an action confirmation is cancelled.
  static let actionConfirmationCancelled = NSNotification.Name("ActionConfirmationCancelled")
  /// Posted when HUD position mode changes (floating ↔ pinned).
  static let hudPositionModeChanged = NSNotification.Name("HUDPositionModeChanged")
}

enum ActionConfirmationNotification {
  static let intentKey = "actionIntent"
  static let intentsKey = "actionIntents"
  static let rawTranscriptKey = "rawTranscript"
  /// When true the panel executes immediately on appear — used by routines
  /// the user has promoted to auto-run on the trust ladder.
  static let autoExecuteKey = "autoExecute"

  static func post(intent: ActionIntent, rawTranscript: String = "") {
    NotificationCenter.default.post(
      name: .presentActionConfirmation,
      object: nil,
      userInfo: [
        intentKey: intent,
        rawTranscriptKey: rawTranscript,
      ]
    )
  }

  static func postMulti(intents: [ActionIntent], rawTranscript: String = "", autoExecute: Bool = false) {
    NotificationCenter.default.post(
      name: .presentMultiActionConfirmation,
      object: nil,
      userInfo: [
        intentsKey: intents,
        rawTranscriptKey: rawTranscript,
        autoExecuteKey: autoExecute,
      ]
    )
  }
}
