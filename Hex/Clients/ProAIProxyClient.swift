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
    /// Cloud Function endpoint (defined once in `LLMTransport`).
    static let proxyURL = LLMTransport.proProxyURL

    static func process(
        text: String,
        systemPrompt: String,
        accessToken: String,
        skipTranscriptWrapping: Bool = false
    ) async throws -> String {
        let userMessage = skipTranscriptWrapping ? text : TranscriptWrapper.wrap(text)

        do {
            let content = try await LLMTransport.complete(
                userMessage: userMessage,
                systemPrompt: systemPrompt,
                credential: .proProxy(accessToken: accessToken)
            )
            proLogger.info("Pro AI processing complete (\(content.count) chars)")
            return content
        } catch let error as LLMTransportError {
            // Preserve the historical error surface for existing callers.
            switch error {
            case .apiError(let code, let body):
                throw ProAIError.apiError(code, body)
            case .invalidResponse:
                throw ProAIError.unexpectedFormat
            }
        }
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
