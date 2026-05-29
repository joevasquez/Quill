#if os(macOS)
import AppKit
#endif
import AuthenticationServices
import CryptoKit
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import os

private let oauthLogger = HexLog.action

struct GoogleTokens: Codable, Sendable {
  let accessToken: String
  let refreshToken: String
  let expiresAt: Date
}

@DependencyClient
struct GoogleOAuthClient {
  var authorize: @Sendable (_ scopes: [String]) async throws -> GoogleTokens
  var refreshIfNeeded: @Sendable () async throws -> String
  var isAuthorized: @Sendable () async -> Bool = { false }
  var disconnect: @Sendable () async -> Void
  /// Fetches the user's primary email via the userinfo endpoint and caches
  /// it in UserDefaults under `googleAccountEmailDefaultsKey`. Returns `nil`
  /// on failure (network, scope missing, etc.) so the UI can fall back to a
  /// generic "Connected" label.
  var fetchUserEmail: @Sendable () async -> String? = { nil }
}

extension GoogleOAuthClient: DependencyKey {
  // Replace with your Google Cloud Console OAuth credential of type **iOS**
  // (NOT "Desktop app"). Google enforces server-side that only iOS-type
  // clients may use custom URI scheme redirects — Desktop clients are
  // restricted to loopback (http://127.0.0.1) since 2022. iOS clients have
  // no client_secret; PKCE replaces it.
  //
  // The credential's bundle ID can be either Quill bundle ID
  // (com.joevasquez.Quill or com.joevasquez.Quill.iOS); Google uses that
  // field for App Store verification, not runtime OAuth checks, so a single
  // credential serves both targets.
  static let clientId = "897102622833-ugs83fdspt94d9g373nh1v19gm4elive.apps.googleusercontent.com"

  /// Reverse-DNS of the client ID — Google's mandated redirect-URI scheme
  /// for iOS-type clients. Derived to avoid drift if the client ID isx
  /// rotated.
  static var reversedClientId: String {
    let suffix = ".apps.googleusercontent.com"
    let prefix = clientId.hasSuffix(suffix) ? String(clientId.dropLast(suffix.count)) : clientId
    return "com.googleusercontent.apps.\(prefix)"
  }

  /// Full redirect URI sent in the authorization request. Path doesn't
  /// matter to Google — only the scheme is enforced — but we use a stable
  /// path to make logs/network traces self-documenting.
  static var redirectURI: String { "\(reversedClientId):/oauth2redirect" }

  /// Scopes requested for every Google sign-in. `userinfo.email` lets us
  /// display "Connected as <address>" in Settings; the others power Gmail
  /// drafts and Calendar event creation in Action mode. `datastore` enables
  /// Firestore cloud sync when the user opts in.
  static let defaultScopes: [String] = [
    "https://www.googleapis.com/auth/gmail.compose",
    "https://www.googleapis.com/auth/calendar.events",
    "https://www.googleapis.com/auth/userinfo.email",
    CloudSyncConstants.firestoreScope,
    CloudSyncConstants.photoStorageScope,
  ]

  /// UserDefaults key for the cached account email — shared across Settings
  /// section views and onboarding so they stay in sync without polling.
  static let googleAccountEmailDefaultsKey = "quill.googleAccountEmail"

  private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
  private static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!

  // MARK: - In-memory token cache

  /// Keeps Google OAuth tokens in memory so `refreshIfNeeded` doesn't
  /// hit the macOS Keychain on every call (which triggers the system
  /// password dialog). The cache is populated on first read and updated
  /// on authorize / refresh / disconnect.
  private final class TokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var _accessToken: String?
    private var _refreshToken: String?
    private var _expiresAt: Date?
    private var _loaded = false

    func load(keychain: KeychainClient) async {
      lock.lock()
      if _loaded { lock.unlock(); return }
      lock.unlock()

      let at = await keychain.read(KeychainKey.googleAccessToken)
      let rt = await keychain.read(KeychainKey.googleRefreshToken)
      let exp: Date? = {
        guard let s = UserDefaults.standard.string(forKey: "quill.googleTokenExpiry") else { return nil }
        return ISO8601DateFormatter().date(from: s)
      }()

      // Also try keychain for expiry if UserDefaults doesn't have it
      let expiry: Date?
      if let exp {
        expiry = exp
      } else {
        let ks = await keychain.read(KeychainKey.googleTokenExpiry)
        expiry = ks.flatMap { ISO8601DateFormatter().date(from: $0) }
      }

      lock.lock()
      _accessToken = at
      _refreshToken = rt
      _expiresAt = expiry
      _loaded = true
      lock.unlock()
    }

    var tokens: (accessToken: String, refreshToken: String, expiresAt: Date)? {
      lock.lock()
      defer { lock.unlock() }
      guard let at = _accessToken, !at.isEmpty,
            let rt = _refreshToken, !rt.isEmpty,
            let exp = _expiresAt
      else { return nil }
      return (at, rt, exp)
    }

    func update(accessToken: String, refreshToken: String, expiresAt: Date) {
      lock.lock()
      _accessToken = accessToken
      _refreshToken = refreshToken
      _expiresAt = expiresAt
      _loaded = true
      lock.unlock()
    }

    func updateAccess(token: String, expiresAt: Date) {
      lock.lock()
      _accessToken = token
      _expiresAt = expiresAt
      lock.unlock()
    }

    func clear() {
      lock.lock()
      _accessToken = nil
      _refreshToken = nil
      _expiresAt = nil
      _loaded = true
      lock.unlock()
    }
  }

  private static let tokenCache = TokenCache()

  static var liveValue: Self {
    let cache = tokenCache

    return .init(
      authorize: { scopes in
        @Dependency(\.keychain) var keychain

        // PKCE: hash a random verifier into a challenge, send the challenge
        // with the auth request, prove possession of the verifier on the
        // token exchange. Replaces the client_secret that Desktop OAuth
        // clients used to embed.
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = codeChallenge(for: codeVerifier)

        let scopeString = scopes.joined(separator: " ")
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
          URLQueryItem(name: "client_id", value: clientId),
          URLQueryItem(name: "redirect_uri", value: redirectURI),
          URLQueryItem(name: "response_type", value: "code"),
          URLQueryItem(name: "scope", value: scopeString),
          URLQueryItem(name: "code_challenge", value: codeChallenge),
          URLQueryItem(name: "code_challenge_method", value: "S256"),
          URLQueryItem(name: "access_type", value: "offline"),
          URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = components.url else {
          throw GoogleOAuthError.invalidURL
        }

        oauthLogger.info("Starting Google OAuth via ASWebAuthenticationSession")

        // Hops to the main actor; runs the system Safari sheet in-process,
        // captures the redirect callback without going through any
        // app-level URL routing.
        let code = try await runWebAuth(authURL: authURL, callbackScheme: reversedClientId)

        let tokens = try await exchangeCode(code, codeVerifier: codeVerifier)

        try? await keychain.save(KeychainKey.googleAccessToken, tokens.accessToken)
        try? await keychain.save(KeychainKey.googleRefreshToken, tokens.refreshToken)
        let expiryString = ISO8601DateFormatter().string(from: tokens.expiresAt)
        try? await keychain.save(KeychainKey.googleTokenExpiry, expiryString)

        // Update in-memory cache so subsequent reads skip the keychain.
        cache.update(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          expiresAt: tokens.expiresAt
        )

        oauthLogger.info("Google OAuth tokens stored in Keychain")
        return tokens
      },
      refreshIfNeeded: {
        @Dependency(\.keychain) var keychain

        // Populate the in-memory cache from keychain once per launch.
        await cache.load(keychain: keychain)

        guard let tokens = cache.tokens else {
          throw GoogleOAuthError.notAuthorized
        }

        if tokens.expiresAt.timeIntervalSinceNow > 300 {
          return tokens.accessToken
        }

        oauthLogger.info("Google access token expired or expiring soon; refreshing")

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // No client_secret for iOS-type clients. Google accepts public-client
        // refresh requests with just client_id + refresh_token.
        let body = [
          "client_id=\(clientId)",
          "refresh_token=\(tokens.refreshToken)",
          "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
          let code = (response as? HTTPURLResponse)?.statusCode ?? 0
          oauthLogger.error("Google token refresh failed: HTTP \(code, privacy: .public)")
          // Refresh failures are usually "token revoked" (401) or upstream
          // outages (5xx). Either way they're real errors worth surfacing.
          captureError(
            GoogleOAuthError.refreshFailed(code),
            context: ErrorContext.feature("google_oauth")
              .tag("op", "refresh")
              .tag("status", String(code))
          )
          throw GoogleOAuthError.refreshFailed(code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
          throw GoogleOAuthError.invalidTokenResponse
        }

        let newExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        try? await keychain.save(KeychainKey.googleAccessToken, newAccessToken)
        let newExpiryString = ISO8601DateFormatter().string(from: newExpiry)
        try? await keychain.save(KeychainKey.googleTokenExpiry, newExpiryString)

        // Update the in-memory cache with the fresh access token.
        cache.updateAccess(token: newAccessToken, expiresAt: newExpiry)

        oauthLogger.info("Google access token refreshed, expires in \(expiresIn, privacy: .public)s")
        return newAccessToken
      },
      isAuthorized: {
        // Use the cached email in UserDefaults as a fast, synchronous
        // proxy for "has a refresh token." The email is written on
        // successful sign-in and cleared on disconnect — same lifecycle
        // as the keychain tokens — so it avoids a keychain read (and
        // the macOS password prompt that can accompany it) on every
        // settings tab switch.
        let email = UserDefaults.standard.string(forKey: googleAccountEmailDefaultsKey)
        return email?.isEmpty == false
      },
      disconnect: {
        @Dependency(\.keychain) var keychain
        await keychain.delete(KeychainKey.googleAccessToken)
        await keychain.delete(KeychainKey.googleRefreshToken)
        await keychain.delete(KeychainKey.googleTokenExpiry)
        cache.clear()
        UserDefaults.standard.removeObject(forKey: googleAccountEmailDefaultsKey)
        oauthLogger.info("Google OAuth tokens cleared from Keychain")
      },
      fetchUserEmail: {
        // Use the in-memory cache if available; fall back to keychain.
        let accessToken: String?
        if let tokens = cache.tokens, !tokens.accessToken.isEmpty {
          accessToken = tokens.accessToken
        } else {
          @Dependency(\.keychain) var keychain
          accessToken = await keychain.read(KeychainKey.googleAccessToken)
        }
        guard let accessToken, !accessToken.isEmpty else { return nil }

        var request = URLRequest(url: userInfoEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
          let (data, response) = try await URLSession.shared.data(for: request)
          guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            oauthLogger.error("Google userinfo failed: HTTP \(code, privacy: .public)")
            return nil
          }
          guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let email = json["email"] as? String,
                !email.isEmpty
          else { return nil }
          UserDefaults.standard.set(email, forKey: googleAccountEmailDefaultsKey)
          return email
        } catch {
          oauthLogger.error("Google userinfo request threw: \(error.localizedDescription, privacy: .public)")
          return nil
        }
      }
    )
  }

  // MARK: - Token exchange

  private static func exchangeCode(_ code: String, codeVerifier: String) async throws -> GoogleTokens {
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
      oauthLogger.error("Google token exchange failed: HTTP \(statusCode, privacy: .public)")
      throw GoogleOAuthError.tokenExchangeFailed(statusCode)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accessToken = json["access_token"] as? String,
          let refreshToken = json["refresh_token"] as? String,
          let expiresIn = json["expires_in"] as? Int
    else {
      throw GoogleOAuthError.invalidTokenResponse
    }

    let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
    return GoogleTokens(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
  }

  // MARK: - PKCE

  private static func generateCodeVerifier() -> String {
    // RFC 7636 §4.1 — verifier is 43-128 chars from [A-Z][a-z][0-9]-._~.
    // 32 random bytes → ~43 base64url chars after padding strip.
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).pkceBase64URLEncoded()
  }

  private static func codeChallenge(for verifier: String) -> String {
    let hash = SHA256.hash(data: Data(verifier.utf8))
    return Data(hash).pkceBase64URLEncoded()
  }

  // MARK: - ASWebAuthenticationSession

  /// Runs the system-managed OAuth sheet on the main actor and resolves to
  /// the authorization code. Provider + session are kept alive via closure
  /// capture so they live for the duration of the awaited continuation.
  @MainActor
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
            continuation.resume(throwing: GoogleOAuthError.userCancelled)
          } else {
            continuation.resume(throwing: error)
          }
          return
        }
        guard let callbackURL,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
          continuation.resume(throwing: GoogleOAuthError.invalidCallback)
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
        continuation.resume(throwing: GoogleOAuthError.sessionFailedToStart)
      }
    }
  }
}

extension DependencyValues {
  var googleOAuth: GoogleOAuthClient {
    get { self[GoogleOAuthClient.self] }
    set { self[GoogleOAuthClient.self] = newValue }
  }
}

// MARK: - Presentation context

@MainActor
private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if os(macOS)
    return NSApplication.shared.keyWindow
      ?? NSApplication.shared.windows.first
      ?? NSWindow()
    #else
    // Compiled into macOS target only — defensive default for cross-target
    // builds that pull this file in.
    return ASPresentationAnchor()
    #endif
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

// MARK: - Errors

enum GoogleOAuthError: LocalizedError {
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
      "Not signed in to Google — connect in Settings → Integrations."
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
