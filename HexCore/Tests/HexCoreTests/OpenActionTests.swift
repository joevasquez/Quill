import XCTest
@testable import HexCore

/// The `.open` action type (open a website / launch an app) round-trips
/// through JSON and the planner prompt teaches it.
final class OpenActionTests: XCTestCase {
  func testOpenIntentRoundTrips() throws {
    let intent = ActionIntent(
      actionType: .open,
      title: "Open LinkedIn in Chrome",
      urlString: "https://www.linkedin.com",
      appName: "Google Chrome"
    )
    let data = try JSONEncoder().encode(intent)
    let decoded = try JSONDecoder().decode(ActionIntent.self, from: data)
    XCTAssertEqual(decoded, intent)
    XCTAssertEqual(decoded.actionType, .open)
    XCTAssertEqual(decoded.urlString, "https://www.linkedin.com")
    XCTAssertEqual(decoded.appName, "Google Chrome")
  }

  func testAppLaunchIntentHasNoURL() throws {
    let intent = ActionIntent(actionType: .open, title: "Launch Spotify", appName: "Spotify")
    let decoded = try JSONDecoder().decode(ActionIntent.self, from: try JSONEncoder().encode(intent))
    XCTAssertEqual(decoded.appName, "Spotify")
    XCTAssertNil(decoded.urlString)
  }

  /// Legacy intents (before `.open` existed) still decode — additive fields.
  func testLegacyIntentDecodesWithoutOpenFields() throws {
    let legacy = #"{"actionType":"createReminder","targetIntegration":"appleReminders","title":"Buy milk"}"#
    let decoded = try JSONDecoder().decode(ActionIntent.self, from: Data(legacy.utf8))
    XCTAssertNil(decoded.urlString)
    XCTAssertNil(decoded.appName)
  }

  func testPlannerPromptTeachesOpen() {
    let p = ActionSystemPrompt.prompt
    XCTAssertTrue(p.contains("\"open\""))
    XCTAssertTrue(p.contains("urlString"))
    XCTAssertTrue(p.contains("appName"))
    XCTAssertTrue(p.contains("https://www.linkedin.com"))
  }

  func testOpenActionParsesFromPlannerJSON() throws {
    let json = #"{"actions":[{"actionType":"open","targetIntegration":"appleReminders","title":"Open LinkedIn in Chrome","urlString":"https://www.linkedin.com","appName":"Google Chrome"}]}"#
    let response = try JSONDecoder().decode(MultiActionResponse.self, from: Data(json.utf8))
    XCTAssertEqual(response.actions.count, 1)
    XCTAssertEqual(response.actions[0].actionType, .open)
    XCTAssertEqual(response.actions[0].appName, "Google Chrome")
  }
}
