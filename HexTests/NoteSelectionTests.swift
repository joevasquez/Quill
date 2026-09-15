import Foundation
import Testing

@testable import Hex

@Suite(.serialized)
@MainActor
struct NoteSelectionTests {
  @Test
  func selectionPublicationIsDeferredBeyondTheCurrentViewUpdate() async {
    let selection = NoteSelectionState.shared
    selection.selectedNoteID = nil
    defer { selection.selectedNoteID = nil }

    let noteID = UUID()
    selection.selectAfterViewUpdate(noteID)

    // Publishing synchronously here is what causes SwiftUI's
    // "Publishing changes from within view updates" warning.
    #expect(selection.selectedNoteID == nil)

    for _ in 0..<10 where selection.selectedNoteID != noteID {
      await Task.yield()
    }
    #expect(selection.selectedNoteID == noteID)
  }
}
