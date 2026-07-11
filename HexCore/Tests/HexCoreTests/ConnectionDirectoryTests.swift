import XCTest
@testable import HexCore

final class ConnectionDirectoryTests: XCTestCase {
  func testBrandMatchesExactName() {
    XCTAssertEqual(ConnectionDirectory.brand(forServerNamed: "notion")?.name, "notion")
    XCTAssertEqual(ConnectionDirectory.brand(forServerNamed: "Linear")?.name, "linear")
  }

  func testBrandMatchesSubstringEitherDirection() {
    XCTAssertEqual(ConnectionDirectory.brand(forServerNamed: "dex crm")?.name, "dex")
    XCTAssertEqual(ConnectionDirectory.brand(forServerNamed: "my notion workspace")?.name, "notion")
  }

  func testBrandMatchesByURLHost() {
    XCTAssertEqual(
      ConnectionDirectory.brand(forServerNamed: "work tools", url: "https://mcp.linear.app/mcp")?.name,
      "linear"
    )
  }

  func testUnknownServerHasNoBrand() {
    XCTAssertNil(ConnectionDirectory.brand(forServerNamed: "internal-tools", url: "https://mcp.example.com/mcp"))
  }

  func testTargetResolutionFromIntent() {
    let mcp = ActionIntent(actionType: .mcpCall, title: "Find Joe", mcpServerName: "dex")
    XCTAssertEqual(ConnectionTarget.forIntent(mcp), .mcpServer("dex"))

    let open = ActionIntent(actionType: .open, title: "Open site", urlString: "https://x.com")
    XCTAssertEqual(ConnectionTarget.forIntent(open), .open)

    let task = ActionIntent(actionType: .createTask, targetIntegration: .todoist, title: "T")
    XCTAssertEqual(ConnectionTarget.forIntent(task), .integration(.todoist))
  }

  func testKnownMCPTargetGetsBrandedPresentation() {
    let target = ConnectionTarget.mcpServer("dex")
    XCTAssertEqual(target.displayName, "Dex")
    XCTAssertEqual(target.systemImage, "person.text.rectangle")
    XCTAssertNotNil(target.tintHex)
  }

  func testUnknownMCPTargetFallsBackToNeutral() {
    let target = ConnectionTarget.mcpServer("internal-tools")
    XCTAssertEqual(target.displayName, "internal-tools")
    XCTAssertEqual(target.systemImage, "puzzlepiece.extension.fill")
    XCTAssertNil(target.tintHex)
  }

  func testIntegrationTargetUsesCatalogBranding() {
    let target = ConnectionTarget.integration(.todoist)
    XCTAssertEqual(target.systemImage, Integration.all.first { $0.identifier == .todoist }?.systemImage)
    XCTAssertNotNil(target.tintHex)
  }
}
