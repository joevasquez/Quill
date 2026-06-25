import Foundation
import os

private let analyticsLogger = Logger(subsystem: "com.joevasquez.Quill", category: "analytics")

/// Writes per-user analytics snapshots to Firestore so usage data is
/// visible in the GCP console (or via Firestore queries/exports).
///
/// Document path: `users/{sanitizedEmail}/analytics/usage`
///
/// This is a simple upsert — each upload overwrites the previous snapshot.
/// Firestore's built-in `updateTime` on the document serves as the
/// server-side "last seen" timestamp.
public actor AnalyticsFirestoreClient {
    private let projectID: String
    private let databaseID: String
    private let baseURL: String

    public init(
        projectID: String = CloudSyncConstants.gcpProjectID,
        databaseID: String = CloudSyncConstants.firestoreDatabaseID
    ) {
        self.projectID = projectID
        self.databaseID = databaseID
        self.baseURL = "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/\(databaseID)/documents"
    }

    public func uploadAnalytics(_ analytics: UserAnalytics, userEmail: String, accessToken: String) async throws {
        let sanitized = sanitizeEmail(userEmail)
        let path = "users/\(sanitized)/analytics/usage"
        let fields = analyticsToFields(analytics)
        try await upsertDocument(path: path, fields: fields, accessToken: accessToken)
        analyticsLogger.info("Uploaded analytics for \(sanitized, privacy: .public)")
    }

    public func fetchAnalytics(userEmail: String, accessToken: String) async throws -> UserAnalytics? {
        let path = "users/\(sanitizeEmail(userEmail))/analytics/usage"
        let url = URL(string: "\(baseURL)/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        if http.statusCode == 404 { return nil }

        guard http.statusCode == 200 else {
            analyticsLogger.error("Firestore GET analytics failed: HTTP \(http.statusCode, privacy: .public)")
            return nil
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = json["fields"] as? [String: [String: Any]]
        else { return nil }

        return fieldsToAnalytics(fields)
    }

    // MARK: - Field encoding

    private func analyticsToFields(_ a: UserAnalytics) -> [String: Any] {
        var fields: [String: Any] = [
            "totalWordsTranscribed": ["integerValue": String(a.totalWordsTranscribed)],
            "dictationCount": ["integerValue": String(a.dictationCount)],
            "editCount": ["integerValue": String(a.editCount)],
            "actionCount": ["integerValue": String(a.actionCount)],
            "appOpens": ["integerValue": String(a.appOpens)],
            "totalSessions": ["integerValue": String(a.totalSessions)],
            "estimatedMinutesSaved": ["doubleValue": a.estimatedMinutesSaved],
            "displayMode": ["stringValue": a.displayMode],
            "selectedModel": ["stringValue": a.selectedModel],
            "appVersion": ["stringValue": a.appVersion],
            "platform": ["stringValue": a.platform],
            "firstSeenAt": ["timestampValue": iso8601(a.firstSeenAt)],
            "lastActiveAt": ["timestampValue": iso8601(a.lastActiveAt)],
        ]

        if let plan = a.selectedPlan {
            fields["selectedPlan"] = ["stringValue": plan]
        }

        if !a.connectedIntegrations.isEmpty {
            let values = a.connectedIntegrations.map { integration in
                ["stringValue": integration] as [String: Any]
            }
            fields["connectedIntegrations"] = ["arrayValue": ["values": values]]
        }

        return fields
    }

    private func fieldsToAnalytics(_ fields: [String: [String: Any]]) -> UserAnalytics? {
        func intField(_ key: String) -> Int {
            if let str = fields[key]?["integerValue"] as? String {
                return Int(str) ?? 0
            }
            return 0
        }

        guard let firstSeenStr = fields["firstSeenAt"]?["timestampValue"] as? String,
              let firstSeen = parseISO8601(firstSeenStr)
        else { return nil }

        let lastActiveStr = fields["lastActiveAt"]?["timestampValue"] as? String
        let lastActive = lastActiveStr.flatMap { parseISO8601($0) } ?? firstSeen

        var integrations: [String] = []
        if let arrayVal = fields["connectedIntegrations"]?["arrayValue"] as? [String: Any],
           let values = arrayVal["values"] as? [[String: Any]] {
            integrations = values.compactMap { $0["stringValue"] as? String }
        }

        return UserAnalytics(
            totalWordsTranscribed: intField("totalWordsTranscribed"),
            dictationCount: intField("dictationCount"),
            editCount: intField("editCount"),
            actionCount: intField("actionCount"),
            appOpens: intField("appOpens"),
            displayMode: fields["displayMode"]?["stringValue"] as? String ?? "hud",
            selectedModel: fields["selectedModel"]?["stringValue"] as? String ?? "",
            selectedPlan: fields["selectedPlan"]?["stringValue"] as? String,
            connectedIntegrations: integrations,
            appVersion: fields["appVersion"]?["stringValue"] as? String ?? "",
            platform: fields["platform"]?["stringValue"] as? String ?? "macOS",
            firstSeenAt: firstSeen,
            lastActiveAt: lastActive
        )
    }

    // MARK: - REST helpers

    private func upsertDocument(path: String, fields: [String: Any], accessToken: String) async throws {
        let url = URL(string: "\(baseURL)/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = ["fields": fields]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            analyticsLogger.error("Firestore analytics PATCH failed: HTTP \(code, privacy: .public)")
            throw AnalyticsUploadError.uploadFailed(code)
        }
    }

    private func sanitizeEmail(_ email: String) -> String {
        email.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "@", with: "_at_")
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func parseISO8601(_ string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

public enum AnalyticsUploadError: LocalizedError {
    case uploadFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .uploadFailed(let code): "Analytics upload failed (HTTP \(code))"
        }
    }
}
