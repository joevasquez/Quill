import Foundation

public struct TimestampedTranscription: Codable, Equatable, Sendable {
    public var text: String
    public var words: [TimedTranscriptWord]

    public init(text: String, words: [TimedTranscriptWord]) {
        self.text = text
        self.words = words
    }
}

/// A timestamped unit of recognized text. Kept independent of any ASR SDK so
/// speaker attribution can be shared by the macOS and iOS targets.
public struct TimedTranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Float?

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

/// A diarizer's answer to "who spoke when?". Speaker IDs are meaningful only
/// within one recording unless a future opt-in voice-profile feature maps them.
public struct SpeakerTimeRange: Codable, Equatable, Sendable {
    public var speakerID: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(speakerID: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct TranscriptSpeaker: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var displayName: String?
    public var colorIndex: Int

    public init(id: String, displayName: String? = nil, colorIndex: Int) {
        self.id = id
        self.displayName = displayName
        self.colorIndex = colorIndex
    }
}

public struct SpeakerUtterance: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var speakerID: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String

    public init(
        id: UUID = UUID(),
        speakerID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct SpeakerTranscript: Codable, Equatable, Hashable, Sendable {
    public var speakers: [TranscriptSpeaker]
    public var utterances: [SpeakerUtterance]

    public init(speakers: [TranscriptSpeaker], utterances: [SpeakerUtterance]) {
        self.speakers = speakers
        self.utterances = utterances
    }

    public func displayName(for speakerID: String) -> String {
        guard let index = speakers.firstIndex(where: { $0.id == speakerID }) else {
            return "Unknown Speaker"
        }
        let customName = speakers[index].displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let customName, !customName.isEmpty { return customName }
        return "Speaker \(index + 1)"
    }

    public mutating func renameSpeaker(id: String, to name: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers[index].displayName = trimmed.isEmpty ? nil : trimmed
    }

    /// A portable plain-text representation for copy/export and older clients.
    public var formattedText: String {
        utterances.map { utterance in
            "\(displayName(for: utterance.speakerID)):\n\(utterance.text)"
        }.joined(separator: "\n\n")
    }
}

public enum SpeakerTranscriptAssembler {
    /// Aligns ASR words with diarizer regions and groups adjacent words into
    /// readable turns. Returns nil when fewer than two speakers are present so
    /// ordinary dictation retains its existing compact representation.
    public static func assemble(
        words: [TimedTranscriptWord],
        speakerRanges: [SpeakerTimeRange],
        maximumSameSpeakerGap: TimeInterval = 1.5
    ) -> SpeakerTranscript? {
        let validWords = words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime < $1.startTime }
        let validRanges = speakerRanges
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        guard !validWords.isEmpty, !validRanges.isEmpty else { return nil }

        var attributed: [(word: TimedTranscriptWord, speakerID: String)] = []
        attributed.reserveCapacity(validWords.count)
        for word in validWords {
            guard let speakerID = bestSpeaker(for: word, ranges: validRanges) else { continue }
            attributed.append((word, speakerID))
        }

        var orderedSpeakerIDs: [String] = []
        for item in attributed where !orderedSpeakerIDs.contains(item.speakerID) {
            orderedSpeakerIDs.append(item.speakerID)
        }
        guard orderedSpeakerIDs.count >= 2 else { return nil }

        var utterances: [SpeakerUtterance] = []
        for item in attributed {
            if let lastIndex = utterances.indices.last,
               utterances[lastIndex].speakerID == item.speakerID,
               item.word.startTime - utterances[lastIndex].endTime <= maximumSameSpeakerGap {
                utterances[lastIndex].text = appending(item.word.text, to: utterances[lastIndex].text)
                utterances[lastIndex].endTime = max(utterances[lastIndex].endTime, item.word.endTime)
            } else {
                utterances.append(SpeakerUtterance(
                    speakerID: item.speakerID,
                    startTime: item.word.startTime,
                    endTime: item.word.endTime,
                    text: item.word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }

        let speakers = orderedSpeakerIDs.enumerated().map { index, id in
            TranscriptSpeaker(id: id, colorIndex: index)
        }
        return SpeakerTranscript(speakers: speakers, utterances: utterances)
    }

    private static func bestSpeaker(
        for word: TimedTranscriptWord,
        ranges: [SpeakerTimeRange]
    ) -> String? {
        let overlaps = ranges.map { range -> (range: SpeakerTimeRange, overlap: TimeInterval) in
            let overlap = max(0, min(word.endTime, range.endTime) - max(word.startTime, range.startTime))
            return (range, overlap)
        }
        if let best = overlaps.max(by: { $0.overlap < $1.overlap }), best.overlap > 0 {
            return best.range.speakerID
        }

        // Timestamp boundaries from independent models can differ slightly.
        // Attribute an unmatched word to the closest diarization region.
        let midpoint = (word.startTime + word.endTime) / 2
        return ranges.min { lhs, rhs in
            distance(from: midpoint, to: lhs) < distance(from: midpoint, to: rhs)
        }?.speakerID
    }

    private static func distance(from time: TimeInterval, to range: SpeakerTimeRange) -> TimeInterval {
        if time < range.startTime { return range.startTime - time }
        if time > range.endTime { return time - range.endTime }
        return 0
    }

    private static func appending(_ rawWord: String, to text: String) -> String {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return text }
        guard let first = word.first else { return text }
        let punctuation = CharacterSet.punctuationCharacters
        if first.unicodeScalars.allSatisfy({ punctuation.contains($0) }) {
            return text + word
        }
        return text.isEmpty ? word : text + " " + word
    }
}
