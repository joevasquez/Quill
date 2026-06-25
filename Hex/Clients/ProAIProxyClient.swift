#if os(macOS)
import Dependencies
import Foundation
import HexCore
import os

private let proLogger = HexLog.aiProcessing

/// Routes AI processing requests through a GCP Cloud Function proxy when
/// the user is on the Pro plan. The proxy holds the Anthropic API key
/// server-side — Pro users never need to enter their own key.
///
/// The proxy validates the caller's Google OAuth access token, checks Pro
/// status in Firestore, and forwards the request to Anthropic.
enum ProAIProxyClient {
    /// Cloud Function endpoint. Update this after deploying the function.
    static let proxyURL = "https://us-central1-quill-495210.cloudfunctions.net/quill-ai-proxy"

    static func process(
        text: String,
        systemPrompt: String,
        accessToken: String,
        skipTranscriptWrapping: Bool = false
    ) async throws -> String {
        let url = URL(string: proxyURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let userMessage = skipTranscriptWrapping ? text : TranscriptWrapper.wrap(text)

        let body: [String: Any] = [
            "systemPrompt": systemPrompt,
            "userMessage": userMessage,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        proLogger.info("Sending text to Pro AI proxy (\(text.count) chars)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProAIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            proLogger.error("Pro AI proxy error \(httpResponse.statusCode): \(errorBody, privacy: .private)")
            throw ProAIError.apiError(httpResponse.statusCode, errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? String
        else {
            throw ProAIError.unexpectedFormat
        }

        proLogger.info("Pro AI processing complete (\(content.count) chars)")
        return content
    }
}

enum ProAIError: LocalizedError {
    case invalidResponse
    case apiError(Int, String)
    case unexpectedFormat
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from Pro AI service"
        case .apiError(let code, _):
            "Pro AI service returned error \(code)"
        case .unexpectedFormat:
            "Unexpected response format from Pro AI service"
        case .notAuthorized:
            "Sign in with Google to use Pro AI features"
        }
    }
}

#endif
