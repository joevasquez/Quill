import XCTest
@testable import HexCore

final class MCPClientTests: XCTestCase {
  func testSSEResponseParsingFindsMatchingID() {
    let sse = """
    event: message
    data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

    event: message
    data: {"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"create_issue"}]}}

    """
    let parsed = MCPClient.parseSSEResponse(data: Data(sse.utf8), requestID: 3)
    XCTAssertNotNil(parsed)
    let result = parsed?["result"] as? [String: Any]
    XCTAssertNotNil(result?["tools"])
    XCTAssertNil(MCPClient.parseSSEResponse(data: Data(sse.utf8), requestID: 99))
  }

  func testTextContentConcatenatesTextBlocks() {
    let result: [String: Any] = [
      "content": [
        ["type": "text", "text": "Created issue"],
        ["type": "image", "data": "…"],
        ["type": "text", "text": "QUI-42"],
      ]
    ]
    XCTAssertEqual(MCPClient.textContent(from: result), "Created issue\nQUI-42")
  }

  func testInvalidURLThrows() {
    XCTAssertThrowsError(try MCPClient(url: "not a url"))
    XCTAssertThrowsError(try MCPClient(url: "ftp://x"))
    XCTAssertNoThrow(try MCPClient(url: "https://mcp.example.com/mcp"))
  }

  func testCatalogPromptContext() async {
    let catalog = MCPToolCatalog()
    let server = MCPServerConfig(name: "linear", url: "https://mcp.linear.app/mcp")
    // No cached tools → no context
    let empty = await catalog.promptContext(servers: [server])
    XCTAssertNil(empty)
  }

  func testMCPIntentRoundTripsThroughJSON() throws {
    let intent = ActionIntent(
      actionType: .mcpCall,
      title: "Create Linear issue for the login bug",
      mcpServerName: "linear",
      mcpTool: "create_issue",
      mcpArguments: ["title": "Login bug", "priority": "2"]
    )
    let data = try JSONEncoder().encode(intent)
    let decoded = try JSONDecoder().decode(ActionIntent.self, from: data)
    XCTAssertEqual(decoded, intent)
    XCTAssertEqual(decoded.actionType, .mcpCall)
    XCTAssertEqual(decoded.mcpArguments?["priority"], "2")
  }
}

final class MCPToolArgumentSummaryTests: XCTestCase {
  func testRequiredArgsFirstWithTypes() {
    let schema = """
    {"type":"object","properties":{"limit":{"type":"integer"},"query":{"type":"string"}},"required":["query"]}
    """
    let tool = MCPTool(name: "search", inputSchemaJSON: schema)
    XCTAssertEqual(tool.argumentSummary, "query (string, required), limit (integer)")
  }

  func testEnumValuesIncluded() {
    let schema = """
    {"type":"object","properties":{"status":{"type":"string","enum":["open","closed"]}}}
    """
    let tool = MCPTool(name: "filter", inputSchemaJSON: schema)
    XCTAssertEqual(tool.argumentSummary, "status (string) one of: open|closed")
  }

  func testNoPropertiesReturnsNil() {
    XCTAssertNil(MCPTool(name: "ping", inputSchemaJSON: #"{"type":"object"}"#).argumentSummary)
    XCTAssertNil(MCPTool(name: "ping").argumentSummary)
  }
}
