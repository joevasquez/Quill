import Foundation

/// Renders the agent's memory into a compact context block appended to the
/// action-parsing system prompt, so "email Mike" resolves to the right Mike
/// without clarifying questions.
public enum MemoryContextBuilder {
  /// Most-relevant-first: recency-weighted with an occurrence boost.
  /// Returns nil when there is nothing to say (prompt stays unchanged).
  public static func context(from entities: [MemoryEntity], limit: Int = 12, now: Date = Date()) -> String? {
    guard !entities.isEmpty else { return nil }

    let ranked = entities.sorted { score($0, now: now) > score($1, now: now) }.prefix(limit)

    var lines: [String] = [
      "Known context about this user, learned from their previous dictations. Use it to resolve names, projects, lists, and defaults — never invent details not present here or in the transcript:"
    ]
    for entity in ranked {
      var line = "- \(entity.name) (\(entity.kind.rawValue)"
      if !entity.aliases.isEmpty {
        line += ", aka \(entity.aliases.joined(separator: ", "))"
      }
      line += ")"
      if !entity.details.isEmpty {
        let facts = entity.details.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        line += " — " + facts.joined(separator: "; ")
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }

  private static func score(_ entity: MemoryEntity, now: Date) -> Double {
    let daysSinceSeen = max(0, now.timeIntervalSince(entity.lastSeenAt) / 86_400)
    // Halve relevance every ~2 weeks of silence; frequent entities decay slower.
    let recency = pow(0.5, daysSinceSeen / 14)
    return recency * (1 + log(Double(max(1, entity.occurrences))))
  }
}
