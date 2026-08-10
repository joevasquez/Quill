import XCTest
@testable import HexCore

final class SelectionInstructionTests: XCTestCase {

  // MARK: - Positives: verbs nobody wrote into a keyword list

  func testImperativePlusDeicticIsAnEditInstruction() {
    let instructions = [
      "Convert this into bullets, please.",
      "Turn this into a table",
      "Reword this",
      "Make this shorter",
      "Summarize this",
      "Tighten this up a bit",
      "Translate this to Spanish",
      "Rewrite these as questions",
    ]
    for text in instructions {
      XCTAssertTrue(
        SelectionInstruction.isEditInstruction(text),
        "expected an edit instruction: \"\(text)\""
      )
    }
  }

  /// Politeness and filler before the verb must not hide the imperative.
  func testLeadingFillerIsSkipped() {
    let instructions = [
      "Please convert this into bullets",
      "Hey, shorten this",
      "Now clean this up",
      "Just make this shorter",
    ]
    for text in instructions {
      XCTAssertTrue(
        SelectionInstruction.isEditInstruction(text),
        "expected an edit instruction: \"\(text)\""
      )
    }
  }

  // MARK: - Negatives: prose that merely mentions "this"

  /// The rule's whole safety margin. These all contain a deictic; what saves
  /// them is that they don't OPEN with a verb. If leading pronouns or nouns
  /// were skipped while hunting for a verb, every one of these would become
  /// an edit — and Edit overwrites the user's selection.
  func testProseMentioningThisIsNotAnInstruction() {
    let prose = [
      "I talked to him about this today",
      "Today we discussed this at length",
      "This is a good idea and we should do it",
      "We should probably revisit this next quarter",
      "My take on this is that it needs more work",
    ]
    for text in prose {
      XCTAssertFalse(
        SelectionInstruction.isEditInstruction(text),
        "expected plain dictation: \"\(text)\""
      )
    }
  }

  /// An imperative with no deictic isn't aimed at the selection.
  func testImperativeWithoutDeicticIsNotAnInstruction() {
    XCTAssertFalse(SelectionInstruction.isEditInstruction("Summarize the meeting notes"))
    XCTAssertFalse(SelectionInstruction.isEditInstruction("Write a follow-up email to the team"))
  }

  /// Dispatch verbs mean "put this somewhere", not "change this text".
  /// Claiming them as edits would rewrite the selection instead of routing.
  func testDispatchVerbsAreNotEdits() {
    let dispatches = [
      "Send this to Mike",
      "Share this with the team",
      "Save this for later",
      "Post this to Slack",
    ]
    for text in dispatches {
      XCTAssertFalse(
        SelectionInstruction.isEditInstruction(text),
        "expected NOT an edit: \"\(text)\""
      )
    }
  }

  // MARK: - Boundaries

  func testDeicticMatchesOnWordBoundaries() {
    XCTAssertTrue(SelectionInstruction.containsDeictic("shorten this"))
    // "this" inside a longer word must not count.
    XCTAssertFalse(SelectionInstruction.containsDeictic("prune the thistle"))
  }

  func testEmptyAndNonsenseInputsAreSafe() {
    XCTAssertFalse(SelectionInstruction.isEditInstruction(""))
    XCTAssertFalse(SelectionInstruction.isEditInstruction("   "))
    XCTAssertFalse(SelectionInstruction.isEditInstruction("this"))
  }

  // MARK: - Integration with the classifier

  /// The rule only applies with a selection; without one the same words are
  /// ordinary dictation.
  func testClassifierUsesItOnlyWhenASelectionExists() {
    XCTAssertEqual(
      AutoModeClassifier.resolve(
        transcript: "Turn this into a table", hasSelection: true, hasIntegrations: true
      ),
      .edit
    )
    XCTAssertEqual(
      AutoModeClassifier.resolve(
        transcript: "Turn this into a table", hasSelection: false, hasIntegrations: true
      ),
      .dictate
    )
  }

  /// Action keywords are still checked first, so a command that happens to
  /// open with a verb and point at something still routes to the agent.
  func testActionKeywordsStillWinOverTheShapeRule() {
    XCTAssertEqual(
      AutoModeClassifier.resolve(
        transcript: "Add this to my Todoist", hasSelection: true, hasIntegrations: true
      ),
      .action
    )
  }
}
