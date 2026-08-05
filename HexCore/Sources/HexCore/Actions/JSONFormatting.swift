//
//  JSONFormatting.swift
//  HexCore
//
//  Pretty-printing for trace payloads. MCP tools return their results as
//  text, and that text is usually JSON — often minified into one very long
//  line, and not rarely a JSON *string* that itself contains the JSON
//  payload (a text content block wrapping a serialized object). Both are
//  unreadable in a trace viewer, so this normalizes them.
//

import Foundation

public enum JSONFormatting {
  /// Re-serialized with indentation and sorted keys, or nil when `text`
  /// isn't JSON at all (a created-item id, a plain "Done", a prose error).
  ///
  /// `depth` bounds the double-encoding unwrap; it is not a caller concern.
  public static func prettified(_ text: String, depth: Int = 0) -> String? {
    guard depth < 3 else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Cheap reject before paying for a parse: JSON worth pretty-printing
    // starts with one of these.
    guard let first = trimmed.first, first == "{" || first == "[" || first == "\"" else { return nil }
    guard let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return nil }

    // A JSON string whose contents are themselves JSON — unwrap one level
    // so the trace shows the payload rather than an escaped blob.
    if let inner = object as? String {
      return prettified(inner, depth: depth + 1)
    }

    guard JSONSerialization.isValidJSONObject(object),
          let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          )
    else { return nil }
    return String(data: pretty, encoding: .utf8)
  }

  /// Whether `text` would render differently pretty-printed — used to decide
  /// if a raw/pretty toggle is worth showing at all.
  public static func isPrettifiable(_ text: String) -> Bool {
    guard let pretty = prettified(text) else { return false }
    return pretty != text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
