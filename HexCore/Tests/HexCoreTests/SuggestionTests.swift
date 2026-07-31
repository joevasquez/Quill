import XCTest

@testable import HexCore

final class SuggestionTests: XCTestCase {
  // MARK: - Engine decode

  func testEngineDecodesSuggestionsWithActions() throws {
    let json = """
      {"suggestions": [
        {"source": "gmail", "headline": "3 emails look time-sensitive",
         "why": "They mention you by name.",
         "actions": [
           {"actionType": "createDraft", "targetIntegration": "gmail",
            "title": "Reply to Kelly", "recipient": "kelly@capitalone.com",
            "subject": "Re: Q3 pilot", "notes": "Hi Kelly, works for us."}
         ]},
        {"source": "dex", "headline": "Reconnect with 2 people",
         "why": "Quiet for 3+ months.",
         "actions": [
           {"actionType": "mcpCall", "targetIntegration": "appleReminders",
            "title": "Look up Mike in Dex", "mcpServerName": "Dex",
            "mcpTool": "search_contacts", "mcpArguments": {"query": "Mike"}},
           {"actionType": "createDraft", "targetIntegration": "gmail",
            "title": "Draft check-in", "dependsOn": 0,
            "resolveInstruction": "Set recipient to the email from the lookup."}
         ]}
      ]}
      """
    let suggestions = try XCTUnwrap(SuggestionEngine.decode(json, generatedAt: Date()))
    XCTAssertEqual(suggestions.count, 2)
    XCTAssertEqual(suggestions[0].source, .gmail)
    XCTAssertEqual(suggestions[0].intents.count, 1)
    XCTAssertEqual(suggestions[0].intents[0].actionType, .createDraft)
    XCTAssertEqual(suggestions[1].intents[1].dependsOn, 0)
  }

  func testEngineDecodeDropsUnknownSourceAndEmptyActions() throws {
    let json = """
      {"suggestions": [
        {"source": "linkedin", "headline": "Nope", "why": "",
         "actions": [{"actionType": "createTask", "targetIntegration": "todoist", "title": "x"}]},
        {"source": "gmail", "headline": "No actions", "why": "", "actions": []},
        {"source": "todoist", "headline": "5 tasks are overdue", "why": "Slipped.",
         "actions": [{"actionType": "createTask", "targetIntegration": "todoist", "title": "Reschedule"}]}
      ]}
      """
    let suggestions = try XCTUnwrap(SuggestionEngine.decode(json, generatedAt: Date()))
    XCTAssertEqual(suggestions.count, 1)
    XCTAssertEqual(suggestions[0].source, .todoist)
  }

  func testEngineDecodeSurvivesInventedEnumValues() throws {
    // One invented actionType / targetIntegration must not nil the whole
    // response — Codable arrays are all-or-nothing without the Lossy wrap.
    let json = """
      {"suggestions": [
        {"source": "dex", "headline": "Reconnect", "why": "",
         "actions": [{"actionType": "createContact", "targetIntegration": "dex", "title": "bad"}]},
        {"source": "calendar", "headline": "Block focus time", "why": "Busy day.",
         "actions": [
           {"actionType": "createEvent", "targetIntegration": "calendar", "title": "Focus"},
           {"actionType": "createNudge", "targetIntegration": "calendar", "title": "bad item"}
         ]}
      ]}
      """
    let suggestions = try XCTUnwrap(SuggestionEngine.decode(json, generatedAt: Date()))
    // Dex suggestion drops (its only action was undecodable); calendar
    // survives with the one good action.
    XCTAssertEqual(suggestions.count, 1)
    XCTAssertEqual(suggestions[0].source, .calendar)
    XCTAssertEqual(suggestions[0].intents.count, 1)
    XCTAssertEqual(suggestions[0].intents[0].actionType, .createEvent)
  }

  func testEngineDecodeDistinguishesGarbageFromEmpty() {
    // Garbage (e.g. a truncated response) → nil, so the caller throws
    // instead of stamping the TTL with a phantom empty feed.
    XCTAssertNil(SuggestionEngine.decode("not json", generatedAt: Date()))
    XCTAssertNil(SuggestionEngine.decode("{\"suggestions\": [{\"source\": \"gm", generatedAt: Date()))
    // Valid-but-empty is a legitimate "nothing worth suggesting".
    XCTAssertEqual(SuggestionEngine.decode("{}", generatedAt: Date()), [])
  }

  func testEngineSkipsWhenAllContextsEmpty() async throws {
    let result = try await SuggestionEngine.generate(
      contexts: [SuggestionSourceContext(source: .gmail, text: "  ")],
      capabilities: nil
    ) { _, _ in
      XCTFail("Completer should not run with no usable context")
      return ""
    }
    XCTAssertEqual(result, [])
  }

  // MARK: - Store

  private func makeStore() -> SuggestionStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("suggestions-test-\(UUID().uuidString).json")
    return SuggestionStore(fileURL: url)
  }

  private func makeSuggestion(source: SuggestionSource = .gmail, headline: String) -> Suggestion {
    Suggestion(
      source: source,
      headline: headline,
      why: "why",
      intents: [ActionIntent(actionType: .createDraft, targetIntegration: .gmail, title: "t")]
    )
  }

  func testStoreDismissedStaysDismissedAcrossRegeneration() async {
    let store = makeStore()
    let first = makeSuggestion(headline: "10 new emails")
    await store.replaceAll([first])
    await store.dismiss(first)
    var current = await store.current()
    XCTAssertTrue(current.isEmpty)

    // Regeneration mints a new UUID but the same content — must stay hidden.
    let regenerated = makeSuggestion(headline: "10 New Emails ")
    await store.replaceAll([regenerated, makeSuggestion(headline: "Other")])
    current = await store.current()
    XCTAssertEqual(current.map(\.headline), ["Other"])
  }

  func testStoreStaleness() async {
    let store = makeStore()
    var stale = await store.isStale(ttl: 60)
    XCTAssertTrue(stale, "Never-generated store is stale")

    await store.replaceAll([makeSuggestion(headline: "x")])
    stale = await store.isStale(ttl: 3600)
    XCTAssertFalse(stale)
    stale = await store.isStale(ttl: 3600, now: Date().addingTimeInterval(7200))
    XCTAssertTrue(stale)
  }

  func testStoreCapsSuggestions() async {
    let store = makeStore()
    let many = (0..<20).map { makeSuggestion(headline: "s\($0)") }
    await store.replaceAll(many)
    let current = await store.current()
    XCTAssertEqual(current.count, 6)
  }

  func testDedupeKeyNormalizes() {
    let a = makeSuggestion(headline: "  Hello World ")
    let b = makeSuggestion(headline: "hello world")
    XCTAssertEqual(a.dedupeKey, b.dedupeKey)
    let c = makeSuggestion(source: .dex, headline: "hello world")
    XCTAssertNotEqual(a.dedupeKey, c.dedupeKey)
  }
}
