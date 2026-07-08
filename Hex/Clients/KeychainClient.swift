//
//  KeychainClient.swift
//  Quill
//
//  Stores and retrieves API keys from the system Keychain (macOS + iOS).
//

import Dependencies
import DependenciesMacros
import Foundation
import Security

@DependencyClient
struct KeychainClient {
  var save: @Sendable (String, String) async throws -> Void
  var read: @Sendable (String) async -> String?
  var delete: @Sendable (String) async -> Void
}

extension KeychainClient: DependencyKey {
  static var liveValue: Self {
    let live = KeychainClientLive()
    return .init(
      save: { key, value in
        try live.save(key: key, value: value)
      },
      read: { key in
        live.read(key: key)
      },
      delete: { key in
        live.delete(key: key)
      }
    )
  }
}

extension DependencyValues {
  var keychain: KeychainClient {
    get { self[KeychainClient.self] }
    set { self[KeychainClient.self] = newValue }
  }
}

// MARK: - Keychain Keys

enum KeychainKey {
  static let openAIAPIKey = "com.joevasquez.Quill.openAIAPIKey"
  static let anthropicAPIKey = "com.joevasquez.Quill.anthropicAPIKey"
  static let todoistAPIToken = "com.joevasquez.Quill.todoistAPIToken"
  static let googleAccessToken = "com.joevasquez.Quill.googleAccessToken"
  static let googleRefreshToken = "com.joevasquez.Quill.googleRefreshToken"
  static let googleTokenExpiry = "com.joevasquez.Quill.googleTokenExpiry"
}

// MARK: - Live Implementation

/// Reads/writes prefer the modern **Data Protection keychain**
/// (`kSecUseDataProtectionKeychain: true`), which — unlike the legacy
/// file-based keychain — does NOT trigger the system password dialog on
/// every access in sandboxed debug builds. Existing secrets live in the
/// legacy keychain, so `read` transparently migrates them: it checks the
/// DP keychain first, falls back to legacy, and on a legacy hit re-saves
/// into the DP keychain so subsequent launches read silently. If the app
/// isn't entitled for the DP keychain (no `application-identifier`), every
/// path degrades cleanly to the legacy behavior — never a hard failure and
/// never lost data.
///
/// One-time cost: the first launch after upgrading still prompts once per
/// stored secret (the migration reads from legacy); after that, DP reads
/// are silent.
private struct KeychainClientLive {
  private let service = "com.joevasquez.Quill"

  /// Base lookup attributes (class + service + account). `kSecAttrAccessible`
  /// is *deliberately* NOT included here: on iOS, passing it to
  /// `SecItemCopyMatching` can cause the query to miss items that were saved
  /// with the same attribute. Keep accessible as a save-only attribute.
  ///
  /// Uses the standard `[String: Any] as CFDictionary` bridge — the Swift
  /// runtime toll-free-bridges and retains values for the dictionary's
  /// lifetime. (A past version used `CFDictionaryCreateMutable` with `nil`
  /// retain callbacks; that failed to retain `kSecValueData`, deallocating
  /// the `CFData` before `SecItemAdd` read it and crashing in `CFGetTypeID`.)
  private func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if dataProtection {
      query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
    }
    return query
  }

  func save(key: String, value: String) throws {
    guard !key.isEmpty else { return }
    guard let data = value.data(using: .utf8) else { return }

    let dpStatus = performSave(account: key, data: data, dataProtection: true)
    if dpStatus == errSecSuccess { return }

    // DP keychain unavailable (typically `errSecMissingEntitlement` when the
    // app lacks a keychain access group) — fall back to legacy so saving
    // never hard-fails. Report the primary failure if legacy also fails.
    let legacyStatus = performSave(account: key, data: data, dataProtection: false)
    guard legacyStatus == errSecSuccess else {
      throw KeychainError.saveFailed(dpStatus)
    }
  }

  func read(key: String) -> String? {
    guard !key.isEmpty else { return nil }

    // 1. Data Protection keychain — silent.
    if let value = performRead(account: key, dataProtection: true) {
      return value
    }
    // 2. Legacy keychain — one-time prompt in debug. On a hit, migrate into
    //    the DP keychain (best-effort) so future launches read silently.
    if let value = performRead(account: key, dataProtection: false) {
      if let data = value.data(using: .utf8) {
        _ = performSave(account: key, data: data, dataProtection: true)
      }
      return value
    }
    return nil
  }

  func delete(key: String) {
    guard !key.isEmpty else { return }
    // Remove from both keychains so a delete is authoritative.
    SecItemDelete(baseQuery(account: key, dataProtection: true) as CFDictionary)
    SecItemDelete(baseQuery(account: key, dataProtection: false) as CFDictionary)
  }

  // MARK: Primitives

  private func performSave(account: String, data: Data, dataProtection: Bool) -> OSStatus {
    // Delete any existing item in the same keychain first so Add doesn't
    // collide. (Within-keychain delete doesn't prompt.)
    SecItemDelete(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary)

    var query = baseQuery(account: account, dataProtection: dataProtection)
    query[kSecValueData as String] = data
    // "WhenUnlockedThisDeviceOnly" = readable only while unlocked, never
    // synced to iCloud or included in backups — appropriate for API keys.
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(query as CFDictionary, nil)
  }

  private func performRead(account: String, dataProtection: Bool) -> String? {
    var query = baseQuery(account: account, dataProtection: dataProtection)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let string = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return string
  }
}

private enum KeychainError: LocalizedError {
  case saveFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .saveFailed(let status):
      "Failed to save to Keychain (status: \(status))"
    }
  }
}
