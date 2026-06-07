import Foundation

public struct UsageStats: Codable, Equatable, Sendable {
    public var totalWordsTranscribed: Int
    public var dictationCount: Int
    public var editCount: Int
    public var actionCount: Int

    public init(
        totalWordsTranscribed: Int = 0,
        dictationCount: Int = 0,
        editCount: Int = 0,
        actionCount: Int = 0
    ) {
        self.totalWordsTranscribed = totalWordsTranscribed
        self.dictationCount = dictationCount
        self.editCount = editCount
        self.actionCount = actionCount
    }

    // MARK: - Computed

    public var totalSessions: Int {
        dictationCount + editCount + actionCount
    }

    /// Estimated minutes saved assuming 40 WPM average typing speed.
    public var estimatedMinutesSaved: Double {
        Double(totalWordsTranscribed) / 40.0
    }
}
