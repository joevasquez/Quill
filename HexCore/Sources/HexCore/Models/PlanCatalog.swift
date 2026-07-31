//
//  PlanCatalog.swift
//  HexCore
//
//  The single source of truth for the Free vs Pro story, shared by the
//  iOS "Quill Pro" screen, the macOS Plan tab, and the onboarding
//  Google-connect step — so tier copy can't drift between surfaces.
//
//  No payments exist yet: activation is the test toggle. When StoreKit
//  lands, this catalog stays; only the purchase affordance changes.
//

import Foundation

/// One row of the Free vs Pro comparison table.
public struct PlanFeatureRow: Identifiable, Sendable {
  public let name: String
  public let systemImage: String
  /// What the free tier gets — nil renders as "not included".
  public let free: String?
  public let pro: String

  public var id: String { name }

  public init(name: String, systemImage: String, free: String?, pro: String) {
    self.name = name
    self.systemImage = systemImage
    self.free = free
    self.pro = pro
  }
}

/// One benefit of connecting Google — used by onboarding and the Pro
/// surfaces to explain what the sign-in unlocks.
public struct GoogleBenefit: Identifiable, Sendable {
  public let systemImage: String
  public let title: String
  public let detail: String

  public var id: String { title }

  public init(systemImage: String, title: String, detail: String) {
    self.systemImage = systemImage
    self.title = title
    self.detail = detail
  }
}

public enum PlanCatalog {
  /// The comparison table. The two Pro anchors lead: bundled AI (no API
  /// key) and proactive suggestions.
  public static let rows: [PlanFeatureRow] = [
    PlanFeatureRow(
      name: "Voice capture & notes",
      systemImage: "mic.fill",
      free: "Unlimited, on-device",
      pro: "Unlimited, on-device"
    ),
    PlanFeatureRow(
      name: "AI enhancement",
      systemImage: "wand.and.stars",
      free: "Your own API key",
      pro: "Included — Claude built in, no key"
    ),
    PlanFeatureRow(
      name: "Proactive suggestions",
      systemImage: "lightbulb.max",
      free: nil,
      pro: "Ready-to-run actions from your inbox, calendar & contacts"
    ),
    PlanFeatureRow(
      name: "Connections",
      systemImage: "app.connected.to.app.below.fill",
      free: "\(IntegrationLimits.freeTierMaxConnections) apps",
      pro: "Unlimited, incl. Gmail & Google Calendar"
    ),
    PlanFeatureRow(
      name: "Voice agent (routines, memory, MCP)",
      systemImage: "sparkles",
      free: "Included",
      pro: "Included"
    ),
    PlanFeatureRow(
      name: "Cloud sync across devices",
      systemImage: "icloud",
      free: "Included with Google",
      pro: "Included with Google"
    ),
  ]

  /// What connecting Google unlocks — sign-in is always optional; each
  /// benefit gates itself.
  public static let googleBenefits: [GoogleBenefit] = [
    GoogleBenefit(
      systemImage: "icloud",
      title: "Sync across devices",
      detail: "Notes captured on your phone appear on your Mac, and back."
    ),
    GoogleBenefit(
      systemImage: "envelope.fill",
      title: "Gmail & Calendar actions",
      detail: "\u{201C}Email Mike about the deck\u{201D} or \u{201C}add a meeting Friday\u{201D} — drafted for you."
    ),
    GoogleBenefit(
      systemImage: "lightbulb.max",
      title: "Proactive suggestions (Pro)",
      detail: "Quill reads your inbox and calendar and offers ready-to-run actions."
    ),
  ]
}
