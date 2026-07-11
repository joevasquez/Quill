import XCTest
@testable import HexCore

final class AgentParsingTests: XCTestCase {
  // MARK: - Fence stripping

  func testStripFencesRemovesJSONFence() {
    XCTAssertEqual(
      LLMTransport.stripFences("```json\n{\"a\": 1}\n```"),
      "{\"a\": 1}"
    )
  }

  func testStripFencesPassesPlainJSONThrough() {
    XCTAssertEqual(LLMTransport.stripFences("  {\"a\": 1} \n"), "{\"a\": 1}")
  }

  // MARK: - Multi-or-single decode

  func testDecodeMultiActionResponse() throws {
    let json = """
    {"actions": [
      {"actionType": "createTask", "targetIntegration": "todoist", "title": "One"},
      {"actionType": "createReminder", "targetIntegration": "appleReminders", "title": "Two"}
    ]}
    """
    let response = try AgentParsing.decodeMultiOrSingle(json)
    XCTAssertEqual(response.actions.count, 2)
    XCTAssertEqual(response.actions[0].title, "One")
  }

  func testDecodeBareSingleIntentWrapsInArray() throws {
    let json = """
    {"actionType": "createReminder", "targetIntegration": "appleReminders", "title": "Solo"}
    """
    let response = try AgentParsing.decodeMultiOrSingle(json)
    XCTAssertEqual(response.actions.count, 1)
    XCTAssertEqual(response.actions[0].title, "Solo")
  }

  func testDecodeGarbageThrows() {
    XCTAssertThrowsError(try AgentParsing.decodeMultiOrSingle("not json"))
  }

  // MARK: - parseMulti prompt assembly

  func testParseMultiAppendsContextsAndWrapsTranscript() async throws {
    let captured = CapturedCall()
    let reply = """
    {"actions": [{"actionType": "createTask", "targetIntegration": "todoist", "title": "T"}]}
    """
    _ = try await AgentParsing.parseMulti(
      transcript: "add task",
      selection: "picked text",
      memoryContext: "MEMORY BLOCK",
      mcpContext: "MCP BLOCK",
      complete: { user, system in
        await captured.record(user: user, system: system)
        return reply
      }
    )
    let (user, system) = await captured.value()
    XCTAssertTrue(system.hasPrefix(ActionSystemPrompt.prompt))
    XCTAssertTrue(system.contains("MEMORY BLOCK"))
    XCTAssertTrue(system.contains("MCP BLOCK"))
    XCTAssertTrue(user.contains("add task"))
    XCTAssertTrue(user.contains("picked text"))
  }

  func testParseMultiOmitsEmptyContexts() async throws {
    let captured = CapturedCall()
    let reply = """
    {"actions": [{"actionType": "createTask", "targetIntegration": "todoist", "title": "T"}]}
    """
    _ = try await AgentParsing.parseMulti(
      transcript: "add task",
      selection: nil,
      memoryContext: nil,
      mcpContext: "",
      complete: { user, system in
        await captured.record(user: user, system: system)
        return reply
      }
    )
    let (_, system) = await captured.value()
    XCTAssertEqual(system, ActionSystemPrompt.prompt)
  }

  func testParseMultiStripsFencedReply() async throws {
    let response = try await AgentParsing.parseMulti(
      transcript: "x",
      selection: nil,
      memoryContext: nil,
      mcpContext: nil,
      complete: { _, _ in
        "```json\n{\"actions\": [{\"actionType\": \"createReminder\", \"targetIntegration\": \"appleReminders\", \"title\": \"F\"}]}\n```"
      }
    )
    XCTAssertEqual(response.actions.first?.title, "F")
  }

  // MARK: - resolveStep

  func testResolveStepWithoutInstructionSkipsLLM() async throws {
    let intent = ActionIntent(actionType: .createDraft, targetIntegration: .gmail, title: "Email")
    let resolved = try await AgentParsing.resolveStep(
      intent: intent,
      priorResult: "whatever",
      request: "req",
      complete: { _, _ in XCTFail("should not call LLM"); return "" }
    )
    XCTAssertEqual(resolved, intent)
  }

  func testResolveStepDecodesResolvedIntent() async throws {
    var intent = ActionIntent(actionType: .createDraft, targetIntegration: .gmail, title: "Email Joe")
    intent.resolveInstruction = "fill recipient from prior result"
    let resolvedJSON = """
    {"actionType": "createDraft", "targetIntegration": "gmail", "title": "Email Joe", "notes": "Happy birthday, Joe!"}
    """
    let resolved = try await AgentParsing.resolveStep(
      intent: intent,
      priorResult: "email: joe@example.com",
      request: "wish Joe happy birthday",
      complete: { _, _ in resolvedJSON }
    )
    XCTAssertEqual(resolved.notes, "Happy birthday, Joe!")
  }

  func testResolveStepFallsBackOnBadJSON() async throws {
    var intent = ActionIntent(actionType: .createDraft, targetIntegration: .gmail, title: "Email Joe")
    intent.resolveInstruction = "fill recipient"
    let resolved = try await AgentParsing.resolveStep(
      intent: intent,
      priorResult: "prior",
      request: "req",
      complete: { _, _ in "I could not do that" }
    )
    XCTAssertEqual(resolved, intent)
  }

  // MARK: - extractAnswer

  func testExtractAnswerReadsAnswerField() async throws {
    let answer = try await AgentParsing.extractAnswer(
      request: "what's Joe's email?",
      result: "{\"email\": \"joe@example.com\"}",
      complete: { _, _ in "{\"answer\": \" joe@example.com \"}" }
    )
    XCTAssertEqual(answer, "joe@example.com")
  }

  func testExtractAnswerReturnsEmptyOnUndecodableReply() async throws {
    let answer = try await AgentParsing.extractAnswer(
      request: "q",
      result: "r",
      complete: { _, _ in "no json here" }
    )
    XCTAssertEqual(answer, "")
  }

  // MARK: - extractMemory

  func testExtractMemoryDecodesEntities() async throws {
    let reply = """
    {"entities": [{"kind": "person", "name": "Mike", "details": {"role": "coworker"}}]}
    """
    let entities = try await AgentParsing.extractMemory(
      transcript: "email Mike about the launch",
      complete: { _, _ in reply }
    )
    XCTAssertEqual(entities.count, 1)
    XCTAssertEqual(entities.first?.name, "Mike")
  }

  func testExtractMemoryThrowsOnGarbage() async {
    do {
      _ = try await AgentParsing.extractMemory(
        transcript: "x",
        complete: { _, _ in "garbage" }
      )
      XCTFail("expected throw")
    } catch {}
  }

  // MARK: - Queueability of transport errors

  func testTransportServerErrorIsQueueable() {
    XCTAssertTrue(QueueableErrorClassifier.isQueueable(LLMTransportError.apiError(503, "")))
    XCTAssertTrue(QueueableErrorClassifier.isQueueable(LLMTransportError.apiError(429, "")))
  }

  func testTransportClientErrorIsNotQueueable() {
    XCTAssertFalse(QueueableErrorClassifier.isQueueable(LLMTransportError.apiError(401, "")))
    XCTAssertFalse(QueueableErrorClassifier.isQueueable(LLMTransportError.invalidResponse))
  }
}

/// Actor-backed capture so the @Sendable completer can record its inputs.
private actor CapturedCall {
  private var user = ""
  private var system = ""

  func record(user: String, system: String) {
    self.user = user
    self.system = system
  }

  func value() -> (String, String) { (user, system) }
}
