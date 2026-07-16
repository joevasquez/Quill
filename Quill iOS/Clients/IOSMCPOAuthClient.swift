//
//  IOSMCPOAuthClient.swift
//  Quill (iOS)
//
//  iOS shell around HexCore's `MCPOAuthOrchestrator`: supplies the
//  `KeychainStore`-backed token storage and the `ASWebAuthenticationSession`
//  browser leg anchored to the foreground scene's key window. All flow logic
//  (discovery, RFC 7591 registration, PKCE, token exchange/refresh) lives in
//  HexCore, shared with macOS.
//

import AuthenticationServices
import Foundation
import HexCore
import UIKit

@MainActor
enum IOSMCPOAuthClient {
  private static var orchestrator: MCPOAuthOrchestrator {
    MCPOAuthOrchestrator(
      storage: IOSMCPTokenStorage(),
      authorize: { authURL, expectedState in
        try await runWebAuth(authURL: authURL, expectedState: expectedState)
      }
    )
  }

  /// The bearer token to authenticate an MCP request: a valid OAuth access
  /// token (refreshed if needed) when the server is OAuth-connected, else
  /// the static token, else nil.
  static func resolveAuthToken(for server: MCPServerConfig) async -> String? {
    await orchestrator.resolveAuthToken(for: server)
  }

  static func isSignedIn(_ server: MCPServerConfig) async -> Bool {
    await orchestrator.isSignedIn(server)
  }

  static func signOut(_ server: MCPServerConfig) async {
    await orchestrator.signOut(server)
  }

  static func signIn(server: MCPServerConfig) async throws {
    try await orchestrator.signIn(server: server)
  }

  /// Whether the server publishes OAuth metadata (i.e. supports browser
  /// sign-in) even if it doesn't 401 anonymous catalog requests.
  static func advertisesOAuth(_ server: MCPServerConfig) async -> Bool {
    await orchestrator.advertisesOAuth(server: server)
  }

  /// Remove every stored credential for a server (OAuth blob + static
  /// token) — used when the user deletes the server row.
  static func deleteAllCredentials(for server: MCPServerConfig) {
    _ = KeychainStore.delete(account: server.oauthKeychainKey)
    _ = KeychainStore.delete(account: server.keychainTokenKey)
  }

  // MARK: - Browser session

  private static func runWebAuth(authURL: URL, expectedState: String) async throws -> String {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      let provider = MCPWebAuthPresentationContext()
      var sessionHolder: ASWebAuthenticationSession?

      let session = ASWebAuthenticationSession(
        url: authURL,
        callbackURLScheme: MCPOAuth.redirectScheme
      ) { callbackURL, error in
        // Hold strong refs to provider + session until the callback fires —
        // ASWebAuthenticationSession.presentationContextProvider is weak.
        _ = provider
        _ = sessionHolder

        if let error {
          let nsError = error as NSError
          if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
             nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            continuation.resume(throwing: MCPOAuthError.userCancelled)
          } else {
            continuation.resume(throwing: error)
          }
          return
        }
        guard let callbackURL,
              let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
              comps.queryItems?.first(where: { $0.name == "state" })?.value == expectedState
        else {
          continuation.resume(throwing: MCPOAuthError.invalidCallback)
          return
        }
        continuation.resume(returning: code)
      }

      session.presentationContextProvider = provider
      session.prefersEphemeralWebBrowserSession = false
      sessionHolder = session

      if !session.start() {
        continuation.resume(throwing: MCPOAuthError.sessionFailedToStart)
      }
    }
  }
}

/// Adapts the direct-Security `KeychainStore` to HexCore's storage protocol.
/// Never use `KeychainClient.liveValue` on iOS — see CLAUDE.md.
private struct IOSMCPTokenStorage: MCPTokenStorage {
  func read(_ key: String) async -> String? {
    await MainActor.run { KeychainStore.read(account: key).value }
  }

  func save(_ key: String, _ value: String) async {
    _ = await MainActor.run { KeychainStore.save(account: key, value: value) }
  }

  func delete(_ key: String) async {
    _ = await MainActor.run { KeychainStore.delete(account: key) }
  }
}

@MainActor
private final class MCPWebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
      ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first
      ?? ASPresentationAnchor()
  }
}
