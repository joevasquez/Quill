import Foundation

/// Last-resort repairs for model-emitted JSON.
///
/// Only ever applied AFTER a strict decode has already failed, so a
/// well-formed reply is never touched. The repairs are deliberately narrow:
/// each one fixes a mistake that is unambiguous to correct and impossible
/// in valid JSON, so applying it can turn a failure into a success but
/// cannot change the meaning of anything that already parsed.
public enum JSONRepair {
  /// Escapes raw control characters that appear *inside* string literals.
  ///
  /// JSON forbids literal newlines, tabs, and other control characters in
  /// strings — they must be written `\n`, `\t`, `\uXXXX`. Models are
  /// reliable about this for short values and much less so when asked to
  /// put multi-paragraph prose in a field, which is exactly what a drafted
  /// reply is. One raw newline makes the entire response unparseable and
  /// the whole command fails.
  ///
  /// Since valid JSON can never contain an unescaped control character in a
  /// string, this rewrite is a no-op on anything already well-formed.
  public static func escapingControlCharactersInStrings(_ json: String) -> String {
    var out = String()
    out.reserveCapacity(json.count)
    var inString = false
    var escaped = false

    for character in json {
      if escaped {
        // Previous character was a backslash — this one is its payload and
        // passes through untouched (including a legitimate `\n`).
        out.append(character)
        escaped = false
        continue
      }
      if character == "\\" {
        out.append(character)
        escaped = inString  // a backslash outside a string isn't an escape
        continue
      }
      if character == "\"" {
        inString.toggle()
        out.append(character)
        continue
      }
      guard inString else {
        out.append(character)  // whitespace between tokens is legal
        continue
      }
      switch character {
      case "\n": out.append("\\n")
      case "\r": out.append("\\r")
      case "\t": out.append("\\t")
      default:
        if let ascii = character.asciiValue, ascii < 0x20 {
          out.append(String(format: "\\u%04x", Int(ascii)))
        } else {
          out.append(character)
        }
      }
    }
    return out
  }
}
