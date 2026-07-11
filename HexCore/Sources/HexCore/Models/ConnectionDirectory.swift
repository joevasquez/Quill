//
//  ConnectionDirectory.swift
//  HexCore
//
//  Unifies native integrations and MCP servers under one user-facing
//  concept: a Connection. Two pieces:
//
//  1. `ConnectionBrand` + the curated directory — known MCP-backed
//     services (Notion, Linear, Dex, …) with their official remote MCP
//     URL and branding, so "Connect Notion" is one tap that creates an
//     `MCPServerConfig` + starts OAuth. MCP becomes an implementation
//     detail; users think in brands, not protocols.
//
//  2. `ConnectionTarget` — the shared presentation type every surface
//     renders from (confirmation step tiles, offline queue rows, the
//     macOS orb satellite ring), so a Dex lookup shows Dex branding
//     instead of a generic puzzle piece.
//
//  Directory URLs are prefilled defaults — vendors occasionally move
//  their MCP endpoints, so the add-flow must let the user edit the URL
//  when a connect fails.
//

import Foundation

// MARK: - Curated brand directory

public struct ConnectionBrand: Equatable, Sendable, Identifiable {
  /// Short name — doubles as the MCP server name the LLM refers to.
  public let name: String
  public let systemImage: String
  public let tintHex: String
  public let tagline: String
  /// Prefilled remote MCP endpoint. All featured brands authenticate
  /// via the standard MCP OAuth flow (browser sign-in on first 401).
  public let mcpURL: String

  public var id: String { name }

  public init(name: String, systemImage: String, tintHex: String, tagline: String, mcpURL: String) {
    self.name = name
    self.systemImage = systemImage
    self.tintHex = tintHex
    self.tagline = tagline
    self.mcpURL = mcpURL
  }
}

public enum ConnectionDirectory {
  /// Known MCP-backed services shown as one-tap connects alongside the
  /// native integrations. Order = display order.
  public static let featured: [ConnectionBrand] = [
    ConnectionBrand(
      name: "notion",
      systemImage: "doc.richtext",
      tintHex: "1F1F1F",
      tagline: "Create pages and search your workspace",
      mcpURL: "https://mcp.notion.com/mcp"
    ),
    ConnectionBrand(
      name: "linear",
      systemImage: "line.3.crossed.swirl.circle",
      tintHex: "5E6AD2",
      tagline: "File and update issues by voice",
      mcpURL: "https://mcp.linear.app/mcp"
    ),
    ConnectionBrand(
      name: "dex",
      systemImage: "person.text.rectangle",
      tintHex: "0EA5E9",
      tagline: "Look up contacts, log notes, set follow-ups",
      mcpURL: "https://mcp.getdex.com/mcp"
    ),
    ConnectionBrand(
      name: "github",
      systemImage: "chevron.left.forwardslash.chevron.right",
      tintHex: "24292F",
      tagline: "Issues, PRs, and repo lookups",
      mcpURL: "https://api.githubcopilot.com/mcp/"
    ),
    ConnectionBrand(
      name: "asana",
      systemImage: "checklist.checked",
      tintHex: "F06A6A",
      tagline: "Tasks and projects by voice",
      mcpURL: "https://mcp.asana.com/sse"
    ),
    ConnectionBrand(
      name: "sentry",
      systemImage: "exclamationmark.shield",
      tintHex: "593D78",
      tagline: "Query issues and releases",
      mcpURL: "https://mcp.sentry.dev/mcp"
    ),
    ConnectionBrand(
      name: "stripe",
      systemImage: "creditcard",
      tintHex: "635BFF",
      tagline: "Customers, invoices, payments",
      mcpURL: "https://mcp.stripe.com"
    ),
  ]

  /// Brand lookup for an MCP server the user has connected — matches
  /// the user-assigned server name (case-insensitive; substring in
  /// either direction so "dex crm" still gets Dex branding) or the
  /// server URL's host.
  public static func brand(forServerNamed name: String, url: String? = nil) -> ConnectionBrand? {
    let lowered = name.lowercased()
    if let byName = featured.first(where: {
      lowered == $0.name || lowered.contains($0.name) || $0.name.contains(lowered)
    }) {
      return byName
    }
    if let url, let host = URL(string: url)?.host()?.lowercased() {
      return featured.first { URL(string: $0.mcpURL)?.host()?.lowercased() == host }
    }
    return nil
  }
}

// MARK: - Shared presentation target

/// What a step/row acts through, resolved to one display vocabulary.
/// Every surface (confirmation tiles, queue rows, satellite ring)
/// renders from this instead of branching on actionType/integration.
public enum ConnectionTarget: Equatable, Sendable {
  case integration(Integration.Identifier)
  case mcpServer(String)
  case open

  public static func forIntent(_ intent: ActionIntent) -> ConnectionTarget {
    switch intent.actionType {
    case .mcpCall:
      return .mcpServer(intent.mcpServerName ?? "MCP")
    case .open:
      return .open
    default:
      return .integration(intent.targetIntegration)
    }
  }

  public var displayName: String {
    switch self {
    case .integration(let id):
      return Integration.all.first { $0.identifier == id }?.name ?? id.rawValue
    case .mcpServer(let name):
      return ConnectionDirectory.brand(forServerNamed: name)?.name.capitalized ?? name
    case .open:
      return "Open"
    }
  }

  public var systemImage: String {
    switch self {
    case .integration(let id):
      return Integration.all.first { $0.identifier == id }?.systemImage ?? "questionmark.circle"
    case .mcpServer(let name):
      return ConnectionDirectory.brand(forServerNamed: name)?.systemImage ?? "puzzlepiece.extension.fill"
    case .open:
      return "globe"
    }
  }

  /// Hex tint for the icon tile; nil → caller's neutral fallback
  /// (`QuillDesign.mcpTile` for unknown MCP servers, blue for open).
  public var tintHex: String? {
    switch self {
    case .integration(let id):
      return Integration.all.first { $0.identifier == id }?.tintHex
    case .mcpServer(let name):
      return ConnectionDirectory.brand(forServerNamed: name)?.tintHex
    case .open:
      return nil
    }
  }
}
