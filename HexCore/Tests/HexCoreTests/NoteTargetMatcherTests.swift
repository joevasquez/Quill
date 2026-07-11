import XCTest
@testable import HexCore

final class NoteTargetMatcherTests: XCTestCase {
  func testContentFirstForm() {
    let m = NoteTargetMatcher.match("Add milk and eggs to my groceries note")
    XCTAssertEqual(m, .init(noteName: "groceries", content: "milk and eggs"))
  }

  func testTargetFirstForm() {
    let m = NoteTargetMatcher.match("Add to my groceries note: milk and eggs")
    XCTAssertEqual(m, .init(noteName: "groceries", content: "milk and eggs"))
  }

  func testAppendVerbAndTheArticle() {
    let m = NoteTargetMatcher.match("Append call Sarah back to the follow-ups note.")
    XCTAssertEqual(m, .init(noteName: "follow-ups", content: "call Sarah back"))
  }

  func testMultiWordNoteName() {
    let m = NoteTargetMatcher.match("Put review the Q3 numbers in my board meeting note")
    XCTAssertEqual(m, .init(noteName: "board meeting", content: "review the Q3 numbers"))
  }

  func testListPhrasingDoesNotMatch() {
    // "groceries list" belongs to the agent (Reminders/Todoist), not notes.
    XCTAssertNil(NoteTargetMatcher.match("Add milk to my groceries list"))
  }

  func testPlainDictationDoesNotMatch() {
    XCTAssertNil(NoteTargetMatcher.match("Today we talked about the launch timeline"))
    XCTAssertNil(NoteTargetMatcher.match("Remind me to call the dentist tomorrow"))
  }

  func testPreservesContentCasing() {
    let m = NoteTargetMatcher.match("add Email Mike about NDA to my legal note")
    XCTAssertEqual(m?.content, "Email Mike about NDA")
  }
}
