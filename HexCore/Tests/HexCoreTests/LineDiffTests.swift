import XCTest
@testable import HexCore

final class LineDiffTests: XCTestCase {
  private func render(_ rows: [LineDiff.Row]) -> [String] {
    rows.map { row in
      switch row.kind {
      case .unchanged: "  \(row.text)"
      case .removed: "- \(row.text)"
      case .added: "+ \(row.text)"
      }
    }
  }

  func testIdenticalTextHasNoChanges() {
    let rows = LineDiff.rows(from: "a\nb\nc", to: "a\nb\nc")
    XCTAssertEqual(rows.map(\.kind), [.unchanged, .unchanged, .unchanged])
  }

  func testDroppedLineIsMarkedRemoved() {
    let rows = LineDiff.rows(from: "a\nb\nc", to: "a\nc")
    XCTAssertEqual(render(rows), ["  a", "- b", "  c"])
  }

  func testAddedLineIsMarkedAdded() {
    let rows = LineDiff.rows(from: "a\nc", to: "a\nb\nc")
    XCTAssertEqual(render(rows), ["  a", "+ b", "  c"])
  }

  func testReplacedLineShowsRemovalThenAddition() {
    let rows = LineDiff.rows(from: "a\nold\nc", to: "a\nnew\nc")
    XCTAssertEqual(render(rows), ["  a", "- old", "+ new", "  c"])
  }

  /// The prototype's set-membership diff got this wrong: with duplicate
  /// lines, `set.has(line)` is true for every copy, so dropping one of
  /// three identical bullets showed zero changes.
  func testDuplicateLinesDiffByPositionNotMembership() {
    let rows = LineDiff.rows(from: "• x\n• x\n• x", to: "• x\n• x")
    XCTAssertEqual(rows.filter { $0.kind == .removed }.count, 1)
    XCTAssertEqual(rows.filter { $0.kind == .unchanged }.count, 2)
    XCTAssertEqual(rows.filter { $0.kind == .added }.count, 0)
  }

  /// Same trap: a line that merely moved shouldn't be reported as both
  /// removed and re-added at every occurrence.
  func testUnchangedLinesSurviveAReorder() {
    let rows = LineDiff.rows(from: "a\nb", to: "b\na")
    // One of the two must move; the other stays put.
    XCTAssertEqual(rows.filter { $0.kind == .unchanged }.count, 1)
    XCTAssertEqual(rows.filter { $0.kind == .removed }.count, 1)
    XCTAssertEqual(rows.filter { $0.kind == .added }.count, 1)
  }

  func testEmptyBeforeIsAllAdditions() {
    let rows = LineDiff.rows(from: "", to: "a\nb")
    // "" is a single empty line, which survives as the first row.
    XCTAssertEqual(rows.filter { $0.kind == .added }.count, 2)
  }

  func testEmptyAfterIsAllRemovals() {
    let rows = LineDiff.rows(from: "a\nb", to: "")
    XCTAssertEqual(rows.filter { $0.kind == .removed }.count, 2)
  }

  func testRowIDsAreUnique() {
    let rows = LineDiff.rows(from: "a\nb\nc\nd", to: "a\nx\nd\ny")
    XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
  }

  func testShortenedBulletListKeepsTheKeptBullets() {
    let before = "**Notes**\n• one\n• two\n• three"
    let after = "**Notes**\n• one\n• two"
    XCTAssertEqual(render(LineDiff.rows(from: before, to: after)), [
      "  **Notes**", "  • one", "  • two", "- • three",
    ])
  }
}
