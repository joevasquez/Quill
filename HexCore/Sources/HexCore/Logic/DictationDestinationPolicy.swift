/// Evidence returned by the platform paste adapter. `unverified` is a real
/// state for Citrix, browsers, and other apps where a Cmd-V cannot be read
/// back; it must not be treated as failure or Quill will create duplicates.
public enum DictationPasteOutcome: Equatable, Sendable {
  case notAttempted
  case inserted
  case unverified
  case clipboardOnly
  case targetUnavailable
}

public enum DictationDestination: Equatable, Sendable {
  case externalTarget
  case newQuillNote
  case action
  case discard
}

public enum DictationDestinationPolicy {
  public static func route(
    mode: TranscriptionMode,
    target: EditableTarget,
    pasteOutcome: DictationPasteOutcome,
    hasSpeech: Bool
  ) -> DictationDestination {
    guard hasSpeech else { return .discard }
    guard mode != .action else { return .action }
    if target == .notEditable || pasteOutcome == .targetUnavailable {
      return .newQuillNote
    }
    return .externalTarget
  }
}
