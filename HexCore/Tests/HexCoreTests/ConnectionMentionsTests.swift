import XCTest
@testable import HexCore

final class ConnectionMentionsTests: XCTestCase {
  private let gmail = QuillActDestination(
    kind: .integration(.gmail), name: "Gmail", systemImage: "envelope.fill", hue: 20
  )
  private let googleCalendar = QuillActDestination(
    kind: .integration(.googleCalendar), name: "Google Calendar", systemImage: "calendar", hue: 255
  )
  private let dex = QuillActDestination(
    kind: .mcp("Dex"), name: "Dex", systemImage: "person.2.fill", hue: 32
  )

  private var all: [QuillActDestination] { [gmail, googleCalendar, dex] }

  // MARK: - Active query

  func testActiveQueryAtStart() {
    let result = ConnectionMentions.activeQuery(in: "@gm")
    XCTAssertEqual(result?.query, "gm")
  }

  func testActiveQueryAfterWhitespace() {
    XCTAssertEqual(ConnectionMentions.activeQuery(in: "log this in @de")?.query, "de")
  }

  func testEmptyQueryOpensTheMenu() {
    XCTAssertEqual(ConnectionMentions.activeQuery(in: "remind me @")?.query, "")
  }

  func testNoQueryInsideAWord() {
    // An email address must not open the menu.
    XCTAssertNil(ConnectionMentions.activeQuery(in: "mail joe@dex.com"))
  }

  func testNoQueryWhenNoTrigger() {
    XCTAssertNil(ConnectionMentions.activeQuery(in: "remind me to call Kelly"))
  }

  func testQueryEndsAtNewline() {
    XCTAssertNil(ConnectionMentions.activeQuery(in: "@Gmail\ndraft a note"))
  }

  // MARK: - Matching

  func testPrefixMatchBeatsInterior() {
    let matches = ConnectionMentions.matches(query: "g", among: all)
    XCTAssertEqual(matches.first?.name, "Gmail")
  }

  func testMatchesLaterWord() {
    let matches = ConnectionMentions.matches(query: "calendar", among: all)
    XCTAssertEqual(matches.map(\.name), ["Google Calendar"])
  }

  func testEmptyQueryListsEverything() {
    XCTAssertEqual(ConnectionMentions.matches(query: "", among: all).count, 3)
  }

  // MARK: - Completion

  func testCompleteReplacesTokenAndAddsSpace() {
    let text = "log this in @de"
    let range = ConnectionMentions.activeQuery(in: text)!.range
    XCTAssertEqual(
      ConnectionMentions.complete(text, with: dex, replacing: range),
      "log this in @Dex "
    )
  }

  // MARK: - Extraction

  func testExtractsSinglePinAndStripsToken() {
    let result = ConnectionMentions.extract(from: "@Dex log that I met Kelly", destinations: all)
    XCTAssertEqual(result.text, "log that I met Kelly")
    XCTAssertEqual(result.pinned, [dex])
  }

  func testExtractsMultiWordDestination() {
    let result = ConnectionMentions.extract(
      from: "book lunch Friday @Google Calendar", destinations: all
    )
    XCTAssertEqual(result.text, "book lunch Friday")
    XCTAssertEqual(result.pinned, [googleCalendar])
  }

  func testLongestNameWinsOverPrefix() {
    // "@Google Calendar" must not clip to a hypothetical "@Google".
    let google = QuillActDestination(
      kind: .mcp("Google"), name: "Google", systemImage: "g.circle", hue: 100
    )
    let result = ConnectionMentions.extract(
      from: "@Google Calendar block 3pm", destinations: [google, googleCalendar]
    )
    XCTAssertEqual(result.pinned, [googleCalendar])
    XCTAssertEqual(result.text, "block 3pm")
  }

  func testMultiplePinsPreserveOrderAndDedupe() {
    let result = ConnectionMentions.extract(
      from: "@Gmail draft a reply and log it in @Dex, then @Gmail again", destinations: all
    )
    XCTAssertEqual(result.pinned, [gmail, dex])
  }

  func testUnknownTagStaysLiteral() {
    let result = ConnectionMentions.extract(from: "ping @nobody about it", destinations: all)
    XCTAssertEqual(result.text, "ping @nobody about it")
    XCTAssertTrue(result.pinned.isEmpty)
  }

  func testEmailAddressIsNotAPin() {
    let result = ConnectionMentions.extract(from: "email joe@dex.com the deck", destinations: all)
    XCTAssertTrue(result.pinned.isEmpty)
    XCTAssertEqual(result.text, "email joe@dex.com the deck")
  }

  func testNoTriggerIsAPassthrough() {
    let result = ConnectionMentions.extract(from: "remind me Friday", destinations: all)
    XCTAssertEqual(result.text, "remind me Friday")
    XCTAssertTrue(result.pinned.isEmpty)
  }

  // MARK: - Targeting

  func testUnrestrictedTargetingHasNoPromptContext() {
    XCTAssertNil(ActTargeting.unrestricted.promptContext)
    XCTAssertTrue(ActTargeting.unrestricted.isUnrestricted)
  }

  func testPinnedTargetingOverridesRoutable() {
    let targeting = ActTargeting(routable: all, pinned: [dex])
    XCTAssertEqual(targeting.focus, [dex])
    XCTAssertTrue(targeting.promptContext?.contains("pinned") == true)
  }

  func testSinglePinForcesNativeIntegration() {
    XCTAssertEqual(ActTargeting(pinned: [gmail]).forcedIntegration, .gmail)
  }

  func testMCPPinDoesNotForceAnIntegration() {
    XCTAssertNil(ActTargeting(pinned: [dex]).forcedIntegration)
  }

  func testMultiplePinsStayAdvisory() {
    XCTAssertNil(ActTargeting(pinned: [gmail, googleCalendar]).forcedIntegration)
  }

  func testAllowedServersWithheldOutsideFocus() {
    let servers = [
      MCPServerConfig(name: "Dex", url: "https://dex.example/mcp"),
      MCPServerConfig(name: "Linear", url: "https://linear.example/mcp"),
    ]
    let targeting = ActTargeting(routable: all, pinned: [dex])
    XCTAssertEqual(targeting.allowedServers(from: servers).map(\.name), ["Dex"])
  }

  func testUnrestrictedTargetingAllowsEveryServer() {
    let servers = [MCPServerConfig(name: "Dex", url: "https://dex.example/mcp")]
    XCTAssertEqual(ActTargeting.unrestricted.allowedServers(from: servers).count, 1)
  }

  func testMutedDestinationsNarrowWithoutPinning() {
    let targeting = ActTargeting(all: all, muted: [googleCalendar.id, dex.id])
    XCTAssertEqual(targeting.focus, [gmail])
    XCTAssertTrue(targeting.promptContext?.contains("turned the others off") == true)
  }

  /// Muting nothing must not produce an "allowed set" — see the init's note.
  func testNothingMutedIsUnrestricted() {
    let targeting = ActTargeting(all: all, muted: [])
    XCTAssertTrue(targeting.isUnrestricted)
    XCTAssertNil(targeting.promptContext)
  }

  func testPinSurvivesAnUnmutedRow() {
    let targeting = ActTargeting(all: all, muted: [], pinned: [dex])
    XCTAssertEqual(targeting.focus, [dex])
  }

  func testDestinationlessActionsAreExempted() {
    let targeting = ActTargeting(all: all, muted: [dex.id])
    XCTAssertTrue(targeting.promptContext?.contains("exempt") == true)
  }

  // MARK: - Menu open/close

  func testMenuOpensOnPartialQuery() {
    XCTAssertEqual(
      ConnectionMentions.menu(in: "log it in @de", destinations: all)?.matches, [dex]
    )
  }

  /// The regression that mattered: `complete` writes "@Dex " and a query may
  /// contain spaces, so "Dex " kept matching Dex and the menu never closed.
  func testMenuClosesAfterASelection() {
    let completed = ConnectionMentions.complete(
      "log it in @de", with: dex, replacing: ConnectionMentions.activeQuery(in: "log it in @de")!.range
    )
    XCTAssertEqual(completed, "log it in @Dex ")
    XCTAssertNil(ConnectionMentions.menu(in: completed, destinations: completed.isEmpty ? [] : all))
  }

  func testMenuClosesOnExactNameTypedByHand() {
    XCTAssertNil(ConnectionMentions.menu(in: "@Gmail", destinations: all))
  }

  func testMenuIsNilWithNothingConnected() {
    XCTAssertNil(ConnectionMentions.menu(in: "@de", destinations: []))
  }

  func testMenuIsNilWhenNothingMatches() {
    XCTAssertNil(ConnectionMentions.menu(in: "@zzz", destinations: all))
  }

  // MARK: - Caret-relative queries

  func testQueryFollowsTheCaretMidSentence() {
    let text = "tag @de here"
    let caret = text.index(text.startIndex, offsetBy: 7)  // just after "@de"
    XCTAssertEqual(ConnectionMentions.activeQuery(in: text, caret: caret)?.query, "de")
  }

  func testUTF16CaretMatchesStringIndexCaret() {
    let text = "tag @de here"
    XCTAssertEqual(ConnectionMentions.activeQuery(in: text, utf16Caret: 7)?.query, "de")
  }

  func testOutOfRangeCaretClampsInsteadOfTrapping() {
    XCTAssertNotNil(ConnectionMentions.activeQuery(in: "@de", utf16Caret: 999))
  }

  // MARK: - Inline token ranges

  func testTokenRangesFindsEveryCompletedMention() {
    let text = "@Gmail draft it and log it in @Dex"
    let tokens = ConnectionMentions.tokenRanges(in: text, destinations: all)
    XCTAssertEqual(tokens.map(\.destination), [gmail, dex])
    XCTAssertEqual(tokens.map { String(text[$0.range]) }, ["@Gmail", "@Dex"])
  }

  func testTokenRangesSpanMultiWordNames() {
    let text = "block 3pm @Google Calendar"
    let tokens = ConnectionMentions.tokenRanges(in: text, destinations: all)
    XCTAssertEqual(tokens.map { String(text[$0.range]) }, ["@Google Calendar"])
  }

  func testTokenRangesIgnoresEmailAddresses() {
    XCTAssertTrue(
      ConnectionMentions.tokenRanges(in: "email joe@dex.com", destinations: all).isEmpty
    )
  }
}
