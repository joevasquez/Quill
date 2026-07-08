import XCTest
@testable import HexCore

/// Chained Action steps: the model carries a `dependsOn` index + a
/// `resolveInstruction`, and both survive a JSON round-trip (the planner emits
/// them, the offline queue persists them).
final class DependentStepTests: XCTestCase {
  func testDependentFieldsRoundTripThroughJSON() throws {
    let intent = ActionIntent(
      actionType: .createDraft,
      targetIntegration: .gmail,
      title: "Happy Birthday",
      notes: "Wishing you a very happy birthday!",
      dependsOn: 0,
      resolveInstruction: "Set recipient to the email address from the lookup result"
    )
    let data = try JSONEncoder().encode(intent)
    let decoded = try JSONDecoder().decode(ActionIntent.self, from: data)
    XCTAssertEqual(decoded, intent)
    XCTAssertEqual(decoded.dependsOn, 0)
    XCTAssertEqual(decoded.resolveInstruction, "Set recipient to the email address from the lookup result")
  }

  /// Legacy intents (persisted before chaining existed) decode with nil
  /// dependency fields — they must remain independent steps.
  func testLegacyIntentDecodesAsIndependent() throws {
    let legacy = #"{"actionType":"createReminder","targetIntegration":"appleReminders","title":"Buy milk"}"#
    let decoded = try JSONDecoder().decode(ActionIntent.self, from: Data(legacy.utf8))
    XCTAssertNil(decoded.dependsOn)
    XCTAssertNil(decoded.resolveInstruction)
  }

  /// A planner response with a producer + a dependent consumer decodes into
  /// an ordered actions array with the dependency wired by index.
  func testMultiActionResponseWithDependentStep() throws {
    let json = """
    {"actions":[
      {"actionType":"mcpCall","targetIntegration":"appleReminders","title":"Look up Joe in Dex","mcpServerName":"Dex","mcpTool":"search_contacts","mcpArguments":{"query":"Joe Vasquez"}},
      {"actionType":"createDraft","targetIntegration":"gmail","title":"Happy Birthday","notes":"Happy birthday!","dependsOn":0,"resolveInstruction":"Set recipient to Joe's email from the lookup"}
    ]}
    """
    let response = try JSONDecoder().decode(MultiActionResponse.self, from: Data(json.utf8))
    XCTAssertEqual(response.actions.count, 2)
    XCTAssertNil(response.actions[0].dependsOn)
    XCTAssertEqual(response.actions[1].dependsOn, 0)
    XCTAssertEqual(response.actions[1].targetIntegration, .gmail)
  }

  func testResolvePromptUserMessageIncludesAllSections() {
    let msg = StepResolvePrompt.userMessage(
      actionJSON: #"{"recipient":null}"#,
      priorResult: "Joe Vasquez <joe@example.com>",
      instruction: "Set recipient to the email address",
      request: "find Joe in Dex then draft him a birthday email"
    )
    XCTAssertTrue(msg.contains("REQUEST:"))
    XCTAssertTrue(msg.contains("find Joe in Dex then draft him a birthday email"))
    XCTAssertTrue(msg.contains("PRIOR RESULT:"))
    XCTAssertTrue(msg.contains("Joe Vasquez <joe@example.com>"))
    XCTAssertTrue(msg.contains("INSTRUCTION:"))
    XCTAssertTrue(msg.contains("ACTION:"))
    XCTAssertTrue(msg.contains(#"{"recipient":null}"#))
  }

  /// The resolve system prompt must license personalization (rewriting the
  /// body with the looked-up name), not just filling the linking field — this
  /// is what makes the prior step's output dynamically inform the next.
  func testResolvePromptLicensesPersonalization() {
    let p = StepResolvePrompt.prompt.lowercased()
    XCTAssertTrue(p.contains("personalize"))
    XCTAssertTrue(p.contains("never invent"))
  }
}
