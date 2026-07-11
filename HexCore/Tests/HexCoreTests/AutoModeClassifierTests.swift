import XCTest
@testable import HexCore

final class AutoModeClassifierTests: XCTestCase {
  // MARK: - resolve

  func testActionKeywordsRouteToAction() {
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "Remind me to call the dentist tomorrow", hasSelection: false, hasIntegrations: true),
      .action
    )
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "Add buy milk to my Todoist", hasSelection: false, hasIntegrations: true),
      .action
    )
  }

  func testActionRequiresIntegrations() {
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "Remind me to call the dentist", hasSelection: false, hasIntegrations: false),
      .dictate
    )
  }

  func testEditRequiresSelection() {
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "Make this more professional", hasSelection: true, hasIntegrations: true),
      .edit
    )
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "Make this more professional", hasSelection: false, hasIntegrations: true),
      .dictate
    )
  }

  func testActionBeatsEditWhenBothMatch() {
    // "add to" (action) + "convert to" (edit) — action wins, checked first.
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "Convert to a task and add to Todoist", hasSelection: true, hasIntegrations: true),
      .action
    )
  }

  func testPlainDictationStaysDictate() {
    XCTAssertEqual(
      AutoModeClassifier.resolve(
        transcript: "Today we discussed the quarterly roadmap and hiring plans",
        hasSelection: false,
        hasIntegrations: true
      ),
      .dictate
    )
  }

  // MARK: - classifyPartial

  func testClassifyPartialDetectsActionMidStream() {
    XCTAssertEqual(AutoModeClassifier.classifyPartial("remind me to"), .action)
    XCTAssertEqual(AutoModeClassifier.classifyPartial("shorten this by"), .edit)
    XCTAssertEqual(AutoModeClassifier.classifyPartial("the meeting went"), .dictate)
  }
}
