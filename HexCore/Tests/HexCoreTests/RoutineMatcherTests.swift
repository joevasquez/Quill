import XCTest
@testable import HexCore

final class RoutineMatcherTests: XCTestCase {
  private let shipIt = Routine(
    name: "Release checklist",
    triggerPhrases: ["ship it"],
    steps: [ActionIntent(actionType: .createTask, targetIntegration: .todoist, title: "Run the release checklist")]
  )
  private let monday = Routine(
    name: "Monday standup",
    triggerPhrases: ["monday standup", "run my monday"],
    steps: [ActionIntent(actionType: .createReminder, title: "Post standup summary")]
  )

  func testExactPhraseMatches() {
    XCTAssertEqual(RoutineMatcher.match(transcript: "Ship it", routines: [shipIt, monday])?.id, shipIt.id)
  }

  func testPunctuationAndCaseInsensitive() {
    XCTAssertEqual(RoutineMatcher.match(transcript: "Ship it!", routines: [shipIt])?.id, shipIt.id)
  }

  func testLeadingAndTrailingFillerStripped() {
    XCTAssertEqual(RoutineMatcher.match(transcript: "run my ship it please", routines: [shipIt])?.id, shipIt.id)
    XCTAssertEqual(RoutineMatcher.match(transcript: "Run my Monday", routines: [monday])?.id, monday.id)
    XCTAssertEqual(RoutineMatcher.match(transcript: "monday standup routine", routines: [monday])?.id, monday.id)
  }

  func testMidSentenceTriggerDoesNotFire() {
    // A trigger embedded in a longer command is a normal LLM parse, not a routine.
    XCTAssertNil(RoutineMatcher.match(transcript: "remind me to ship it tomorrow", routines: [shipIt]))
  }

  func testNoMatchReturnsNil() {
    XCTAssertNil(RoutineMatcher.match(transcript: "add buy milk to my reminders", routines: [shipIt, monday]))
    XCTAssertNil(RoutineMatcher.match(transcript: "", routines: [shipIt]))
  }

  func testAuthoringDetection() {
    XCTAssertEqual(
      RoutineMatcher.authoringRequest(transcript: "New routine: when I say ship it, run the checklist", agentName: "Hermes"),
      "when i say ship it run the checklist"
    )
    XCTAssertEqual(
      RoutineMatcher.authoringRequest(transcript: "Hermes, create a routine when I say wrap up email the team", agentName: "Hermes"),
      "when i say wrap up email the team"
    )
    XCTAssertNil(RoutineMatcher.authoringRequest(transcript: "remind me to make a routine for the gym", agentName: "Hermes"))
    XCTAssertNil(RoutineMatcher.authoringRequest(transcript: "add buy milk", agentName: "Hermes"))
  }
}
