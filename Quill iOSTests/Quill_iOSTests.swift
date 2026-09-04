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

}
