import Foundation

/// One thing the agent knows about the user's world, distilled from their
/// dictations: a person, a project, a preference. Fully user-visible and
/// deletable — trust is the product.
public struct MemoryEntity: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    case person
    case project
    case preference
    case place
    case other
  }

  public var id: UUID
  public var kind: Kind
  public var name: String
  /// Alternate ways the user refers to this entity ("Mike" / "Mike Chen").
  public var aliases: [String]
  /// Short key-value facts, e.g. "email": "mike@acme.com",
  /// "todoistProject": "Kearney", "role": "client lead".
  public var details: [String: String]
  /// How many transcripts have mentioned this entity — recency + frequency
  /// drive what gets included in the planner context.
  public var occurrences: Int
  public var firstSeenAt: Date
  public var lastSeenAt: Date

  public init(
    id: UUID = UUID(),
    kind: Kind,
    name: String,
    aliases: [String] = [],
    details: [String: String] = [:],
    occurrences: Int = 1,
    firstSeenAt: Date = Date(),
    lastSeenAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.aliases = aliases
    self.details = details
    self.occurrences = occurrences
    self.firstSeenAt = firstSeenAt
    self.lastSeenAt = lastSeenAt
  }
}

/// What the memory-extraction LLM call returns for one entity, before it is
/// merged into the store.
public struct MemoryCandidate: Codable, Equatable, Sendable {
  public var kind: MemoryEntity.Kind
  public var name: String
  public var aliases: [String]?
  public var details: [String: String]?

  public init(kind: MemoryEntity.Kind, name: String, aliases: [String]? = nil, details: [String: String]? = nil) {
    self.kind = kind
    self.name = name
    self.aliases = aliases
    self.details = details
  }
}

/// Envelope for decoding the extraction response.
public struct MemoryExtractionResponse: Codable, Equatable, Sendable {
  public var entities: [MemoryCandidate]

  public init(entities: [MemoryCandidate]) {
    self.entities = entities
  }
}
