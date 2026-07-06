import XCTest
@testable import HexCore

final class MemoryStoreTests: XCTestCase {
  private var tempURL: URL!
  private var store: MemoryStore!

  override func setUp() {
    super.setUp()
    tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("memory-test-\(UUID().uuidString).json")
    store = MemoryStore(fileURL: tempURL)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempURL)
    super.tearDown()
  }

  func testUpsertCreatesNewEntity() async {
    await store.upsert([MemoryCandidate(kind: .person, name: "Mike Chen", aliases: ["Mike"], details: ["email": "mike@acme.com"])])
    let all = await store.loadAll()
    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(all[0].name, "Mike Chen")
    XCTAssertEqual(all[0].aliases, ["Mike"])
    XCTAssertEqual(all[0].details["email"], "mike@acme.com")
    XCTAssertEqual(all[0].occurrences, 1)
  }

  func testUpsertMergesByAlias() async {
    await store.upsert([MemoryCandidate(kind: .person, name: "Mike Chen", aliases: ["Mike"])])
    // Later transcript refers to him as just "mike" and adds a detail.
    await store.upsert([MemoryCandidate(kind: .person, name: "Mike", details: ["project": "Kearney"])])
    let all = await store.loadAll()
    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(all[0].occurrences, 2)
    XCTAssertEqual(all[0].details["project"], "Kearney")
  }

  func testSameNameDifferentKindStaysSeparate() async {
    await store.upsert([MemoryCandidate(kind: .person, name: "Kearney")])
    await store.upsert([MemoryCandidate(kind: .project, name: "Kearney")])
    let all = await store.loadAll()
    XCTAssertEqual(all.count, 2)
  }

  func testRemoveAndClear() async {
    await store.upsert([
      MemoryCandidate(kind: .person, name: "Mike"),
      MemoryCandidate(kind: .project, name: "Kearney"),
    ])
    var all = await store.loadAll()
    XCTAssertEqual(all.count, 2)
    await store.remove(id: all[0].id)
    all = await store.loadAll()
    XCTAssertEqual(all.count, 1)
    await store.clear()
    all = await store.loadAll()
    XCTAssertTrue(all.isEmpty)
  }

  func testContextBuilderRendersRankedEntities() {
    let now = Date()
    let recent = MemoryEntity(kind: .person, name: "Mike Chen", aliases: ["Mike"], details: ["email": "mike@acme.com"], occurrences: 5, lastSeenAt: now)
    let stale = MemoryEntity(kind: .project, name: "Old Thing", occurrences: 1, lastSeenAt: now.addingTimeInterval(-90 * 86_400))
    let context = MemoryContextBuilder.context(from: [stale, recent], limit: 1, now: now)
    XCTAssertNotNil(context)
    XCTAssertTrue(context!.contains("Mike Chen"))
    XCTAssertTrue(context!.contains("mike@acme.com"))
    XCTAssertFalse(context!.contains("Old Thing"))
    XCTAssertNil(MemoryContextBuilder.context(from: []))
  }

  func testExtractionResponseDecoding() throws {
    let json = """
    {"entities": [{"kind": "person", "name": "Mike", "aliases": null, "details": {"email": "m@a.com"}}]}
    """
    let response = try JSONDecoder().decode(MemoryExtractionResponse.self, from: Data(json.utf8))
    XCTAssertEqual(response.entities.count, 1)
    XCTAssertEqual(response.entities[0].details?["email"], "m@a.com")
  }

  func testRoutineDraftDecoding() throws {
    let json = """
    {"name": "Release checklist", "triggerPhrase": "ship it", "actions": [{"actionType": "createTask", "targetIntegration": "todoist", "title": "Run checklist", "dueDate": "today", "notes": null, "listName": null, "priority": 4, "duration": null, "attendees": null, "recipient": null, "subject": null}]}
    """
    let draft = try JSONDecoder().decode(RoutineDraft.self, from: Data(json.utf8))
    XCTAssertEqual(draft.triggerPhrase, "ship it")
    XCTAssertEqual(draft.actions.count, 1)
    XCTAssertEqual(draft.actions[0].targetIntegration, .todoist)
  }
}

final class TranscriptWrapperSelectionTests: XCTestCase {
  func testWrapWithSelectionAppendsBlock() {
    let message = TranscriptWrapper.wrapWithSelection("add this to my list", selection: "Q3 numbers")
    XCTAssertTrue(message.contains("<transcript>\nadd this to my list\n</transcript>"))
    XCTAssertTrue(message.contains("<selection>\nQ3 numbers\n</selection>"))
  }

  func testNilOrEmptySelectionDegradesToPlainWrap() {
    XCTAssertEqual(
      TranscriptWrapper.wrapWithSelection("buy milk", selection: nil),
      TranscriptWrapper.wrap("buy milk")
    )
    XCTAssertEqual(
      TranscriptWrapper.wrapWithSelection("buy milk", selection: ""),
      TranscriptWrapper.wrap("buy milk")
    )
  }
}
