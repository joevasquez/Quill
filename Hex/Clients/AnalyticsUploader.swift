#if os(macOS)
import ComposableArchitecture
import Dependencies
import Foundation
import HexCore
import os
import Sharing

private let analyticsLogger = Logger(subsystem: "com.joevasquez.Quill", category: "analytics")

/// Debounced analytics uploader that batches local usage stats into a single
/// Firestore document per user. Uploads are fire-and-forget — failures are
/// logged but never surface to the user.
@MainActor
final class AnalyticsUploader: ObservableObject {
    static let shared = AnalyticsUploader()

    private let client = AnalyticsFirestoreClient()
    private let appOpensKey = "quill.analytics.appOpens"
    private let firstSeenKey = "quill.analytics.firstSeenAt"
    private var pendingUpload: Task<Void, Never>?

    private init() {}

    /// Call on every app launch to bump the open counter and schedule an upload.
    func recordAppOpen() {
        let current = UserDefaults.standard.integer(forKey: appOpensKey)
        UserDefaults.standard.set(current + 1, forKey: appOpensKey)

        if UserDefaults.standard.object(forKey: firstSeenKey) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: firstSeenKey)
        }

        scheduleUpload()
    }

    /// Call after each transcription completes (stats have already been
    /// incremented in the reducer). Debounces so rapid dictations don't
    /// fire multiple uploads.
    func scheduleUpload() {
        pendingUpload?.cancel()
        pendingUpload = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await upload()
        }
    }

    private func upload() async {
        guard let email = getUserEmail(),
              let accessToken = await getAccessToken()
        else { return }

        @Shared(.hexSettings) var hexSettings: HexSettings
        @Shared(.usageStats) var usageStats: UsageStats

        let appOpens = UserDefaults.standard.integer(forKey: appOpensKey)
        let firstSeenInterval = UserDefaults.standard.double(forKey: firstSeenKey)
        let firstSeen = firstSeenInterval > 0 ? Date(timeIntervalSince1970: firstSeenInterval) : Date()

        let rawIntegrations = UserDefaults.standard.data(forKey: IntegrationConnectionStore.userDefaultsKey)
        let connectedIntegrations = IntegrationConnectionStore.decode(rawIntegrations).map(\.rawValue)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        let analytics = UserAnalytics(
            totalWordsTranscribed: usageStats.totalWordsTranscribed,
            dictationCount: usageStats.dictationCount,
            editCount: usageStats.editCount,
            actionCount: usageStats.actionCount,
            appOpens: appOpens,
            displayMode: hexSettings.displayMode.rawValue,
            selectedModel: hexSettings.selectedModel,
            selectedPlan: hexSettings.selectedPlan,
            connectedIntegrations: connectedIntegrations,
            appVersion: version,
            platform: "macOS",
            firstSeenAt: firstSeen,
            lastActiveAt: Date()
        )

        do {
            try await client.uploadAnalytics(analytics, userEmail: email, accessToken: accessToken)
            analyticsLogger.info("Analytics uploaded successfully")
        } catch {
            analyticsLogger.error("Analytics upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func getAccessToken() async -> String? {
        @Dependency(\.googleOAuth) var googleOAuth
        do {
            return try await googleOAuth.refreshIfNeeded()
        } catch {
            return nil
        }
    }

    private func getUserEmail() -> String? {
        UserDefaults.standard.string(forKey: GoogleOAuthClient.googleAccountEmailDefaultsKey)
    }
}

#endif
