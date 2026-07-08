//
//  MCPOAuth.swift
//  HexCore
//
//  Pure, testable pieces of the MCP OAuth 2.0 authorization flow (the MCP
//  auth spec = RFC 6749 authorization-code + PKCE, with RFC 9728 protected-
//  resource discovery, RFC 8414 authorization-server metadata, and RFC 7591
//  dynamic client registration). The stateful orchestration (browser session,
//  keychain, URLSession) lives in the app target's `MCPOAuthClient`; this file
//  holds the models, metadata/URL derivation, header parsing, and PKCE so they
//  can be unit-tested without a network or a browser.
//

import CryptoKit
import Foundation
import Security

// MARK: - Models

/// Stored OAuth tokens for one MCP server (persisted as JSON in the keychain).
public struct MCPOAuthTokens: Codable, Equatable, Sendable {
  public var accessToken: String
  public var refreshToken: String?
  /// Absolute expiry, if the token endpoint returned `expires_in`.
  public var expiresAt: Date?
  /// The dynamically-registered client id (needed for refresh).
  public var clientId: String
  /// The token endpoint (needed for refresh).
  public var tokenEndpoint: String

  public init(
    accessToken: String,
    refreshToken: String?,
    expiresAt: Date?,
    clientId: String,
    tokenEndpoint: String
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.clientId = clientId
    self.tokenEndpoint = tokenEndpoint
  }

  /// Expired (or within a 60s clock-skew guard). No known expiry → assumed
  /// valid until the server 401s.
  public func isExpired(now: Date = Date()) -> Bool {
    guard let expiresAt else { return false }
    return now >= expiresAt.addingTimeInterval(-60)
  }
}

/// `/.well-known/oauth-protected-resource` (RFC 9728). Decoded with
/// `.convertFromSnakeCase`.
public struct MCPProtectedResourceMetadata: Codable, Equatable, Sendable {
  public var authorizationServers: [String]?
}

/// `/.well-known/oauth-authorization-server` (RFC 8414) or OpenID config.
public struct MCPAuthServerMetadata: Codable, Equatable, Sendable {
  public var authorizationEndpoint: String
  public var tokenEndpoint: String
  public var registrationEndpoint: String?
}

/// Dynamic client registration response (RFC 7591).
public struct MCPClientRegistration: Codable, Equatable, Sendable {
  public var clientId: String
}

/// Token endpoint response (RFC 6749 §5.1).
public struct MCPTokenResponse: Codable, Equatable, Sendable {
  public var accessToken: String
  public var refreshToken: String?
  public var expiresIn: Double?
}

// MARK: - Helpers

public enum MCPOAuth {
  /// Redirect scheme/URI for the ASWebAuthenticationSession callback. It's
  /// declared in each dynamic client registration, so no Info.plist URL type
  /// is required (ASWebAuthenticationSession intercepts the scheme itself).
  public static let redirectScheme = "com.joevasquez.quill.mcp"
  public static let redirectURI = "com.joevasquez.quill.mcp://oauth-callback"

  /// JSON decoder configured for the snake_cased OAuth/metadata payloads.
  public static func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
  }

  /// Extracts the `resource_metadata="…"` URL from a `WWW-Authenticate`
  /// header value (RFC 9728 §5.1), quoted or bare.
  public static func resourceMetadataURL(fromWWWAuthenticate header: String) -> URL? {
    guard let range = header.range(of: "resource_metadata=") else { return nil }
    var value = String(header[range.upperBound...])
    if value.hasPrefix("\"") {
      value.removeFirst()
      if let end = value.firstIndex(of: "\"") { value = String(value[..<end]) }
    } else if let end = value.firstIndex(where: { $0 == "," || $0 == " " }) {
      value = String(value[..<end])
    }
    return URL(string: value.trimmingCharacters(in: .whitespaces))
  }

  /// Fallback protected-resource metadata URL(s) when there's no
  /// `WWW-Authenticate` header: the well-known path at the server's origin.
  public static func resourceMetadataCandidates(for serverURL: URL) -> [URL] {
    wellKnown(at: serverURL, paths: ["/.well-known/oauth-protected-resource"])
  }

  /// Candidate authorization-server metadata URLs for an issuer.
  public static func authServerMetadataCandidates(for authServer: URL) -> [URL] {
    wellKnown(at: authServer, paths: [
      "/.well-known/oauth-authorization-server",
      "/.well-known/openid-configuration",
    ])
  }

  private static func wellKnown(at url: URL, paths: [String]) -> [URL] {
    guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = comps.scheme, let host = comps.host
    else { return [] }
    return paths.compactMap { path in
      var c = URLComponents()
      c.scheme = scheme
      c.host = host
      c.port = comps.port
      c.path = path
      return c.url
    }
  }

  /// Builds the authorization request URL (RFC 6749 §4.1.1 + PKCE).
  public static func authorizationURL(
    endpoint: URL,
    clientId: String,
    codeChallenge: String,
    state: String,
    scope: String? = nil,
    resource: String? = nil
  ) -> URL? {
    guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
    var items = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
    ]
    if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
    // RFC 8707 resource indicator — many MCP servers require it.
    if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
    comps.queryItems = (comps.queryItems ?? []) + items
    return comps.url
  }

  // MARK: PKCE (RFC 7636)

  public static func generateCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return base64URL(Data(bytes))
  }

  public static func codeChallenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
