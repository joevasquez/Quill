import Foundation
import Testing
@testable import HexCore

@Suite("Cloud note speaker metadata")
struct CloudNoteSpeakerSyncTests {
  @Test("Firestore note round trip keeps speaker metadata")
  func firestoreRoundTrip() async throws {
    let note = SyncableNote(
      id: UUID(), title: "Conversation", body: "Speaker 1:\nHello.",
      createdAt: Date(), updatedAt: Date(),
      transcriptionMetadataJSON: "[{\"speaker\":\"Melissa\"}]",
      sourceDevice: "iphone", sourcePlatform: .iOS
    )
    let client = FirestoreClient()
    let fields = client.noteToFields(note)
    let typedFields = fields.compactMapValues { $0 as? [String: Any] }
    let loaded = client.fieldsToNote(typedFields)
    #expect(loaded?.transcriptionMetadataJSON == note.transcriptionMetadataJSON)
    #expect(loaded?.body == note.body)
  }

  @Test("oversized speaker metadata is omitted before upload")
  func oversizedMetadataIsOmitted() {
    let note = SyncableNote(
      id: UUID(), title: "Long conversation", body: String(repeating: "a", count: 700_000),
      createdAt: Date(), updatedAt: Date(),
      transcriptionMetadataJSON: String(repeating: "b", count: 300_000),
      sourceDevice: "iphone", sourcePlatform: .iOS
    )
    let fields = FirestoreClient().noteToFields(note)
    #expect(fields["transcriptionMetadataJSON"] == nil)
  }
}
