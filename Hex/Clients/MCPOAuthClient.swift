//
//  MCPOAuthClient.swift
//  Quill (macOS)
//
//  macOS shell around HexCore's `MCPOAuthOrchestrator`: supplies the
//  keychain-backed token storage (TCA `KeychainClient` → Data Protection
//  keychain) and the `ASWebAuthenticationSession` browser leg anchored to
//  the app's key window. All flow logic (discovery, RFC 7591 registration,
//  PKCE, token exchange/refresh) lives in HexCore.
//

import AuthenticationServices
import Dependencies
import Foundation
import HexCore

enum MCPOAuthClient {
  private static var orchestrator: MCPOAuthOrchestrator {
    MCPOAuthOrchestrator(
      storage: KeychainTokenStorage(),
      authorize: { authURL, expectedState in
        try await runWebAuth(authURL: authURL, expectedState: expectedState)
      }
    )
  }

  /// The bearer token to authenticate an MCP request: a valid OAuth access
  /// token (refreshed if needed) when the server is OAuth-connected, else the
  /// static token, else nil.
  static func resolveAuthToken(for server: MCPServerConfig) async -> String? {
    await orchestrator.resolveAuthToken(for: server)
  }

  /// Whether the server has stored OAuth tokens (drives the UI's signed-in
  /// state).
  static func isSignedIn(_ server: MCPServerConfig) async -> Bool {
    await orchestrator.isSignedIn(server)
  }

  static func signOut(_ server: MCPServerConfig) async {
    await orchestrator.signOut(server)
  }

  @MainActor
  static func signIn(server: MCPServerConfig) async throws {
    try await orchestrator.signIn(server: server)
  }

  /// Whether the server publishes OAuth metadata (i.e. supports browser
  /// sign-in) even if it doesn't 401 anonymous catalog requests.
  static func advertisesOAuth(_ server: MCPServerConfig) async -> Bool {
    await orchestrator.advertisesOAuth(server: server)
  }

  // MARK: - Browser session

  @MainActor
  private static func runWebAuth(authURL: URL, expectedState: String) async throws -> String {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      let provider = MCPWebAuthContext()
      var sessionHolder: ASWebAuthenticationSession?
      let session = ASWebAuthenticationSession(
        url: authURL,
        callbackURLScheme: MCPOAuth.redirectScheme
      ) { callbackURL, error in
        _ = provider
        _ = sessionHolder
        if let error {
          let ns = error as NSError
          if ns.domain == ASWebAuthenticationSessionError.errorDomain,
             ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
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

/// Adapts the TCA keychain dependency to HexCore's storage protocol.
private struct KeychainTokenStorage: MCPTokenStorage {
  func read(_ key: String) async -> String? {
    @Dependency(\.keychain) var keychain
    return await keychain.read(key)
  }

  func save(_ key: String, _ value: String) async {
    @Dependency(\.keychain) var keychain
    try? await keychain.save(key, value)
  }

  func delete(_ key: String) async {
    @Dependency(\.keychain) var keychain
    await keychain.delete(key)
  }
}

@MainActor
private final class MCPWebAuthContext: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
  }
}
