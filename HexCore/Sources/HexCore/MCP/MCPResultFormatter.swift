import Foundation

/// Turns a raw MCP tool result (usually a JSON blob) into a compact,
/// human-readable form for the confirmation panel's output box + Copy button.
///
/// Schema-agnostic: it detects a JSON object/array, finds the record(s),
/// and renders each as a `Name` heading + `Label: value` lines, dropping
/// noise (ids, image URLs, counts). Anything it can't make sense of falls
/// back to pretty-printed JSON, then to the raw text — so it never loses
/// information, only tidies it.
///
/// NOTE: this is display-only. The resolve pass and any downstream consumer
/// still receive the RAW result, so LLM extraction quality is unaffected.
public enum MCPResultFormatter {
  /// Keys whose values are noise for a human reading a result (internal ids,
  /// avatars, thumbnails). Matched case-insensitively; any key ending in
  /// `_id` or `url`/`uri` pointing at an image is also dropped.
  private static let noiseKeys: Set<String> = [
    "id", "image_url", "imageurl", "avatar", "avatar_url", "photo", "photo_url",
    "icon", "icon_url", "thumbnail", "thumbnail_url", "object", "type", "kind",
  ]

  /// Friendly labels for common field names; anything else is humanized
  /// (`legacy_location` → "Legacy location").
  private static let labelAliases: [String: String] = [
    "first_name": "Name", "last_name": "Name", "full_name": "Name", "display_name": "Name",
    "job_title": "Title", "jobtitle": "Title", "title": "Title",
    "legacy_location": "Location", "location": "Location",
    "email": "Email", "emails": "Email", "email_address": "Email",
    "phone": "Phone", "phone_number": "Phone", "company": "Company",
    "description": "Notes", "notes": "Notes", "starred": "Starred",
  ]

  private static let maxRecords = 10

  public static func format(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    guard let data = trimmed.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data)
    else {
      return trimmed // not JSON — the tool returned plain text
    }

    let records = extractRecords(from: json)
    guard !records.isEmpty else {
      return prettyPrinted(data) ?? trimmed // JSON but not record-shaped
    }

    let blocks = records.prefix(maxRecords).map(renderRecord).filter { !$0.isEmpty }
    guard !blocks.isEmpty else { return prettyPrinted(data) ?? trimmed }

    var out = blocks.joined(separator: "\n\n")
    if records.count > maxRecords {
      out += "\n\n…and \(records.count - maxRecords) more"
    }
    return out
  }

  // MARK: - Record extraction

  /// Finds the list of record dictionaries in a decoded JSON value: a
  /// top-level array of objects, an object wrapping one (`items`/`results`/…),
  /// or a single object treated as one record.
  private static func extractRecords(from json: Any) -> [[String: Any]] {
    if let array = json as? [[String: Any]] {
      return array
    }
    if let object = json as? [String: Any] {
      // Prefer the first value that is an array of objects (items/results/data).
      for (_, value) in object {
        if let array = value as? [[String: Any]], !array.isEmpty {
          return array
        }
      }
      // Otherwise treat the object itself as a single record.
      return [object]
    }
    return []
  }

  // MARK: - Rendering

  private static func renderRecord(_ record: [String: Any]) -> String {
    var lines: [String] = []

    // Heading: a person/entity name if we can derive one.
    if let name = derivedName(from: record) {
      lines.append(name)
    }

    // Remaining scalar fields, common ones first, then the rest alphabetically.
    let nameKeys: Set<String> = ["first_name", "last_name", "full_name", "display_name", "name"]
    let priority = ["job_title", "title", "email", "emails", "email_address", "phone", "company", "legacy_location", "location", "description", "notes"]
    let remaining = record.keys
      .filter { !nameKeys.contains($0.lowercased()) }
      .sorted { a, b in
        let ia = priority.firstIndex(of: a.lowercased()) ?? Int.max
        let ib = priority.firstIndex(of: b.lowercased()) ?? Int.max
        return ia == ib ? a < b : ia < ib
      }

    for key in remaining {
      guard let value = record[key], let rendered = renderValue(key: key, value: value) else { continue }
      lines.append("\(label(for: key)): \(rendered)")
    }

    return lines.joined(separator: "\n")
  }

  private static func derivedName(from record: [String: Any]) -> String? {
    let first = (record["first_name"] as? String)?.trimmingCharacters(in: .whitespaces)
    let last = (record["last_name"] as? String)?.trimmingCharacters(in: .whitespaces)
    let composed = [first, last].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    if !composed.isEmpty { return composed }
    for key in ["full_name", "display_name", "name", "title"] {
      if let v = (record[key] as? String)?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
        return v
      }
    }
    return nil
  }

  /// Renders a scalar value, or nil to skip it (noise key, empty, image URL,
  /// false boolean, nested container).
  private static func renderValue(key: String, value: Any) -> String? {
    let lowerKey = key.lowercased()
    if noiseKeys.contains(lowerKey) || lowerKey.hasSuffix("_id") { return nil }

    if isBool(value) {
      // Only surface a positive flag ("Starred: Yes"); false is noise.
      return (value as? Bool) == true ? "Yes" : nil
    }
    if let number = value as? NSNumber {
      return number.stringValue
    }
    if let string = value as? String {
      let v = string.trimmingCharacters(in: .whitespacesAndNewlines)
      if v.isEmpty || looksLikeImageURL(v) { return nil }
      return v
    }
    if let array = value as? [Any] {
      let scalars = array.compactMap { $0 as? String }.filter { !$0.isEmpty }
      return scalars.isEmpty ? nil : scalars.joined(separator: ", ")
    }
    return nil // nested object — too complex for the summary line
  }

  private static func label(for key: String) -> String {
    if let alias = labelAliases[key.lowercased()] { return alias }
    let spaced = key.replacingOccurrences(of: "_", with: " ")
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
  }

  // MARK: - Helpers

  private static func isBool(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func looksLikeImageURL(_ s: String) -> Bool {
    guard s.hasPrefix("http") else { return false }
    let lower = s.lowercased()
    return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
      || lower.hasSuffix(".gif") || lower.hasSuffix(".webp")
      || lower.contains("/avatar") || lower.contains("storage.googleapis")
  }

  private static func prettyPrinted(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: pretty, encoding: .utf8)
    else { return nil }
    return string
  }
}
