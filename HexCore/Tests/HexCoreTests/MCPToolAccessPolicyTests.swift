import Foundation
import Testing
@testable import HexCore

@Suite("MCP tool access")
struct MCPToolAccessPolicyTests {
  @Test("tools default to enabled")
  func defaultsEnabled() {
    let policy = MCPToolAccessPolicy()
    #expect(policy.isEnabled(serverID: UUID(), toolName: "search_threads"))
  }

  @Test("a disabled tool stays disabled without affecting its neighbors")
  func granularDisable() {
    let serverID = UUID()
    var policy = MCPToolAccessPolicy()
    policy.setEnabled(false, serverID: serverID, toolName: "send_email")

    #expect(!policy.isEnabled(serverID: serverID, toolName: "send_email"))
    #expect(policy.isEnabled(serverID: serverID, toolName: "search_email"))
  }

  @Test("re-enabling removes the stored exception")
  func reenable() {
    let serverID = UUID()
    var policy = MCPToolAccessPolicy()
    policy.setEnabled(false, serverID: serverID, toolName: "delete_task")
    policy.setEnabled(true, serverID: serverID, toolName: "delete_task")

    #expect(policy.isEnabled(serverID: serverID, toolName: "delete_task"))
    #expect(policy.disabledToolsByServer.isEmpty)
  }
}
