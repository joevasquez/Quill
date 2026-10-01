import Testing
@testable import HexCore

@Suite("AI processing modes")
struct AIProcessingModeTests {
    @Test("only Transcript mode enables speaker diarization")
    func speakerDiarizationPolicy() {
        #expect(AIProcessingMode.off.supportsAutomaticSpeakerDiarization)
        #expect(!AIProcessingMode.clean.supportsAutomaticSpeakerDiarization)
        #expect(!AIProcessingMode.email.supportsAutomaticSpeakerDiarization)
        #expect(!AIProcessingMode.notes.supportsAutomaticSpeakerDiarization)
        #expect(!AIProcessingMode.message.supportsAutomaticSpeakerDiarization)
        #expect(!AIProcessingMode.code.supportsAutomaticSpeakerDiarization)
    }

    @Test("Transcript keeps the legacy persisted value")
    func transcriptPersistenceCompatibility() {
        #expect(AIProcessingMode.off.rawValue == "off")
    }
}
