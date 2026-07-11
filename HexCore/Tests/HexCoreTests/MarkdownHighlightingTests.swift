import XCTest
@testable import HexCore

final class MarkdownListContinuationTests: XCTestCase {
  private func result(_ text: String, caretAtEnd: Bool = true, caret: Int? = nil) -> MarkdownListContinuation.Result {
    MarkdownListContinuation.handleNewline(
      text: text,
      caretLocation: caret ?? (text as NSString).length
    )
  }

  func testBulletContinues() {
    XCTAssertEqual(result("- first item"), .continueList(insert: "\n- "))
  }

  func testBulletKeepsIndent() {
    XCTAssertEqual(result("  - nested"), .continueList(insert: "\n  - "))
  }

  func testNumberedListIncrements() {
    XCTAssertEqual(result("3. third"), .continueList(insert: "\n4. "))
  }

  func testQuoteContinues() {
    XCTAssertEqual(result("> quoted"), .continueList(insert: "\n> "))
  }

  func testEmptyBulletExitsList() {
    let text = "- item\n- "
    guard case .exitList(let range) = result(text) else {
      return XCTFail("expected exitList")
    }
    // The clear range covers the trailing "- " marker line head.
    XCTAssertEqual((text as NSString).substring(with: range), "- ")
  }

  func testEmptyNumberedItemExitsList() {
    // Caret right after "2." — treated as an empty item.
    guard case .exitList = result("1. one\n2.") else {
      return XCTFail("expected exitList")
    }
  }

  func testPlainProseDoesNothing() {
    XCTAssertEqual(result("just a sentence"), .none)
  }

  func testCheckboxContinuesUnchecked() {
    XCTAssertEqual(result("- [ ] buy milk"), .continueList(insert: "\n- [ ] "))
    XCTAssertEqual(result("- [x] done thing"), .continueList(insert: "\n- [ ] "))
  }

  func testCaretBeyondTextDoesNothing() {
    XCTAssertEqual(
      MarkdownListContinuation.handleNewline(text: "- x", caretLocation: 99),
      .none
    )
  }
}

final class MarkdownCheckboxTests: XCTestCase {
  func testToggleUnchecked() {
    XCTAssertEqual(
      MarkdownCheckbox.toggleLine(0, in: "- [ ] buy milk"),
      "- [x] buy milk"
    )
  }

  func testToggleCheckedBackToUnchecked() {
    XCTAssertEqual(
      MarkdownCheckbox.toggleLine(1, in: "prose\n- [X] done\nmore"),
      "prose\n- [ ] done\nmore"
    )
  }

  func testToggleKeepsIndent() {
    XCTAssertEqual(
      MarkdownCheckbox.toggleLine(0, in: "  - [ ] nested"),
      "  - [x] nested"
    )
  }

  func testNonCheckboxLineReturnsNil() {
    XCTAssertNil(MarkdownCheckbox.toggleLine(0, in: "- plain bullet"))
    XCTAssertNil(MarkdownCheckbox.toggleLine(5, in: "short"))
  }
}

final class MarkdownHighlighterTests: XCTestCase {
  @MainActor
  func testHighlightPreservesStringContent() {
    let source = "# Title\n**bold** and _italic_ and `code`\n- bullet\n1. numbered\n> quote\n![photo](0A1B2C3D-0000-0000-0000-000000000000)"
    let storage = NSMutableAttributedString(string: source)
    MarkdownHighlighter.highlight(storage)
    XCTAssertEqual(storage.string, source)
  }

  @MainActor
  func testBoldContentGetsBoldFont() {
    let storage = NSMutableAttributedString(string: "**hi** there")
    MarkdownHighlighter.highlight(storage)
    // Content range is inside the markers: "hi" at location 2.
    let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? MDFont
    XCTAssertNotNil(font)
    #if canImport(AppKit)
    XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    #else
    XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.traitBold))
    #endif
  }

  @MainActor
  func testEmptyStringIsNoOp() {
    let storage = NSMutableAttributedString(string: "")
    MarkdownHighlighter.highlight(storage)
    XCTAssertEqual(storage.string, "")
  }
}
