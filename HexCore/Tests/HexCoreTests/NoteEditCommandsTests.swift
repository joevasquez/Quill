import Foundation
import Testing

@testable import HexCore

@Suite("NoteEditCommands")
struct NoteEditCommandsTests {
  @Test("Suggestions are the seven built-ins, stable order")
  func suggestions() {
    #expect(NoteEditCommands.suggestions.first == "Shorten by 20%")
    #expect(NoteEditCommands.suggestions.contains("Fix grammar"))
    #expect(NoteEditCommands.suggestions.count == 7)
  }

  @Test("Labels are past-tense summaries")
  func labels() {
    #expect(NoteEditCommands.label(for: "Shorten by 20%") == "Shortened")
    #expect(NoteEditCommands.label(for: "make it bullets") == "Reformatted as bullets")
    #expect(NoteEditCommands.label(for: "Summarize") == "Summarized")
    #expect(NoteEditCommands.label(for: "Turn into email") == "Turned into email")
    #expect(NoteEditCommands.label(for: "Extract action items") == "Extracted action items")
    #expect(NoteEditCommands.label(for: "More formal") == "Tone adjusted")
    #expect(NoteEditCommands.label(for: "Fix grammar") == "Grammar polished")
    #expect(NoteEditCommands.label(for: "translate to Spanish") == "Note revised")
  }

  @Test("Usage records and ranks most-used first, ties alphabetical")
  func usage() {
    var data = Data()
    data = NoteEditCommands.recordUsage("Summarize", in: data)
    data = NoteEditCommands.recordUsage("Summarize", in: data)
    data = NoteEditCommands.recordUsage("Fix grammar", in: data)
    // Summarize (2) beats Fix grammar (1).
    #expect(NoteEditCommands.mostUsed(data, limit: 3) == ["Summarize", "Fix grammar"])
  }

  @Test("Usage ties break alphabetically for a stable row order")
  func usageTies() {
    var data = Data()
    data = NoteEditCommands.recordUsage("More formal", in: data)
    data = NoteEditCommands.recordUsage("Fix grammar", in: data)
    // Both at 1 → alphabetical: Fix grammar before More formal.
    #expect(NoteEditCommands.mostUsed(data, limit: 2) == ["Fix grammar", "More formal"])
  }

  @Test("Empty / malformed usage data decodes to nothing")
  func emptyUsage() {
    #expect(NoteEditCommands.mostUsed(Data()).isEmpty)
    #expect(NoteEditCommands.mostUsed(Data("not json".utf8)).isEmpty)
  }
}
