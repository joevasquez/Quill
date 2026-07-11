//
//  MCPServersStorage.swift
//  HexCore
//
//  iOS persistence for the user's MCP server list. macOS stores servers in
//  `HexSettings.mcpServers` (the settings JSON file); iOS uses `@AppStorage`
//  / UserDefaults everywhere, so the server list follows the same pattern as
//  `CustomAIModesStorage` — a JSON blob under one `quill.*` key.
//

import Foundation

public enum MCPServersStorage {
  public static let userDefaultsKey = "quill.mcpServers"

  public static func encode(_ servers: [MCPServerConfig]) -> Data {
    (try? JSONEncoder().encode(servers)) ?? Data()
  }

  public static func decode(_ data: Data?) -> [MCPServerConfig] {
    guard let data, !data.isEmpty else { return [] }
    return (try? JSONDecoder().decode([MCPServerConfig].self, from: data)) ?? []
  }

  /// Convenience accessors over `UserDefaults.standard`.
  public static func load() -> [MCPServerConfig] {
    decode(UserDefaults.standard.data(forKey: userDefaultsKey))
  }

  public static func save(_ servers: [MCPServerConfig]) {
    UserDefaults.standard.set(encode(servers), forKey: userDefaultsKey)
  }
}
