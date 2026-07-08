import XCTest
@testable import HexCore

final class MCPResultFormatterTests: XCTestCase {
  /// The real Dex `find_contact` payload the user reported.
  func testDexContactResultIsHumanReadable() {
    let raw = #"{"items":[{"id":"562de193-8ec1-4c9e-9d50-38d5e835ae65","last_name":"Vasquez","first_name":"Joe","job_title":"VP, GenAI Strategy & Transformation at D.E. Shaw Group | Ex-BCG","image_url":"https://storage.googleapis.com/danahq1.appspot.com/contacts/x/avatar.jpeg","legacy_location":"New York, New York, United States of America","starred":true}],"count":1}"#
    let out = MCPResultFormatter.format(raw)

    // Name heading composed from first + last.
    XCTAssertTrue(out.hasPrefix("Joe Vasquez"), "expected name heading, got:\n\(out)")
    // Aliased, humanized labels.
    XCTAssertTrue(out.contains("Title: VP, GenAI Strategy & Transformation"))
    XCTAssertTrue(out.contains("Location: New York, New York, United States of America"))
    XCTAssertTrue(out.contains("Starred: Yes"))
    // Noise dropped.
    XCTAssertFalse(out.contains("562de193"), "id should be dropped")
    XCTAssertFalse(out.contains("image_url"))
    XCTAssertFalse(out.contains("storage.googleapis"), "avatar URL should be dropped")
    XCTAssertFalse(out.contains("{"), "should not be raw JSON")
  }

  func testMultipleRecordsSeparatedAndCapped() {
    let people = (1...12).map { #"{"first_name":"P\#($0)","last_name":"Last"}"# }.joined(separator: ",")
    let raw = "{\"results\":[\(people)]}"
    let out = MCPResultFormatter.format(raw)
    XCTAssertTrue(out.contains("P1 Last"))
    XCTAssertTrue(out.contains("…and 2 more"), "12 records, cap 10 → 2 more")
    XCTAssertFalse(out.contains("P11 Last"))
  }

  func testPlainTextPassesThrough() {
    XCTAssertEqual(MCPResultFormatter.format("Task created successfully"), "Task created successfully")
  }

  func testFlatObjectRendersAsKeyValueLines() {
    let out = MCPResultFormatter.format(#"{"ok":true,"remaining":5}"#)
    // A nameless flat object becomes readable "Label: value" lines.
    XCTAssertTrue(out.contains("Remaining: 5"), "got: \(out)")
    XCTAssertTrue(out.contains("Ok: Yes"))
    XCTAssertFalse(out.contains("{"), "should not be raw JSON")
  }

  func testDeeplyNestedNonRecordJSONFallsBackToPrettyPrint() {
    // Top-level array of non-objects → not record-shaped → pretty-printed.
    let out = MCPResultFormatter.format(#"[1,2,3]"#)
    XCTAssertTrue(out.contains("\n"), "expected pretty-printed multiline, got: \(out)")
    XCTAssertTrue(out.contains("1"))
  }

  func testEmptyStaysEmpty() {
    XCTAssertEqual(MCPResultFormatter.format("   "), "")
  }

  func testSingleObjectRecord() {
    let out = MCPResultFormatter.format(#"{"name":"Acme Corp","company":"Acme","website":"https://acme.com"}"#)
    XCTAssertTrue(out.hasPrefix("Acme Corp"))
    XCTAssertTrue(out.contains("Company: Acme"))
  }
}
