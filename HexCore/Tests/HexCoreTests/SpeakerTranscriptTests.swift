import Foundation
import Testing
@testable import HexCore

@Suite("Speaker transcripts")
struct SpeakerTranscriptTests {
    @Test("legacy transcripts decode without speaker data")
    func legacyTranscriptDecoding() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "timestamp":0,
          "text":"A legacy transcript",
          "audioPath":"file:///tmp/legacy.m4a",
          "duration":4
        }
        """#

        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))

        #expect(transcript.text == "A legacy transcript")
        #expect(transcript.speakerTranscript == nil)
    }

    @Test("words are assigned to the speaker with the greatest overlap")
    func alignsWordsToSpeakers() {
        let words = [
            TimedTranscriptWord(text: "Hello", startTime: 0.0, endTime: 0.5),
            TimedTranscriptWord(text: "there.", startTime: 0.5, endTime: 1.0),
            TimedTranscriptWord(text: "Hi", startTime: 1.1, endTime: 1.4),
            TimedTranscriptWord(text: "Joe.", startTime: 1.4, endTime: 1.8),
        ]
        let regions = [
            SpeakerTimeRange(speakerID: "speaker_0", startTime: 0, endTime: 1.05),
            SpeakerTimeRange(speakerID: "speaker_1", startTime: 1.05, endTime: 2),
        ]

        let result = SpeakerTranscriptAssembler.assemble(words: words, speakerRanges: regions)

        #expect(result?.speakers.map(\.id) == ["speaker_0", "speaker_1"])
        #expect(result?.utterances.map(\.speakerID) == ["speaker_0", "speaker_1"])
        #expect(result?.utterances.map(\.text) == ["Hello there.", "Hi Joe."])
    }

    @Test("a speaker rename updates every linked utterance without rewriting text")
    func renameSpeaker() throws {
        var result = try #require(SpeakerTranscriptAssembler.assemble(
            words: [
                TimedTranscriptWord(text: "First.", startTime: 0, endTime: 0.5),
                TimedTranscriptWord(text: "Second.", startTime: 1, endTime: 1.5),
                TimedTranscriptWord(text: "Third.", startTime: 2, endTime: 2.5),
            ],
            speakerRanges: [
                SpeakerTimeRange(speakerID: "a", startTime: 0, endTime: 0.6),
                SpeakerTimeRange(speakerID: "b", startTime: 0.9, endTime: 1.6),
                SpeakerTimeRange(speakerID: "a", startTime: 1.9, endTime: 2.6),
            ]
        ))

        result.renameSpeaker(id: "a", to: "Joe")

        #expect(result.displayName(for: "a") == "Joe")
        #expect(result.displayName(for: "b") == "Speaker 2")
        #expect(result.utterances.map(\.text) == ["First.", "Second.", "Third."])
        #expect(result.formattedText.contains("Joe:\nFirst."))
        #expect(result.formattedText.contains("Joe:\nThird."))
    }

    @Test("empty or single-speaker diarization does not create conversation data")
    func requiresMultipleSpeakers() {
        let words = [TimedTranscriptWord(text: "Hello", startTime: 0, endTime: 1)]

        #expect(SpeakerTranscriptAssembler.assemble(words: words, speakerRanges: []) == nil)
        #expect(SpeakerTranscriptAssembler.assemble(
            words: words,
            speakerRanges: [SpeakerTimeRange(speakerID: "only", startTime: 0, endTime: 1)]
        ) == nil)
    }

    @Test("speaker transcript survives Codable round trip")
    func codableRoundTrip() throws {
        let conversation = SpeakerTranscript(
            speakers: [TranscriptSpeaker(id: "speaker_0", displayName: "Alex", colorIndex: 0)],
            utterances: [
                SpeakerUtterance(
                    speakerID: "speaker_0",
                    startTime: 0,
                    endTime: 1,
                    text: "Hello."
                )
            ]
        )
        let transcript = Transcript(
            timestamp: Date(timeIntervalSince1970: 1),
            text: "Hello.",
            audioPath: URL(fileURLWithPath: "/tmp/test.m4a"),
            duration: 1,
            speakerTranscript: conversation
        )

        let decoded = try JSONDecoder().decode(
            Transcript.self,
            from: JSONEncoder().encode(transcript)
        )

        #expect(decoded == transcript)
        #expect(decoded.speakerTranscript?.formattedText == "Alex:\nHello.")
    }
}
