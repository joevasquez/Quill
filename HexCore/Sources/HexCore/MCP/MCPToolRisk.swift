public enum MCPToolRisk {
  /// A display-only heuristic. Enforcement is always per exact tool name;
  /// this classification simply helps people scan the permission list.
  public static func isWriteLike(_ toolName: String) -> Bool {
    let name = toolName.lowercased()
    return [
      "add", "archive", "cancel", "create", "delete", "draft", "edit",
      "invite", "move", "post", "remove", "rename", "reply", "send",
      "set", "share", "submit", "update", "write",
    ].contains { name.contains($0) }
  }
}
