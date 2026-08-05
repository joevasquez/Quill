//
//  ActDestination.swift
//  HexCore
//
//  A destination the agent can route an action to — a native integration
//  or a connected MCP server. Shared by the iOS mode rail's Act chips and
//  the macOS Home command bar so both platforms offer the same set, in the
//  same order, with the same brand visuals.
//
//  Lives in HexCore (rather than either app target) because the *targeting*
//  decision — which destinations are routable for this capture, and which
//  the user pinned outright — has to reach the planner prompt, and that
//  assembly is shared too. See `ActTargeting`.
//

import Foundation

/// A destination the agent can route to — a native integration or an MCP
/// server. Only things that are actually connected are ever offered;
/// "+ Add" goes to Connections rather than pretending a toggle can
/// authenticate.
public struct QuillActDestination: Identifiable, Equatable, Hashable, Sendable {
  public enum Kind: Equatable, Hashable, Sendable {
    case integration(Integration.Identifier)
    case mcp(String)
  }

  public var kind: Kind
  public var name: String
  public var systemImage: String
  public var hue: Double

  public init(kind: Kind, name: String, systemImage: String, hue: Double) {
    self.kind = kind
    self.name = name
    self.systemImage = systemImage
    self.hue = hue
  }

  public var id: String {
    switch kind {
    case .integration(let i): "integration:\(i.rawValue)"
    case .mcp(let name): "mcp:\(name)"
    }
  }

  public var isMCP: Bool {
    if case .mcp = kind { return true }
    return false
  }

  /// The native integration this destination is, if it is one. Used to
  /// hard-override a parsed intent's `targetIntegration` when the user
  /// pinned exactly one native destination.
  public var integrationIdentifier: Integration.Identifier? {
    if case .integration(let id) = kind { return id }
    return nil
  }

  /// The MCP server name this destination is, if it is one.
  public var mcpServerName: String? {
    if case .mcp(let name) = kind { return name }
    return nil
  }

  public var palette: OKLCH { QuillDesign.destination(hue: hue) }

  /// Everything the agent could actually route to right now: connected
  /// native integrations plus enabled MCP servers.
  ///
  /// Unlike the design prototype — where destinations were a hardcoded list
  /// with a bool toggle — connecting is a real act of authentication, so
  /// this only reflects what's already set up. "+ Add" leads to Connections.
  public static func connected(
    integrations connectedIDs: Set<Integration.Identifier>,
    servers: [MCPServerConfig]
  ) -> [QuillActDestination] {
    let integrations = Integration.all
      .filter { connectedIDs.contains($0.identifier) }
      .map {
        QuillActDestination(
          kind: .integration($0.identifier),
          name: $0.name,
          systemImage: $0.systemImage,
          hue: $0.satelliteHue
        )
      }

    let mcp = servers
      .filter(\.isEnabled)
      .map { server -> QuillActDestination in
        // A known server gets its brand; an unknown one a neutral tone.
        let brand = ConnectionDirectory.brand(forServerNamed: server.name, url: server.url)
        return QuillActDestination(
          kind: .mcp(server.name),
          name: brand?.name ?? server.name,
          systemImage: brand?.systemImage ?? "puzzlepiece.extension.fill",
          hue: brand.flatMap { OKLCH(hex: $0.tintHex)?.H } ?? Self.neutralMCPHue
        )
      }

    return integrations + mcp
  }

  /// `@AppStorage`-friendly overload (iOS persists both sets as JSON blobs
  /// in UserDefaults; macOS keeps MCP servers in `HexSettings`).
  public static func connected(
    integrationData: Data,
    mcpData: Data
  ) -> [QuillActDestination] {
    connected(
      integrations: IntegrationConnectionStore.decode(integrationData),
      servers: MCPServersStorage.decode(mcpData)
    )
  }

  /// Steel — for MCP servers with no brand of their own.
  private static let neutralMCPHue: Double = 250

  /// The destination a partial transcript points at, or nil if nothing has
  /// been said yet that names one.
  ///
  /// Mirrors the macOS orb's ring intuition: a server named outright beats
  /// an integration matched on a generic verb, since "linear" is a much
  /// stronger signal than "issue". This only previews the guess — the LLM
  /// parse still decides, and the user can override by tapping a chip.
  public static func intuit(
    from transcript: String,
    among destinations: [QuillActDestination]
  ) -> QuillActDestination? {
    let haystack = " \(transcript.lowercased()) "
    guard haystack.count > 2 else { return nil }

    // A destination named explicitly wins outright.
    if let named = destinations.first(where: {
      haystack.contains(" \($0.name.lowercased()) ")
    }) {
      return named
    }

    // Otherwise fall back to each integration's keywords, most hits first.
    var best: (destination: QuillActDestination, hits: Int)?
    for destination in destinations {
      guard case .integration(let id) = destination.kind,
            let integration = Integration.all.first(where: { $0.identifier == id })
      else { continue }

      let hits = integration.intuitKeywords.filter { haystack.contains($0) }.count
      if hits > 0, hits > (best?.hits ?? 0) {
        best = (destination, hits)
      }
    }
    return best?.destination
  }
}

// MARK: - Targeting

/// What the agent is allowed to route this capture to.
///
/// Two independent user signals, both of which have to reach the planner —
/// otherwise the chip toggles are decoration and the `@` mentions are a
/// suggestion the model is free to ignore:
///
/// - `routable`: connected destinations minus anything the user muted on the
///   chip row. A *narrowing* of the default set.
/// - `pinned`: destinations the user named outright with an `@` mention while
///   typing. An *assertion* — when non-empty, nothing else is offered.
///
/// `focus` resolves the two: pins win when present, otherwise the routable
/// set stands.
public struct ActTargeting: Equatable, Hashable, Sendable {
  public var routable: [QuillActDestination]
  public var pinned: [QuillActDestination]

  public init(routable: [QuillActDestination] = [], pinned: [QuillActDestination] = []) {
    self.routable = routable
    self.pinned = pinned
  }

  /// Builds targeting from a chip row's state.
  ///
  /// Muting nothing is deliberately NOT the same as allowing everything by
  /// name: with nothing muted there is no user decision to report, so
  /// `routable` stays empty and the planner sees no restriction section at
  /// all. Listing every connected app as "the allowed set" would be prompt
  /// noise at best, and at worst reads as a ban on destination-less actions
  /// like opening a URL.
  public init(
    all: [QuillActDestination],
    muted: Set<String>,
    pinned: [QuillActDestination] = []
  ) {
    let remaining = all.filter { !muted.contains($0.id) }
    self.routable = remaining.count == all.count ? [] : remaining
    self.pinned = pinned
  }

  public static let unrestricted = ActTargeting()

  /// The destinations the planner may actually choose among. Empty means
  /// "no restriction" — the caller had nothing connected, or chose not to
  /// pass a set at all.
  public var focus: [QuillActDestination] {
    pinned.isEmpty ? routable : pinned
  }

  public var isUnrestricted: Bool { focus.isEmpty }

  /// The MCP servers whose tools should be described to the planner.
  /// Anything outside the focus set is withheld — the model can't invoke a
  /// tool it was never shown, which is a stronger guarantee than asking it
  /// nicely in the prompt.
  public func allowedServers(from all: [MCPServerConfig]) -> [MCPServerConfig] {
    guard !isUnrestricted else { return all }
    let allowedNames = Set(focus.compactMap(\.mcpServerName).map { $0.lowercased() })
    return all.filter { allowedNames.contains($0.name.lowercased()) }
  }

  /// The one native integration to force onto every parsed intent, if the
  /// user's pin is unambiguous. Multiple pins stay advisory: "@Gmail email
  /// Mike and log it in @Dex" is a legitimate two-step command and forcing
  /// one target would break the chain.
  public var forcedIntegration: Integration.Identifier? {
    guard pinned.count == 1 else { return nil }
    return pinned.first?.integrationIdentifier
  }

  /// Planner directive describing the user's explicit targeting, or nil when
  /// there's nothing to say. Appended to the action system prompt alongside
  /// the memory and MCP sections.
  public var promptContext: String? {
    guard !isUnrestricted else { return nil }
    let names = focus.map { $0.isMCP ? "\($0.name) (MCP server)" : $0.name }
    let list = names.map { "- \($0)" }.joined(separator: "\n")

    // Destination-less action types have nothing to restrict, and a blanket
    // "only these" would otherwise read as a ban on them.
    let exemption = "Actions with no destination — opening a URL or launching " +
      "an app — are exempt from this restriction."

    if !pinned.isEmpty {
      return """
      Destinations the user pinned for this request (they typed them explicitly):
      \(list)

      Every action you emit MUST target one of these. Do not route to any other \
      integration or MCP server, even if the wording suggests one — the user's \
      pin is deliberate and overrides your own inference. If a pinned \
      destination cannot do what was asked, still target it and describe the \
      limitation in the action's title rather than silently substituting another. \
      \(exemption)
      """
    }

    return """
    Destinations available for this request (the user has turned the others off):
    \(list)

    Only route to destinations in this list. If none of them fits the request, \
    pick the closest one and say so in the action's title. \(exemption)
    """
  }
}
