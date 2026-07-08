import XCTest
@testable import HexCore

final class MCPOAuthTests: XCTestCase {
  func testResourceMetadataURLFromQuotedHeader() {
    let header = #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", error="invalid_token""#
    let url = MCPOAuth.resourceMetadataURL(fromWWWAuthenticate: header)
    XCTAssertEqual(url?.absoluteString, "https://mcp.example.com/.well-known/oauth-protected-resource")
  }

  func testResourceMetadataURLFromBareHeader() {
    let header = "Bearer resource_metadata=https://mcp.example.com/meta realm=x"
    XCTAssertEqual(
      MCPOAuth.resourceMetadataURL(fromWWWAuthenticate: header)?.absoluteString,
      "https://mcp.example.com/meta"
    )
  }

  func testResourceMetadataURLMissing() {
    XCTAssertNil(MCPOAuth.resourceMetadataURL(fromWWWAuthenticate: "Bearer realm=\"x\""))
  }

  func testWellKnownCandidatesUseOriginNotPath() {
    let server = URL(string: "https://mcp.example.com/some/mcp/path")!
    let resource = MCPOAuth.resourceMetadataCandidates(for: server)
    XCTAssertEqual(resource.map(\.absoluteString),
                   ["https://mcp.example.com/.well-known/oauth-protected-resource"])
    let auth = MCPOAuth.authServerMetadataCandidates(for: URL(string: "https://auth.example.com")!)
    XCTAssertEqual(auth.map(\.absoluteString), [
      "https://auth.example.com/.well-known/oauth-authorization-server",
      "https://auth.example.com/.well-known/openid-configuration",
    ])
  }

  func testAuthorizationURLIncludesPKCEAndResource() {
    let url = MCPOAuth.authorizationURL(
      endpoint: URL(string: "https://auth.example.com/authorize")!,
      clientId: "client123",
      codeChallenge: "CHALLENGE",
      state: "STATE",
      resource: "https://mcp.example.com/mcp"
    )
    let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
    let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value) })
    XCTAssertEqual(items["response_type"], "code")
    XCTAssertEqual(items["client_id"], "client123")
    XCTAssertEqual(items["code_challenge"], "CHALLENGE")
    XCTAssertEqual(items["code_challenge_method"], "S256")
    XCTAssertEqual(items["state"], "STATE")
    XCTAssertEqual(items["redirect_uri"], MCPOAuth.redirectURI)
    XCTAssertEqual(items["resource"], "https://mcp.example.com/mcp")
  }

  func testPKCEChallengeIsDeterministicBase64URL() {
    // RFC 7636 test vector.
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    XCTAssertEqual(MCPOAuth.codeChallenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  func testGeneratedVerifierIsURLSafeAndLongEnough() {
    let v = MCPOAuth.generateCodeVerifier()
    XCTAssertGreaterThanOrEqual(v.count, 43)
    XCTAssertFalse(v.contains("+"))
    XCTAssertFalse(v.contains("/"))
    XCTAssertFalse(v.contains("="))
  }

  func testTokensExpiry() {
    let expired = MCPOAuthTokens(accessToken: "a", refreshToken: "r",
                                 expiresAt: Date().addingTimeInterval(30), clientId: "c", tokenEndpoint: "t")
    XCTAssertTrue(expired.isExpired())  // within 60s skew
    let valid = MCPOAuthTokens(accessToken: "a", refreshToken: "r",
                               expiresAt: Date().addingTimeInterval(600), clientId: "c", tokenEndpoint: "t")
    XCTAssertFalse(valid.isExpired())
    let noExpiry = MCPOAuthTokens(accessToken: "a", refreshToken: nil,
                                  expiresAt: nil, clientId: "c", tokenEndpoint: "t")
    XCTAssertFalse(noExpiry.isExpired())
  }

  func testMetadataDecodingSnakeCase() throws {
    let json = """
    {"authorization_endpoint":"https://a/authorize","token_endpoint":"https://a/token","registration_endpoint":"https://a/register"}
    """
    let meta = try MCPOAuth.decoder().decode(MCPAuthServerMetadata.self, from: Data(json.utf8))
    XCTAssertEqual(meta.authorizationEndpoint, "https://a/authorize")
    XCTAssertEqual(meta.tokenEndpoint, "https://a/token")
    XCTAssertEqual(meta.registrationEndpoint, "https://a/register")

    let reg = try MCPOAuth.decoder().decode(MCPClientRegistration.self, from: Data(#"{"client_id":"abc"}"#.utf8))
    XCTAssertEqual(reg.clientId, "abc")
  }
}
