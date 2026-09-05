import Foundation
import XCTest
@testable import HexCore

final class ProProxyTransportTests: XCTestCase {
  func testStructuredProRequestOptsIntoJSONMode() throws {
    let request = try LLMTransport.makeProProxyRequest(
      userMessage: "Create a reminder",
      systemPrompt: "Return JSON only.",
      accessToken: "google-token",
      maxTokens: 4096,
      jsonResponse: true
    )

    XCTAssertEqual(request.url?.absoluteString, LLMTransport.proProxyURL)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer google-token")
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
    )
    XCTAssertEqual(body["maxTokens"] as? Int, 4096)
    XCTAssertEqual(body["jsonResponse"] as? Bool, true)
  }

  func testPlainTextProRequestDisablesJSONMode() throws {
    let request = try LLMTransport.makeProProxyRequest(
      userMessage: "hello comma world",
      systemPrompt: "Clean up this transcript.",
      accessToken: "google-token",
      maxTokens: 2048,
      jsonResponse: false
    )

    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
    )
    XCTAssertEqual(body["jsonResponse"] as? Bool, false)
  }

  func testProRequestUsesCallersTimeout() throws {
    let request = try LLMTransport.makeProProxyRequest(
      userMessage: "Search my notes",
      systemPrompt: "Answer the question.",
      accessToken: "google-token",
      maxTokens: 1500,
      jsonResponse: true,
      timeout: 90
    )

    XCTAssertEqual(request.timeoutInterval, 90)
  }
}
