import Foundation

/// Where text transformations such as cleanup, note edits, and titles run.
/// `automatic` is intentionally plan-aware: free users get the private local
/// model when their device supports it, while Pro keeps its cloud service.
public enum TextAIExecutionPreference: String, CaseIterable, Codable, Sendable {
  case automatic
  case onDevice
  case cloud

  public var displayName: String {
    switch self {
    case .automatic: "Automatic"
    case .onDevice: "On Device"
    case .cloud: "Cloud"
    }
  }
}

public enum TextAIExecutionRoute: Equatable, Sendable {
  case onDevice
  case cloud
}

public enum TextAIRouteResolver {
  public static func resolve(
    preference: TextAIExecutionPreference,
    isPro: Bool,
    onDeviceAvailable: Bool
  ) -> TextAIExecutionRoute {
    switch preference {
    case .onDevice: .onDevice
    case .cloud: .cloud
    case .automatic:
      !isPro && onDeviceAvailable ? .onDevice : .cloud
    }
  }
}

/// Detects the common failure where a model technically returns Markdown but
/// collapses a multi-idea note into a single oversized bullet.
public enum NoteEditOutputValidator {
  public static func needsBulletRetry(command: String, source: String, output: String) -> Bool {
    let instruction = command.lowercased()
    guard instruction.contains("bullet") || instruction.split(whereSeparator: { !$0.isLetter }).contains("list") else {
      return false
    }
    guard distinctIdeaCount(in: source) >= 2 else { return false }
    return markdownBulletCount(in: output) < 2
  }

  public static func markdownBulletCount(in text: String) -> Int {
    text.split(separator: "\n", omittingEmptySubsequences: true).count { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") ||
        trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil
    }
  }

  private static func distinctIdeaCount(in text: String) -> Int {
    let lines = text.split(separator: "\n").filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if lines.count >= 2 { return lines.count }
    return text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .count
  }
}
