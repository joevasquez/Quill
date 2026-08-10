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

  // MARK: - Reminder phrasings

  /// The phrasings the old enumerated list missed. Each of these is an
  /// obvious command that landed in a note.
  func testReminderPhrasingsRouteToAction() {
    let commands = [
      "Add a reminder I need to go to the beach tomorrow",
      "Set a reminder for the dentist",
      "New reminder: pick up the dry cleaning",
      "Remind me to call Mike",
      "Can you remind us about standup",
    ]
    for command in commands {
      XCTAssertEqual(
        AutoModeClassifier.resolve(transcript: command, hasSelection: false, hasIntegrations: true),
        .action,
        "expected Action for \"\(command)\""
      )
    }
  }

  // MARK: - Word boundaries

  /// A bare `contains` matched action keywords inside longer words, so
  /// ordinary prose routed to Action. No selection here, to isolate the
  /// action path from the edit one.
  func testActionKeywordsDoNotMatchInsideOtherWords() {
    let dictations = [
      "I need to fix the schedule for things next week",  // schedule / things
      "The composer decomposed the theme",                // compose
      "I rescheduled the sync and reminded everyone",     // schedule / remind
    ]
    for dictation in dictations {
      XCTAssertEqual(
        AutoModeClassifier.resolve(transcript: dictation, hasSelection: false, hasIntegrations: true),
        .dictate,
        "expected Dictate for \"\(dictation)\""
      )
    }
  }

  /// Same collision class on the edit side. A selection is present, which is
  /// what makes these dangerous — Edit replaces it.
  ///
  /// Note "fix" as a whole word still routes to Edit with a selection, which
  /// is correct: that IS an edit instruction. Only the substring hits are bugs.
  func testEditKeywordsDoNotMatchInsideOtherWords() {
    let dictations = [
      "We prefixed every field and then fixed the bug",  // fix
      "The expanded roadmap was well received",          // expand
      "She summarized it before I rephrased anything",   // summarize / rephrase
    ]
    for dictation in dictations {
      XCTAssertEqual(
        AutoModeClassifier.resolve(transcript: dictation, hasSelection: true, hasIntegrations: true),
        .dictate,
        "expected Dictate for \"\(dictation)\""
      )
    }
  }

  /// Punctuation must not hide a keyword from the word-boundary match.
  func testPunctuationDoesNotDefeatMatching() {
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "Remind me: buy milk.", hasSelection: false, hasIntegrations: true),
      .action
    )
  }

  /// "schedule" is a command as a verb and prose as a noun. A determiner in
  /// front of it is the tell.
  func testScheduleAsVerbRoutesButAsNounDoesNot() {
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "Schedule lunch with Mike tomorrow", hasSelection: false, hasIntegrations: true),
      .action
    )
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "The schedule slipped again this sprint", hasSelection: false, hasIntegrations: true),
      .dictate
    )
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "My schedule is packed", hasSelection: false, hasIntegrations: true),
      .dictate
    )
  }

  /// The qualified form still routes; the bare English word does not.
  func testThingsRequiresTheAppName() {
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "Add this to Things app", hasSelection: false, hasIntegrations: true),
      .action
    )
    XCTAssertEqual(
      AutoModeClassifier.resolve(transcript: "We covered a lot of things today", hasSelection: false, hasIntegrations: true),
      .dictate
    )
  }

  /// Phrasings that reached Dictate in real use and pasted the command into
  /// the user's document instead of transforming their selection.
  func testConversionPhrasingsRouteToEdit() {
    let commands = [
      "Convert this into bullets, please.",
      "Convert this into poetry",
      "Convert it to a table",
      "Make this bullets",
    ]
    for command in commands {
      XCTAssertEqual(
        AutoModeClassifier.resolve(transcript: command, hasSelection: true, hasIntegrations: true),
        .edit,
        "expected Edit for \"\(command)\""
      )
    }
  }

  // MARK: - classifyPartial

  func testClassifyPartialDetectsActionMidStream() {
    XCTAssertEqual(AutoModeClassifier.classifyPartial("remind me to"), .action)
    XCTAssertEqual(AutoModeClassifier.classifyPartial("shorten this by"), .edit)
    XCTAssertEqual(AutoModeClassifier.classifyPartial("the meeting went"), .dictate)
  }
}
