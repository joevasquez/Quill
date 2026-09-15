import Testing
@testable import HexCore

@Suite("Dictation destination fallback")
struct DictationDestinationPolicyTests {
  @Test("confidently non-editable targets become a Quill note")
  func nonEditableCreatesNote() {
    #expect(DictationDestinationPolicy.route(
      mode: .dictate,
      target: .notEditable,
      pasteOutcome: .notAttempted,
      hasSpeech: true
    ) == .newQuillNote)
  }

  @Test("unknown targets preserve the paste path for Citrix and browsers")
  func unknownDoesNotDuplicate() {
    #expect(DictationDestinationPolicy.route(
      mode: .dictate,
      target: .unknown,
      pasteOutcome: .unverified,
      hasSpeech: true
    ) == .externalTarget)
  }

  @Test("a definitive unavailable target becomes a note")
  func unavailableCreatesNote() {
    #expect(DictationDestinationPolicy.route(
      mode: .dictate,
      target: .unknown,
      pasteOutcome: .targetUnavailable,
      hasSpeech: true
    ) == .newQuillNote)
  }

  @Test("actions never become notes")
  func actionStaysAction() {
    #expect(DictationDestinationPolicy.route(
      mode: .action,
      target: .notEditable,
      pasteOutcome: .targetUnavailable,
      hasSpeech: true
    ) == .action)
  }

  @Test("silence does not create an empty note")
  func silenceDoesNothing() {
    #expect(DictationDestinationPolicy.route(
      mode: .dictate,
      target: .notEditable,
      pasteOutcome: .notAttempted,
      hasSpeech: false
    ) == .discard)
  }
}
