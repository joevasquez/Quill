//
//  MCPOAuthClient.swift
//  Quill (macOS)
//
//  Runs the MCP OAuth 2.0 authorization-code + PKCE flow so servers that
//  require a browser sign-in (Dex, Notion, Linear, …) work as Hermes tools —
//  not just static-token servers. Orchestrates the pure pieces in HexCore's
//  `MCPOAuth`: discover the protected-resource + authorization-server
//  metadata, dynamically register a client (RFC 7591), run the browser sign-in
//  via `ASWebAuthenticationSession`, exchange the code for tokens, and persist
//  them (JSON) in the keychain under `MCPServerConfig.oauthKeychainKey`.
//
//  `resolveAuthToken` is the single entry point callers use to authenticate an
//  MCP request: a valid OAuth access token (refreshed if expired) when the
//  server is OAuth-connected, otherwise the static bearer token.
//

import AuthenticationServices
import Dependencies
import Foundation
import HexCore
import os

private let mcpOAuthLogger = HexLog.app

enum MCPOAuthError: LocalizedError {
  case noAuthorizationServer
  case noRegistrationEndpoint
  case registrationFailed(Int, String)
  case tokenExchangeFailed(Int, String)
  case userCancelled
  case invalidCallback
  case sessionFailedToStart

  var errorDescription: String? {
    switch self {
    case .noAuthorizationServer:
      "Couldn't find this server's authorization server (OAuth discovery failed)."
    case .noRegistrationEndpoint:
      "This server doesn't support dynamic client registration, which Quill needs to sign in."
    case .registrationFailed(let code, _):
      "Client registration failed (HTTP \(code))."
    case .tokenExchangeFailed(let code, _):
      "Token exchange failed (HTTP \(code))."
    case .userCancelled:
      "Sign-in was cancelled."
    case .invalidCallback:
      "The sign-in didn't return a valid authorization code."
    case .sessionFailedToStart:
      "Couldn't open the sign-in window."
    }
  }
}

enum MCPOAuthClient {
  // MARK: - Token resolution (used on every MCP request)

  /// The bearer token to authenticate an MCP request: a valid OAuth access
  /// token (refreshed if needed) when the server is OAuth-connected, else the
  /// static token, else nil.
  static func resolveAuthToken(for server: MCPServerConfig) async -> String? {
    if let tokens = await loadTokens(server) {
      if !tokens.isExpired() { return tokens.accessToken }
      if let refreshed = try? await refresh(server: server, tokens: tokens) {
        return refreshed.accessToken
      }
      // Expired with no working refresh — return it anyway so the resulting
      // 401 surfaces "sign in again" rather than a silent no-auth failure.
      return tokens.accessToken
    }
    @Dependency(\.keychain) var keychain
    return await keychain.read(server.keychainTokenKey)
  }

  /// Whether the server has stored OAuth tokens (drives the UI's signed-in
  /// state).
  static func isSignedIn(_ server: MCPServerConfig) async -> Bool {
    await loadTokens(server) != nil
  }

  static func signOut(_ server: MCPServerConfig) async {
    @Dependency(\.keychain) var keychain
    await keychain.delete(server.oauthKeychainKey)
  }

  // MARK: - Sign in (full flow)

  @MainActor
  static func signIn(server: MCPServerConfig) async throws {
    guard let serverURL = URL(string: server.url) else { throw MCPError.invalidURL }

    // 1. Discover the authorization server via the protected-resource metadata
    //    (WWW-Authenticate header, else the well-known path).
    let authServer = try await discoverAuthorizationServer(serverURL: serverURL)
    let meta = try await fetchAuthServerMetadata(issuer: authServer)

    // 2. Dynamically register a public client (RFC 7591).
    guard let registrationEndpoint = meta.registrationEndpoint,
          let regURL = URL(string: registrationEndpoint) else {
      throw MCPOAuthError.noRegistrationEndpoint
    }
    let clientId = try await registerClient(registrationEndpoint: regURL, serverName: server.name)

    // 3. Authorization-code + PKCE, in the browser.
    let verifier = MCPOAuth.generateCodeVerifier()
    let challenge = MCPOAuth.codeChallenge(for: verifier)
    let state = MCPOAuth.generateCodeVerifier()  // reuse the random generator
    guard let authEndpoint = URL(string: meta.authorizationEndpoint),
          let authURL = MCPOAuth.authorizationURL(
            endpoint: authEndpoint,
            clientId: clientId,
            codeChallenge: challenge,
            state: state,
            resource: server.url
          ) else {
      throw MCPOAuthError.invalidCallback
    }

    mcpOAuthLogger.info("Starting MCP OAuth for \(server.name, privacy: .private)")
    let code = try await runWebAuth(authURL: authURL, expectedState: state)

    // 4. Exchange the code for tokens.
    let tokens = try await exchangeCode(
      code, verifier: verifier, clientId: clientId,
      tokenEndpoint: meta.tokenEndpoint, resource: server.url
    )
    await storeTokens(tokens, for: server)
    mcpOAuthLogger.info("MCP OAuth complete for \(server.name, privacy: .private)")
  }

  // MARK: - Discovery

  private static func discoverAuthorizationServer(serverURL: URL) async throws -> URL {
    // Probe the server; a 401 should carry a WWW-Authenticate pointing at the
    // protected-resource metadata.
    var resourceMetaURL: URL?
    if let (_, response) = try? await probe(serverURL),
       let http = response as? HTTPURLResponse,
       let header = http.value(forHTTPHeaderField: "WWW-Authenticate"),
       let url = MCPOAuth.resourceMetadataURL(fromWWWAuthenticate: header) {
      resourceMetaURL = url
    }
    // Fallback: the well-known path at the server origin.
    let candidates = resourceMetaURL.map { [$0] } ?? MCPOAuth.resourceMetadataCandidates(for: serverURL)
    for url in candidates {
      if let (data, response) = try? await URLSession.shared.data(from: url),
         (response as? HTTPURLResponse)?.statusCode == 200,
         let meta = try? MCPOAuth.decoder().decode(MCPProtectedResourceMetadata.self, from: data),
         let issuer = meta.authorizationServers?.first,
         let issuerURL = URL(string: issuer) {
        return issuerURL
      }
    }
    // Last resort: some servers act as their own issuer at the origin.
    if let comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
       let scheme = comps.scheme, let host = comps.host {
      var origin = URLComponents()
      origin.scheme = scheme; origin.host = host; origin.port = comps.port
      if let url = origin.url { return url }
    }
    throw MCPOAuthError.noAuthorizationServer
  }

  private static func fetchAuthServerMetadata(issuer: URL) async throws -> MCPAuthServerMetadata {
    for url in MCPOAuth.authServerMetadataCandidates(for: issuer) {
      if let (data, response) = try? await URLSession.shared.data(from: url),
         (response as? HTTPURLResponse)?.statusCode == 200,
         let meta = try? MCPOAuth.decoder().decode(MCPAuthServerMetadata.self, from: data) {
        return meta
      }
    }
    throw MCPOAuthError.noAuthorizationServer
  }

  private static func probe(_ serverURL: URL) async throws -> (Data, URLResponse) {
    var request = URLRequest(url: serverURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 15
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Quill", "version": "1.0"]],
    ])
    return try await URLSession.shared.data(for: request)
  }

  // MARK: - Dynamic client registration

  private static func registerClient(registrationEndpoint: URL, serverName: String) async throws -> String {
    var request = URLRequest(url: registrationEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15
    let body: [String: Any] = [
      "client_name": "Quill",
      "redirect_uris": [MCPOAuth.redirectURI],
      "grant_types": ["authorization_code", "refresh_token"],
      "response_types": ["code"],
      "token_endpoint_auth_method": "none",  // public client (PKCE)
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200...201).contains(code) else {
      throw MCPOAuthError.registrationFailed(code, String(data: data, encoding: .utf8) ?? "")
    }
    return try MCPOAuth.decoder().decode(MCPClientRegistration.self, from: data).clientId
  }

  // MARK: - Token exchange + refresh

  private static func exchangeCode(
    _ code: String, verifier: String, clientId: String, tokenEndpoint: String, resource: String
  ) async throws -> MCPOAuthTokens {
    let form = [
      "grant_type=authorization_code",
      "code=\(code)",
      "redirect_uri=\(MCPOAuth.redirectURI)",
      "client_id=\(clientId)",
      "code_verifier=\(verifier)",
      "resource=\(resource.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? resource)",
    ].joined(separator: "&")
    let resp = try await postForm(form, to: tokenEndpoint)
    return MCPOAuthTokens(
      accessToken: resp.accessToken,
      refreshToken: resp.refreshToken,
      expiresAt: resp.expiresIn.map { Date().addingTimeInterval($0) },
      clientId: clientId,
      tokenEndpoint: tokenEndpoint
    )
  }

  private static func refresh(server: MCPServerConfig, tokens: MCPOAuthTokens) async throws -> MCPOAuthTokens {
    guard let refreshToken = tokens.refreshToken else { throw MCPOAuthError.tokenExchangeFailed(0, "no refresh token") }
    let form = [
      "grant_type=refresh_token",
      "refresh_token=\(refreshToken)",
      "client_id=\(tokens.clientId)",
    ].joined(separator: "&")
    let resp = try await postForm(form, to: tokens.tokenEndpoint)
    let updated = MCPOAuthTokens(
      accessToken: resp.accessToken,
      refreshToken: resp.refreshToken ?? tokens.refreshToken,  // reuse if the server didn't rotate it
      expiresAt: resp.expiresIn.map { Date().addingTimeInterval($0) },
      clientId: tokens.clientId,
      tokenEndpoint: tokens.tokenEndpoint
    )
    await storeTokens(updated, for: server)
    return updated
  }

  private static func postForm(_ form: String, to endpoint: String) async throws -> MCPTokenResponse {
    guard let url = URL(string: endpoint) else { throw MCPOAuthError.tokenExchangeFailed(0, "bad token endpoint") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 15
    request.httpBody = form.data(using: .utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      throw MCPOAuthError.tokenExchangeFailed(code, String(data: data, encoding: .utf8) ?? "")
    }
    return try MCPOAuth.decoder().decode(MCPTokenResponse.self, from: data)
  }

  // MARK: - Keychain

  private static func loadTokens(_ server: MCPServerConfig) async -> MCPOAuthTokens? {
    @Dependency(\.keychain) var keychain
    guard let json = await keychain.read(server.oauthKeychainKey),
          let data = json.data(using: .utf8),
          let tokens = try? JSONDecoder().decode(MCPOAuthTokens.self, from: data)
    else { return nil }
    return tokens
  }

  private static func storeTokens(_ tokens: MCPOAuthTokens, for server: MCPServerConfig) async {
    @Dependency(\.keychain) var keychain
    guard let data = try? JSONEncoder().encode(tokens),
          let json = String(data: data, encoding: .utf8) else { return }
    try? await keychain.save(server.oauthKeychainKey, json)
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

@MainActor
private final class MCPWebAuthContext: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
  }
}

private extension CharacterSet {
  /// urlQueryAllowed minus the sub-delims that break form values.
  static let urlQueryValueAllowed: CharacterSet = {
    var set = CharacterSet.urlQueryAllowed
    set.remove(charactersIn: "+&=")
    return set
  }()
}
