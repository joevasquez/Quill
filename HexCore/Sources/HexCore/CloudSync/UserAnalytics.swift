import Foundation

/// Per-user analytics snapshot uploaded to Firestore. This captures the same
/// data shown on the macOS Settings → History stats card, plus engagement and
/// preference signals that are useful for understanding usage patterns.
public struct UserAnalytics: Codable, Equatable, Sendable {
    public var totalWordsTranscribed: Int
    public var dictationCount: Int
    public var editCount: Int
    public var actionCount: Int
    public var appOpens: Int
    public var displayMode: String
    public var selectedModel: String
    public var selectedPlan: String?
    public var connectedIntegrations: [String]
    public var appVersion: String
    public var platform: String
    public var firstSeenAt: Date
    public var lastActiveAt: Date

    public init(
        totalWordsTranscribed: Int = 0,
        dictationCount: Int = 0,
        editCount: Int = 0,
        actionCount: Int = 0,
        appOpens: Int = 0,
        displayMode: String = "hud",
        selectedModel: String = "",
        selectedPlan: String? = nil,
        connectedIntegrations: [String] = [],
        appVersion: String = "",
        platform: String = "macOS",
        firstSeenAt: Date = Date(),
        lastActiveAt: Date = Date()
    ) {
        self.totalWordsTranscribed = totalWordsTranscribed
        self.dictationCount = dictationCount
        self.editCount = editCount
        self.actionCount = actionCount
        self.appOpens = appOpens
        self.displayMode = displayMode
        self.selectedModel = selectedModel
        self.selectedPlan = selectedPlan
        self.connectedIntegrations = connectedIntegrations
        self.appVersion = appVersion
        self.platform = platform
        self.firstSeenAt = firstSeenAt
        self.lastActiveAt = lastActiveAt
    }

    public var totalSessions: Int {
        dictationCount + editCount + actionCount
    }

    public var estimatedMinutesSaved: Double {
        Double(totalWordsTranscribed) / 40.0
    }
}
