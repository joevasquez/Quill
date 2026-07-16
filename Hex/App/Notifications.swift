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
  /// Posted when the display mode changes (HUD ↔ Orb ↔ Chip) so the
  /// AppKit-side status item can swap its label.
  static let displayModeChanged = NSNotification.Name("DisplayModeChanged")
  /// Posted when the user switches transcription mode (cycle hotkey or the
  /// menu Mode submenu). Carries the new mode's rawValue so the AppKit-side
  /// mode-switch HUD can show a brief bubble when the menu bar is hidden
  /// (full-screen app) and the status-item feather/chip isn't visible.
  static let modeDidChange = NSNotification.Name("ModeDidChange")
}

enum ModeChangeNotification {
  static let modeNameKey = "modeName"

  static func post(modeName: String) {
    NotificationCenter.default.post(
      name: .modeDidChange,
      object: nil,
      userInfo: [modeNameKey: modeName]
    )
  }
}

enum ActionConfirmationNotification {
  static let intentKey = "actionIntent"
  static let intentsKey = "actionIntents"
  static let rawTranscriptKey = "rawTranscript"
  /// When true the panel executes immediately on appear — used by routines
  /// the user has promoted to auto-run on the trust ladder.
  static let autoExecuteKey = "autoExecute"
  /// Bundle ID of the app frontmost at record-start, so the panel can paste an
  /// extracted answer back where the user was typing.
  static let sourceAppBundleIDKey = "sourceAppBundleID"

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

  static func postMulti(intents: [ActionIntent], rawTranscript: String = "", autoExecute: Bool = false, sourceAppBundleID: String? = nil) {
    NotificationCenter.default.post(
      name: .presentMultiActionConfirmation,
      object: nil,
      userInfo: [
        intentsKey: intents,
        rawTranscriptKey: rawTranscript,
        autoExecuteKey: autoExecute,
        sourceAppBundleIDKey: sourceAppBundleID as Any,
      ]
    )
  }
}
