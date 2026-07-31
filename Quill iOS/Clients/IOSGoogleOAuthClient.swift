//
//  IOSGoogleOAuthClient.swift
//  Quill (iOS)
//
//  iOS port of `Hex/Clients/GoogleOAuthClient.swift`. Same OAuth 2.0
//  authorization-code-with-PKCE flow, driven by `ASWebAuthenticationSession`
//  on both platforms. Tokens are stored under the same Keychain accounts as
//  macOS via `KeychainStore` (the iOS-native helper, not the TCA-wrapped
//  `KeychainClient`).
//
//  Why not Desktop OAuth + custom URL scheme: Google rejects that
//  combination server-side as of 2022. Custom URI schemes are only legal
//  for "iOS"-type OAuth credentials, whose redirect URI is the reverse-DNS
//  of the client ID. ASWebAuthenticationSession captures the redirect
//  in-process, so no system URL routing or AppDelegate plumbing is needed.
//

import AuthenticationServices
import CryptoKit
import Foundation
import HexCore
import os
import UIKit

private let oauthLogger = HexLog.action

@MainActor
enum IOSGoogleOAuthClient {
  // Replace with your Google Cloud Console OAuth credential of type **iOS**.
  // Same client ID as the macOS target — one credential serves both apps
  // because Google enforces the bundle ID only at App Store submission, not
  // at runtime OAuth.
  static let clientId = "897102622833-ugs83fdspt94d9g373nh1v19gm4elive.apps.googleusercontent.com"

  /// Reverse-DNS of the client ID — Google's mandated redirect-URI scheme
  /// for iOS-type clients. Derived to avoid drift if the client ID rotates.
  static var reversedClientId: String {
    let suffix = ".apps.googleusercontent.com"
    let prefix = clientId.hasSuffix(suffix) ? String(clientId.dropLast(suffix.count)) : clientId
    return "com.googleusercontent.apps.\(prefix)"
  }

  /// Full redirect URI sent in the authorization request. Path is arbitrary;
  /// Google enforces only the scheme.
  static var redirectURI: String { "\(reversedClientId):/oauth2redirect" }

  /// Same scope list as macOS — `userinfo.email` powers the
  /// "Connected as <email>" UI in Settings + Onboarding.
  /// `datastore` enables Firestore cloud sync when the user opts in.
  static let defaultScopes: [String] = [
    "https://www.googleapis.com/auth/gmail.compose",
    // Read scope for the Google-hosted Gmail MCP server (suggestions read
    // the inbox through it; the native adapter stays compose-only).
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/calendar.events",
    "https://www.googleapis.com/auth/userinfo.email",
    CloudSyncConstants.firestoreScope,
    CloudSyncConstants.photoStorageScope,
  ]

  static let googleAccountEmailDefaultsKey = "quill.googleAccountEmail"

  private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
  private static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!

  // MARK: - Public API

  static func isAuthorized() -> Bool {
    let (token, _) = KeychainStore.read(account: KeychainKey.googleRefreshToken)
    return token?.isEmpty == false
  }

  /// Runs the system Safari sheet via ASWebAuthenticationSession, exchanges
  /// the authorization code for tokens with PKCE, persists tokens.
  static func authorize(scopes: [String] = defaultScopes) async throws -> GoogleTokensIOS {
    let codeVerifier = generateCodeVerifier()
    let challenge = codeChallenge(for: codeVerifier)

    let scopeString = scopes.joined(separator: " ")
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: scopeString),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
    ]

    guard let authURL = components.url else {
      throw IOSGoogleOAuthError.invalidURL
    }

    oauthLogger.info("Starting Google OAuth via ASWebAuthenticationSession (iOS)")

    let code = try await runWebAuth(authURL: authURL, callbackScheme: reversedClientId)
    let tokens = try await exchangeCode(code, codeVerifier: codeVerifier)

    KeychainStore.save(account: KeychainKey.googleAccessToken, value: tokens.accessToken)
    KeychainStore.save(account: KeychainKey.googleRefreshToken, value: tokens.refreshToken)
    let expiryString = ISO8601DateFormatter().string(from: tokens.expiresAt)
    KeychainStore.save(account: KeychainKey.googleTokenExpiry, value: expiryString)

    oauthLogger.info("Google OAuth tokens stored in Keychain (iOS)")
    return tokens
  }

  /// Returns a non-expired access token, refreshing it via the refresh token
  /// when within 5 minutes of expiry.
  static func refreshIfNeeded() async throws -> String {
    let (accessTokenOpt, _) = KeychainStore.read(account: KeychainKey.googleAccessToken)
    let (refreshTokenOpt, _) = KeychainStore.read(account: KeychainKey.googleRefreshToken)
    let (expiryStringOpt, _) = KeychainStore.read(account: KeychainKey.googleTokenExpiry)

    guard let accessToken = accessTokenOpt,
          let refreshToken = refreshTokenOpt,
          let expiryString = expiryStringOpt,
          let expiresAt = ISO8601DateFormatter().date(from: expiryString)
    else {
      throw IOSGoogleOAuthError.notAuthorized
    }

    if expiresAt.timeIntervalSinceNow > 300 {
      return accessToken
    }

    oauthLogger.info("Google access token expired or expiring soon; refreshing (iOS)")

    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15

    // No client_secret for iOS-type clients.
    let body = [
      "client_id=\(clientId)",
      "refresh_token=\(refreshToken)",
      "grant_type=refresh_token",
    ].joined(separator: "&")
    request.httpBody = body.data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      oauthLogger.error("Google token refresh failed (iOS): HTTP \(code, privacy: .public)")
      captureError(
        IOSGoogleOAuthError.refreshFailed(code),
        context: ErrorContext.feature("google_oauth")
          .tag("platform", "ios")
          .tag("op", "refresh")
          .tag("status", String(code))
      )
      throw IOSGoogleOAuthError.refreshFailed(code)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let newAccessToken = json["access_token"] as? String,
          let expiresIn = json["expires_in"] as? Int
    else {
      throw IOSGoogleOAuthError.invalidTokenResponse
    }

    let newExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
    KeychainStore.save(account: KeychainKey.googleAccessToken, value: newAccessToken)
    KeychainStore.save(account: KeychainKey.googleTokenExpiry, value: ISO8601DateFormatter().string(from: newExpiry))

    return newAccessToken
  }

  static func disconnect() {
    KeychainStore.delete(account: KeychainKey.googleAccessToken)
    KeychainStore.delete(account: KeychainKey.googleRefreshToken)
    KeychainStore.delete(account: KeychainKey.googleTokenExpiry)
    UserDefaults.standard.removeObject(forKey: googleAccountEmailDefaultsKey)
    oauthLogger.info("Google OAuth tokens cleared from Keychain (iOS)")
  }

  /// Best-effort fetch of the signed-in Google account's email. Caches the
  /// result in UserDefaults so subsequent UI renders don't network.
  static func fetchUserEmail() async -> String? {
    let (accessTokenOpt, _) = KeychainStore.read(account: KeychainKey.googleAccessToken)
    guard let accessToken = accessTokenOpt, !accessToken.isEmpty else { return nil }

    var request = URLRequest(url: userInfoEndpoint)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        oauthLogger.error("Google userinfo failed (iOS): HTTP \(code, privacy: .public)")
        return nil
      }
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let email = json["email"] as? String,
            !email.isEmpty
      else { return nil }
      UserDefaults.standard.set(email, forKey: googleAccountEmailDefaultsKey)
      return email
    } catch {
      oauthLogger.error("Google userinfo request threw (iOS): \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  // MARK: - Token exchange

  private static func exchangeCode(_ code: String, codeVerifier: String) async throws -> GoogleTokensIOS {
    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15

    // PKCE token exchange: send code_verifier instead of client_secret.
    let body = [
      "code=\(code)",
      "client_id=\(clientId)",
      "code_verifier=\(codeVerifier)",
      "redirect_uri=\(redirectURI)",
      "grant_type=authorization_code",
    ].joined(separator: "&")
    request.httpBody = body.data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      oauthLogger.error("Google token exchange failed (iOS): HTTP \(statusCode, privacy: .public)")
      throw IOSGoogleOAuthError.tokenExchangeFailed(statusCode)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accessToken = json["access_token"] as? String,
          let refreshToken = json["refresh_token"] as? String,
          let expiresIn = json["expires_in"] as? Int
    else {
      throw IOSGoogleOAuthError.invalidTokenResponse
    }

    let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
    return GoogleTokensIOS(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
  }

  // MARK: - PKCE

  private static func generateCodeVerifier() -> String {
    // RFC 7636 §4.1 — 43-128 chars from the unreserved alphabet. 32 random
    // bytes → ~43 base64url chars after padding strip.
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).pkceBase64URLEncoded()
  }

  private static func codeChallenge(for verifier: String) -> String {
    let hash = SHA256.hash(data: Data(verifier.utf8))
    return Data(hash).pkceBase64URLEncoded()
  }

  // MARK: - ASWebAuthenticationSession

  private static func runWebAuth(authURL: URL, callbackScheme: String) async throws -> String {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      let provider = WebAuthPresentationContext()
      var sessionHolder: ASWebAuthenticationSession?

      let session = ASWebAuthenticationSession(
        url: authURL,
        callbackURLScheme: callbackScheme
      ) { callbackURL, error in
        // Hold strong refs to provider + session until the callback fires —
        // ASWebAuthenticationSession.presentationContextProvider is weak.
        _ = provider
        _ = sessionHolder

        if let error {
          let nsError = error as NSError
          if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
             nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            continuation.resume(throwing: IOSGoogleOAuthError.userCancelled)
          } else {
            continuation.resume(throwing: error)
          }
          return
        }
        guard let callbackURL,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
          continuation.resume(throwing: IOSGoogleOAuthError.invalidCallback)
          return
        }
        continuation.resume(returning: code)
      }

      session.presentationContextProvider = provider
      // false = reuse Safari's cookies, so a user already signed into Google
      // sees an account picker instead of a fresh login form.
      session.prefersEphemeralWebBrowserSession = false
      sessionHolder = session

      if !session.start() {
        continuation.resume(throwing: IOSGoogleOAuthError.sessionFailedToStart)
      }
    }
  }
}

// MARK: - Presentation context

@MainActor
private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
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

// MARK: - Base64URL helper

private extension Data {
  /// RFC 7636 §3 base64url encoding — strip padding, swap +/ for -_.
  func pkceBase64URLEncoded() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

// MARK: - Tokens / Errors

struct GoogleTokensIOS: Sendable {
  let accessToken: String
  let refreshToken: String
  let expiresAt: Date
}

enum IOSGoogleOAuthError: LocalizedError {
  case invalidURL
  case notAuthorized
  case invalidCallback
  case userCancelled
  case sessionFailedToStart
  case tokenExchangeFailed(Int)
  case refreshFailed(Int)
  case invalidTokenResponse

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      "Could not construct Google OAuth URL"
    case .notAuthorized:
      "Not signed in to Google — connect in Settings."
    case .invalidCallback:
      "Invalid OAuth callback from Google"
    case .userCancelled:
      "Sign-in was cancelled."
    case .sessionFailedToStart:
      "Could not open the Google sign-in sheet."
    case .tokenExchangeFailed(let code):
      "Google token exchange failed (HTTP \(code))"
    case .refreshFailed(let code):
      "Google token refresh failed (HTTP \(code)) — try reconnecting in Settings."
    case .invalidTokenResponse:
      "Unexpected response from Google OAuth"
    }
  }
}
