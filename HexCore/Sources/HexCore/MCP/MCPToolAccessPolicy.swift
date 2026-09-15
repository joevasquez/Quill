import Foundation

/// Stores only disabled exceptions, so existing connections and newly
/// discovered tools retain the current opt-out behavior by default.
public struct MCPToolAccessPolicy: Codable, Equatable, Sendable {
  public var disabledToolsByServer: [String: Set<String>]

  public init(disabledToolsByServer: [String: Set<String>] = [:]) {
    self.disabledToolsByServer = disabledToolsByServer
  }

  public func isEnabled(serverID: UUID, toolName: String) -> Bool {
    !disabledToolsByServer[serverID.uuidString, default: []].contains(toolName)
  }

  public mutating func setEnabled(_ enabled: Bool, serverID: UUID, toolName: String) {
    let key = serverID.uuidString
    if enabled {
      disabledToolsByServer[key]?.remove(toolName)
      if disabledToolsByServer[key]?.isEmpty == true { disabledToolsByServer.removeValue(forKey: key) }
    } else {
      disabledToolsByServer[key, default: []].insert(toolName)
    }
  }

  public mutating func setAllEnabled(_ enabled: Bool, serverID: UUID, toolNames: [String]) {
    let key = serverID.uuidString
    if enabled {
      disabledToolsByServer.removeValue(forKey: key)
    } else {
      disabledToolsByServer[key] = Set(toolNames)
    }
  }
}

public enum MCPToolAccessStore {
  public static let userDefaultsKey = "quill.mcpToolAccess"

  public static func load(defaults: UserDefaults = .standard) -> MCPToolAccessPolicy {
    guard let data = defaults.data(forKey: userDefaultsKey) else { return MCPToolAccessPolicy() }
    return (try? JSONDecoder().decode(MCPToolAccessPolicy.self, from: data)) ?? MCPToolAccessPolicy()
  }

  public static func save(_ policy: MCPToolAccessPolicy, defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(policy) else { return }
    defaults.set(data, forKey: userDefaultsKey)
  }

  public static func isEnabled(serverID: UUID, toolName: String) -> Bool {
    load().isEnabled(serverID: serverID, toolName: toolName)
  }

  public static func enabledTools(_ tools: [MCPTool], for serverID: UUID) -> [MCPTool] {
    let policy = load()
    return tools.filter { policy.isEnabled(serverID: serverID, toolName: $0.name) }
  }
}
