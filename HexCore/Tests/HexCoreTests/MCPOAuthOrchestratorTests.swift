import Foundation
import XCTest
@testable import HexCore

/// Tests the storage-facing behavior of the orchestrator (token
/// resolution, signed-in state, sign-out) with an in-memory store. The
/// network legs (discovery/registration/exchange) are exercised by
/// integration use; here we verify the token plumbing contract both app
/// targets rely on.
final class MCPOAuthOrchestratorTests: XCTestCase {
  private let server = MCPServerConfig(name: "dex", url: "https://mcp.example.com/mcp")

  private func makeOrchestrator(storage: InMemoryTokenStorage) -> MCPOAuthOrchestrator {
    MCPOAuthOrchestrator(storage: storage) { _, _ in
      XCTFail("browser leg should not run in these tests")
      return ""
    }
  }

  private func storedTokens(
    accessToken: String = "at",
    refreshToken: String? = nil,
    expiresAt: Date? = nil
  ) -> String {
    let tokens = MCPOAuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      clientId: "client",
      tokenEndpoint: "https://auth.example.com/token"
    )
    return String(data: try! JSONEncoder().encode(tokens), encoding: .utf8)!
  }

  func testResolveAuthTokenPrefersValidOAuthToken() async {
    let storage = InMemoryTokenStorage()
    await storage.save(server.oauthKeychainKey, storedTokens(
      accessToken: "oauth-token",
      expiresAt: Date().addingTimeInterval(3600)
    ))
    await storage.save(server.keychainTokenKey, "static-token")

    let token = await makeOrchestrator(storage: storage).resolveAuthToken(for: server)
    XCTAssertEqual(token, "oauth-token")
  }

  func testResolveAuthTokenFallsBackToStaticToken() async {
    let storage = InMemoryTokenStorage()
    await storage.save(server.keychainTokenKey, "static-token")

    let token = await makeOrchestrator(storage: storage).resolveAuthToken(for: server)
    XCTAssertEqual(token, "static-token")
  }

  func testResolveAuthTokenNilWhenNothingStored() async {
    let token = await makeOrchestrator(storage: InMemoryTokenStorage()).resolveAuthToken(for: server)
    XCTAssertNil(token)
  }

  func testExpiredTokenWithoutRefreshStillReturned() async {
    // Expired + no refresh token → the stale access token is returned so
    // the resulting 401 surfaces "sign in again" instead of silent no-auth.
    let storage = InMemoryTokenStorage()
    await storage.save(server.oauthKeychainKey, storedTokens(
      accessToken: "stale",
      refreshToken: nil,
      expiresAt: Date().addingTimeInterval(-60)
    ))

    let token = await makeOrchestrator(storage: storage).resolveAuthToken(for: server)
    XCTAssertEqual(token, "stale")
  }

  func testIsSignedInReflectsStoredBlob() async {
    let storage = InMemoryTokenStorage()
    let orchestrator = makeOrchestrator(storage: storage)

    var signedIn = await orchestrator.isSignedIn(server)
    XCTAssertFalse(signedIn)

    await storage.save(server.oauthKeychainKey, storedTokens())
    signedIn = await orchestrator.isSignedIn(server)
    XCTAssertTrue(signedIn)
  }

  func testSignOutDeletesOAuthBlobOnly() async {
    let storage = InMemoryTokenStorage()
    await storage.save(server.oauthKeychainKey, storedTokens())
    await storage.save(server.keychainTokenKey, "static-token")

    let orchestrator = makeOrchestrator(storage: storage)
    await orchestrator.signOut(server)

    let oauth = await storage.read(server.oauthKeychainKey)
    let stat = await storage.read(server.keychainTokenKey)
    XCTAssertNil(oauth)
    XCTAssertEqual(stat, "static-token")
  }

  func testCorruptStoredBlobIsIgnored() async {
    let storage = InMemoryTokenStorage()
    await storage.save(server.oauthKeychainKey, "not json")
    await storage.save(server.keychainTokenKey, "static-token")

    let token = await makeOrchestrator(storage: storage).resolveAuthToken(for: server)
    XCTAssertEqual(token, "static-token")
  }
}

private actor TokenBox {
  var values: [String: String] = [:]
  func get(_ key: String) -> String? { values[key] }
  func set(_ key: String, _ value: String?) { values[key] = value }
}

private struct InMemoryTokenStorage: MCPTokenStorage {
  private let box = TokenBox()

  func read(_ key: String) async -> String? { await box.get(key) }
  func save(_ key: String, _ value: String) async { await box.set(key, value) }
  func delete(_ key: String) async { await box.set(key, nil) }
}
