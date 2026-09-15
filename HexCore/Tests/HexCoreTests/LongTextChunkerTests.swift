import Testing
@testable import HexCore

@Suite("Long text chunking")
struct LongTextChunkerTests {
  @Test("short text remains one chunk")
  func shortText() {
    #expect(LongTextChunker.chunks("A short note.", maxCharacters: 100) == ["A short note."])
  }

  @Test("long text is split without losing words")
  func preservesContent() {
    let words = (0..<600).map { "word\($0)" }
    let input = words.joined(separator: " ")
    let chunks = LongTextChunker.chunks(input, maxCharacters: 500)

    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 500 })
    #expect(chunks.joined(separator: " ").split(separator: " ").map(String.init) == words)
  }

  @Test("paragraph boundaries are preferred")
  func prefersParagraphs() {
    let first = String(repeating: "a", count: 60)
    let second = String(repeating: "b", count: 60)
    let chunks = LongTextChunker.chunks("\(first)\n\n\(second)", maxCharacters: 80)

    #expect(chunks == [first, second])
  }
}

@Suite("Recording capture audit")
struct RecordingCaptureAuditTests {
  @Test("small callback timing differences are accepted")
  func acceptsTolerance() {
    #expect(RecordingCaptureAudit.evaluate(elapsed: 600, captured: 574) == .complete)
  }

  @Test("a materially short audio file requires recovery")
  func catchesTruncation() {
    #expect(RecordingCaptureAudit.evaluate(elapsed: 1_800, captured: 180) == .truncated)
  }
}
