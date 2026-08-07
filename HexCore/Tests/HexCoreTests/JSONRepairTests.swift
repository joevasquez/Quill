import Foundation
import Testing
@testable import HexCore

@Suite("JSON repair")
struct JSONRepairTests {
  /// The failure this exists for: a drafted reply with paragraph breaks
  /// written as real newlines instead of `\n`.
  @Test func escapesRawNewlinesInsideStrings() throws {
    let broken = "{\"actions\":[{\"notes\":\"Line one.\n\nLine two.\"}]}"
    #expect((try? JSONSerialization.jsonObject(with: Data(broken.utf8))) == nil)

    let repaired = JSONRepair.escapingControlCharactersInStrings(broken)
    let object = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
    let actions = try #require(object?["actions"] as? [[String: Any]])
    #expect(actions.first?["notes"] as? String == "Line one.\n\nLine two.")
  }

  /// Must be a no-op on anything already valid — it runs on the failure
  /// path, but it should be safe if that ever changes.
  @Test func leavesValidJSONUnchanged() {
    let valid = "{\"a\":\"already \\n escaped\",\"b\":[1,2],\"c\":\"tab\\there\"}"
    #expect(JSONRepair.escapingControlCharactersInStrings(valid) == valid)
  }

  /// Newlines between tokens are legal JSON whitespace and must survive.
  @Test func preservesStructuralWhitespace() throws {
    let pretty = "{\n  \"a\": \"x\",\n  \"b\": 2\n}"
    let repaired = JSONRepair.escapingControlCharactersInStrings(pretty)
    #expect(repaired == pretty)
    #expect((try? JSONSerialization.jsonObject(with: Data(repaired.utf8))) != nil)
  }

  /// An escaped quote must not be mistaken for the end of the string — the
  /// classic way a naive scanner loses track of where it is.
  @Test func handlesEscapedQuotes() throws {
    let broken = "{\"q\":\"he said \\\"hi\\\"\nthen left\"}"
    let repaired = JSONRepair.escapingControlCharactersInStrings(broken)
    let object = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: String]
    #expect(object?["q"] == "he said \"hi\"\nthen left")
  }

  /// A trailing backslash inside a string is its own escape payload.
  @Test func handlesEscapedBackslash() throws {
    let broken = "{\"p\":\"C:\\\\path\nnext\"}"
    let repaired = JSONRepair.escapingControlCharactersInStrings(broken)
    let object = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: String]
    #expect(object?["p"] == "C:\\path\nnext")
  }

  /// End to end through the real decoder, with the shape the action
  /// planner actually emits.
  @Test func decodesARepliedDraftWithRawNewlines() throws {
    let broken = """
    {"actions":[{"actionType":"composeReply","targetIntegration":"appleReminders","title":"Reply about intros","notes":"Thanks for the note.

    I haven't forgotten the introductions.","dueDate":null,"listName":null,"priority":null,"duration":null,"attendees":null,"recipient":null,"subject":null}]}
    """
    let response = try AgentParsing.decodeMultiOrSingle(broken)
    #expect(response.actions.count == 1)
    #expect(response.actions.first?.actionType == .composeReply)
    #expect(response.actions.first?.notes?.contains("\n\nI haven't") == true)
  }
}

@Suite("Compose salvage")
struct ComposeSalvageTests {
  /// The observed failure: asked to draft a response, the model answered
  /// the message directly instead of returning JSON.
  @Test func salvagesProseOnAComposeRequest() throws {
    let prose = "I'll give it another try and let you know if it still fails."
    let response = try AgentParsing.decodeMultiOrSingle("{\"actions\":[]}")
    #expect(response.actions.isEmpty)  // sanity: normal path untouched

    let intent = try #require(ComposeSalvage.intent(
      forTranscript: "Draft a response to this message.", modelReply: prose
    ))
    #expect(intent.actionType == .composeReply)
    #expect(intent.notes == prose)
  }

  /// An unrelated command that failed for some other reason must still
  /// surface as an error, not as a fabricated draft.
  @Test func ignoresNonComposeRequests() {
    #expect(ComposeSalvage.intent(
      forTranscript: "remind me to call Mike tomorrow", modelReply: "Sorry, I can't help with that."
    ) == nil)
  }

  /// A reply that starts like JSON was a failed attempt at the contract —
  /// salvaging it as prose would hand the user braces and hide a real bug.
  @Test func ignoresRepliesThatLookLikeJSON() {
    #expect(ComposeSalvage.intent(
      forTranscript: "draft a response to this", modelReply: "{\"actions\":[{\"bad\""
    ) == nil)
    #expect(ComposeSalvage.intent(
      forTranscript: "draft a response to this", modelReply: "   "
    ) == nil)
  }

  /// End to end: prose in, drafted-reply action out.
  @Test func parseMultiSalvagesInsteadOfThrowing() async throws {
    let response = try await AgentParsing.parseMulti(
      transcript: "Draft a response to this message.",
      selection: "Thanks for the chat!",
      memoryContext: nil,
      mcpContext: nil,
      complete: { _, _ in "Thanks — I enjoyed it too.\n\nLet's find time again soon." }
    )
    #expect(response.actions.count == 1)
    #expect(response.actions.first?.actionType == .composeReply)
    #expect(response.actions.first?.notes?.contains("enjoyed it too") == true)
  }
}

@Suite("Compose needs a selection")
struct ComposeNeedsSelectionTests {
  @Test func flagsDeicticComposeRequests() {
    #expect(ComposeSalvage.isComposeAboutSelection("Draft a response to this message."))
    #expect(ComposeSalvage.isComposeAboutSelection("draft a response to what I've highlighted"))
    #expect(ComposeSalvage.isComposeAboutSelection("write a reply to this"))
  }

  /// A self-contained command names its own subject — it must still run
  /// without anything highlighted.
  @Test func allowsSelfContainedComposeRequests() {
    #expect(!ComposeSalvage.isComposeAboutSelection("draft an email to Mike about the Q3 numbers"))
    #expect(!ComposeSalvage.isComposeAboutSelection("write a thank you note to Sarah"))
  }

  /// Non-compose commands are none of this check's business.
  @Test func ignoresNonComposeCommands() {
    #expect(!ComposeSalvage.isComposeAboutSelection("add this to my Todoist list"))
    #expect(!ComposeSalvage.isComposeAboutSelection("remind me to call Mike"))
  }
}

@Suite("Auto mode routes composes to Action")
struct AutoComposeRoutingTests {
  /// The bug: with a selection captured, "draft a response to this" hit the
  /// Edit path, which REPLACES the selection — overwriting the message the
  /// user wanted a reply to.
  @Test func composeWithSelectionGoesToActionNotEdit() {
    #expect(AutoModeClassifier.resolve(
      transcript: "Draft a response to this message.",
      hasSelection: true, hasIntegrations: false
    ) == .action)
  }

  /// Needs no integrations — a compose goes to no service at all, so the
  /// `hasIntegrations` gate must not apply to it.
  @Test func composeNeedsNoIntegrations() {
    #expect(AutoModeClassifier.resolve(
      transcript: "write a reply to this", hasSelection: true, hasIntegrations: false
    ) == .action)
    #expect(AutoModeClassifier.classifyPartial("draft a response to this") == .action)
  }

  /// Real edit commands must still reach Edit.
  @Test func editCommandsStillRouteToEdit() {
    #expect(AutoModeClassifier.resolve(
      transcript: "make this more concise", hasSelection: true, hasIntegrations: true
    ) == .edit)
    #expect(AutoModeClassifier.resolve(
      transcript: "translate this to Spanish", hasSelection: true, hasIntegrations: false
    ) == .edit)
  }

  /// And plain dictation is untouched.
  @Test func plainDictationIsUnaffected() {
    #expect(AutoModeClassifier.resolve(
      transcript: "the quarterly numbers came in strong this week",
      hasSelection: false, hasIntegrations: true
    ) == .dictate)
  }
}
