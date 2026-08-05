import Foundation
import Testing

@testable import HexCore

@Suite("JSONFormatting")
struct JSONFormattingTests {
  @Test("Minified object is expanded and key-sorted")
  func prettifiesObject() throws {
    let pretty = try #require(JSONFormatting.prettified(#"{"name":"Joe","email":"joe@example.com"}"#))
    #expect(pretty.contains("\n"))
    // Sorted keys: email before name.
    let emailIndex = try #require(pretty.range(of: "\"email\""))
    let nameIndex = try #require(pretty.range(of: "\"name\""))
    #expect(emailIndex.lowerBound < nameIndex.lowerBound)
  }

  @Test("Arrays prettify too")
  func prettifiesArray() {
    #expect(JSONFormatting.prettified(#"[{"id":1},{"id":2}]"#)?.contains("\n") == true)
  }

  @Test("Slashes are not escaped — URLs stay readable")
  func doesNotEscapeSlashes() throws {
    let pretty = try #require(JSONFormatting.prettified(#"{"url":"https://example.com/a"}"#))
    #expect(pretty.contains("https://example.com/a"))
    #expect(!pretty.contains("\\/"))
  }

  @Test("A JSON string wrapping JSON is unwrapped one level")
  func unwrapsDoubleEncoded() throws {
    // What an MCP text content block often carries: the payload serialized
    // into a string, then serialized again.
    let inner = #"{"contact_id":"abc","email":"joe@example.com"}"#
    let doubled = try #require(
      String(data: try JSONSerialization.data(withJSONObject: inner, options: [.fragmentsAllowed]), encoding: .utf8)
    )
    let pretty = try #require(JSONFormatting.prettified(doubled))
    #expect(pretty.contains("\"contact_id\""))
    #expect(!pretty.contains("\\\""))
  }

  @Test("Non-JSON payloads are left alone")
  func rejectsNonJSON() {
    #expect(JSONFormatting.prettified("Done") == nil)
    #expect(JSONFormatting.prettified("") == nil)
    #expect(JSONFormatting.prettified("x-reminder-id://1234") == nil)
    #expect(JSONFormatting.prettified("Contact not found") == nil)
    // Looks like JSON, isn't.
    #expect(JSONFormatting.prettified("{not json}") == nil)
  }

  @Test("Bare quoted strings aren't treated as prettifiable payloads")
  func rejectsPlainQuotedString() {
    #expect(JSONFormatting.prettified("\"just a string\"") == nil)
  }

  @Test("isPrettifiable is false when formatting changes nothing")
  func alreadyPretty() throws {
    let pretty = try #require(JSONFormatting.prettified(#"{"a":1,"b":2}"#))
    #expect(JSONFormatting.isPrettifiable(pretty) == false)
    #expect(JSONFormatting.isPrettifiable(#"{"a":1,"b":2}"#) == true)
  }
}
