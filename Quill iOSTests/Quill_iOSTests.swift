//
//  Quill_iOSTests.swift
//  Quill iOSTests
//
//  Created by Joe Vasquez on 4/18/26.
//

import Foundation
import Testing
@testable import Quill_iOS

struct Quill_iOSTests {

    @Test("live transcript is separate from existing note text")
    func liveTranscriptPreservesExistingText() {
        let sessionID = UUID()
        var note = Note(title: "Trip", body: "Pack a charger")

        note.beginPendingTranscription(id: sessionID)
        let firstUpdate = note.updatePendingTranscription(id: sessionID, text: "Book a")
        #expect(firstUpdate)
        #expect(note.body == "Pack a charger")
        #expect(note.bodyIncludingPendingTranscription == "Pack a charger\n\nBook a")

        let secondUpdate = note.updatePendingTranscription(id: sessionID, text: "Book a hotel")
        #expect(secondUpdate)
        #expect(note.body == "Pack a charger")
        #expect(note.bodyIncludingPendingTranscription == "Pack a charger\n\nBook a hotel")
    }

    @Test("final transcript replaces the provisional paragraph exactly once")
    func finalTranscriptReplacesDraft() {
        let sessionID = UUID()
        var note = Note(title: "Trip", body: "Pack a charger")
        note.beginPendingTranscription(id: sessionID)
        _ = note.updatePendingTranscription(id: sessionID, text: "Book a hot towel")

        let appended = note.finalizePendingTranscription(
            id: sessionID,
            finalText: "Book a hotel"
        )

        #expect(appended == "Book a hotel")
        #expect(note.body == "Pack a charger\n\nBook a hotel")
        #expect(note.pendingTranscription == nil)
        let duplicateFinalization = note.finalizePendingTranscription(id: sessionID, finalText: "Book a hotel")
        #expect(duplicateFinalization == nil)
        #expect(note.body == "Pack a charger\n\nBook a hotel")
    }

    @Test("discard removes only the provisional paragraph")
    func discardPreservesExistingText() {
        let sessionID = UUID()
        var note = Note(title: "Trip", body: "Pack a charger")
        note.beginPendingTranscription(id: sessionID)
        _ = note.updatePendingTranscription(id: sessionID, text: "Temporary words")

        let discarded = note.discardPendingTranscription(id: sessionID)
        #expect(discarded)
        #expect(note.body == "Pack a charger")
        #expect(note.pendingTranscription == nil)
    }

    @Test("an interrupted live draft can be recovered into the note")
    func interruptedDraftRecovery() {
        let sessionID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 200)
        var note = Note(
            title: "Trip",
            body: "Pack a charger",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        note.beginPendingTranscription(id: sessionID, at: Date(timeIntervalSince1970: 150))
        _ = note.updatePendingTranscription(
            id: sessionID,
            text: "Book a hotel",
            at: updatedAt
        )

        let recovered = note.recoverPendingTranscription()
        #expect(recovered)
        #expect(note.body == "Pack a charger\n\nBook a hotel")
        #expect(note.updatedAt == updatedAt)
        #expect(note.pendingTranscription == nil)
    }

    @Test("a stale recording session cannot overwrite the current draft")
    func staleSessionIsIgnored() {
        let currentSessionID = UUID()
        var note = Note(title: "Trip", body: "Pack a charger")
        note.beginPendingTranscription(id: currentSessionID)

        let staleUpdate = note.updatePendingTranscription(id: UUID(), text: "Wrong take")
        #expect(!staleUpdate)
        #expect(note.pendingTranscription?.text == "")
    }

    @Test("revoked Google refresh tokens require reconnecting")
    func invalidGrantRequiresReconnect() {
        let invalidGrant = Data(#"{"error":"invalid_grant"}"#.utf8)
        let temporaryFailure = Data(#"{"error":"temporarily_unavailable"}"#.utf8)

        #expect(IOSGoogleOAuthClient.requiresReconnect(statusCode: 400, data: invalidGrant))
        #expect(!IOSGoogleOAuthClient.requiresReconnect(statusCode: 400, data: temporaryFailure))
        #expect(!IOSGoogleOAuthClient.requiresReconnect(statusCode: 500, data: invalidGrant))
    }

    @Test("long recordings always use segmented transcription")
    func longRecordingsUseSegmentedTranscription() {
        #expect(IOSLongRecordingPolicy.transcriptionStrategy(for: 30 * 60) == .voiceActivityChunks)
    }

    @Test("a recording is incomplete when captured audio is much shorter than elapsed time")
    func truncatedCaptureIsRejected() {
        let audit = IOSLongRecordingPolicy.audit(
            elapsedDuration: 30 * 60,
            capturedDuration: 3 * 60
        )

        #expect(audit == .truncated)
    }

    @Test("a complete long recording passes the capture audit")
    func completeCapturePassesAudit() {
        let audit = IOSLongRecordingPolicy.audit(
            elapsedDuration: 30 * 60,
            capturedDuration: (30 * 60) - 2
        )

        #expect(audit == .complete)
    }

    @Test("live recognition restarts append instead of replacing earlier recording text")
    func restartedLiveRecognitionKeepsEarlierText() {
        var transcript = IOSLiveTranscriptAccumulator()

        #expect(transcript.update(hypothesis: "First section") == "First section")
        transcript.finishRecognitionTask()
        #expect(transcript.update(hypothesis: "Second section") == "First section Second section")
    }

    @Test("long transcripts are split into bounded AI formatting requests")
    func longAIFormattingIsChunkedWithoutDroppingContent() {
        let paragraphs = (0..<20).map { "Paragraph \($0): " + String(repeating: "detail ", count: 45) }
        let input = paragraphs.joined(separator: "\n\n")
        let chunks = IOSLongTextChunker.chunks(input, maxCharacters: 1_000)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 1_000 })
        for index in 0..<20 {
            #expect(chunks.joined(separator: "\n\n").contains("Paragraph \(index):"))
        }
    }

    @Test("interrupted recordings survive relaunch in the recovery catalog")
    @MainActor
    func interruptedRecordingSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-recovery-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("recording.wav")
        try Data([0, 1, 2, 3]).write(to: audioURL)

        let first = RecordingRecoveryStore(directory: directory)
        let id = first.begin(audioURL: audioURL, startedAt: Date(timeIntervalSince1970: 100))
        first.checkpoint(
            id: id,
            noteID: UUID(),
            expectedDuration: 90,
            capturedDuration: 88,
            liveTranscript: "We agreed to ship Friday"
        )

        let relaunched = RecordingRecoveryStore(directory: directory)
        let restored = try #require(relaunched.recordings.first)
        #expect(restored.id == id)
        #expect(restored.state == .needsRecovery)
        #expect(restored.liveTranscript == "We agreed to ship Friday")
        #expect(restored.capturedDuration == 88)
        #expect(restored.audioURL(in: directory) == audioURL)
    }

    @Test("completing recovery removes its catalog entry and audio")
    @MainActor
    func completedRecoveryCleansUp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-recovery-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("recording.wav")
        try Data([0, 1, 2, 3]).write(to: audioURL)

        let store = RecordingRecoveryStore(directory: directory)
        let id = store.begin(audioURL: audioURL)
        store.complete(id: id, deleteAudio: true)

        #expect(store.recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test("Ask Quill ranks matching notes ahead of merely recent notes")
    func askQuillRanksRelevantNotes() {
        let launch = Note(
            title: "Launch Plan",
            body: "Maya owns the September release notes and launch checklist.",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let groceries = Note(
            title: "Groceries",
            body: "Milk, eggs, and coffee.",
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let selected = NoteQuestionContextBuilder.select(
            notes: [groceries, launch],
            question: "Who owns the launch release notes?",
            maxNotes: 1,
            maxCharacters: 2_000
        )

        #expect(selected.map(\.id) == [launch.id])
    }

    @Test("Ask Quill extracts a relevant passage from late in a long note")
    func askQuillFindsLatePassage() {
        let note = Note(
            title: "Conference Notes",
            body: String(repeating: "Earlier unrelated material. ", count: 500)
                + "The important data lakes lesson was to separate storage from compute."
        )

        let context = NoteQuestionContextBuilder.context(
            from: [note],
            question: "What did we learn about data lakes?",
            maxCharacters: 1_200
        )

        #expect(context.contains("data lakes lesson"))
        #expect(context.count <= 1_200)
    }

    @Test("Ask Quill drops citations to notes outside the supplied context")
    func askQuillValidatesCitations() throws {
        let allowed = Note(title: "Launch", body: "Ship Friday")
        let unknownID = UUID()
        let raw = """
        {
          "answer": "The launch is Friday.",
          "citations": [
            {"noteID": "\(allowed.id.uuidString)", "excerpt": "Ship Friday"},
            {"noteID": "\(unknownID.uuidString)", "excerpt": "Unknown"}
          ]
        }
        """

        let answer = try NoteAnswerParser.parse(raw, allowedNotes: [allowed])

        #expect(answer.citations.count == 1)
        #expect(answer.citations.first?.noteID == allowed.id)
        #expect(answer.citations.first?.noteTitle == "Launch")
    }

    @Test("Ask Quill sends a question, not a transcript transformation")
    func askQuillDoesNotUseDictationWrapper() {
        let request = NoteQuestionRequestBuilder.build(
            question: "What did we learn about data lakes?",
            context: "<note id=\"1\">Lakehouses combine both approaches.</note>"
        )

        #expect(request.contains("<question>What did we learn about data lakes?</question>"))
        #expect(!request.localizedCaseInsensitiveContains("apply the transformation"))
        #expect(!request.contains("<transcript>"))
    }

    @Test("Ask Quill rejects post-processor refusal answers")
    func askQuillRejectsTransformationRefusal() {
        let note = Note(title: "Data Lakes", body: "Lakehouses combine both approaches.")
        let raw = """
        {
          "answer": "The notes do not contain instructions about applying the system-prompt transformation, so I cannot perform that transformation.",
          "citations": [{"noteID": "\(note.id.uuidString)", "excerpt": "Lakehouses combine both approaches."}]
        }
        """

        #expect(throws: TextAIError.self) {
            try NoteAnswerParser.parse(raw, allowedNotes: [note])
        }
    }

    @Test("Ask Quill does not display invented source excerpts")
    func askQuillRejectsInventedCitationExcerpt() throws {
        let note = Note(title: "Data Lakes", body: "Separate storage from compute.")
        let raw = """
        {
          "answer": "Storage and compute should be separated.",
          "citations": [{"noteID": "\(note.id.uuidString)", "excerpt": "Use one giant database."}]
        }
        """

        let answer = try NoteAnswerParser.parse(raw, allowedNotes: [note])
        #expect(answer.citations.isEmpty)
    }

}
