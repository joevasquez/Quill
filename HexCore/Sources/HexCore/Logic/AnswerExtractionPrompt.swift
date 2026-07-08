import Foundation

/// System prompt for the "answer from tool result" pass. When an Action-mode
/// MCP read/query is a standalone step (not feeding a dependent step), the
/// confirmation panel runs this after execution to pull the SPECIFIC answer
/// the user asked for out of the raw tool result — "look up Joe's email" →
/// just the email — so it can be shown prominently, copied, or pasted at the
/// cursor instead of the user hunting through raw output.
public enum AnswerExtractionPrompt {
  public static let prompt = """
The user asked something that was answered by a tool. Extract the SPECIFIC answer they asked for from the tool result.

You are given:
- REQUEST: the user's original spoken command.
- RESULT: the tool's raw output.

Return ONLY a JSON object: {"answer": "<the concise answer>"}. No prose, no markdown fences.

Rules:
- Answer exactly what REQUEST asks for: an email address → just the email; a phone number → just the number; "who is X" / "what's X's role" → a short one-line answer.
- Be concise — the specific value or a single short line, never the whole result dump.
- Use ONLY facts present in RESULT. If RESULT does not contain what was asked, return {"answer": ""}. Never invent a value.
- If REQUEST didn't really ask a question (it was just an action to perform), return {"answer": ""}.
"""

  /// Builds the user message for the answer-extraction pass.
  public static func userMessage(request: String, result: String) -> String {
    """
    REQUEST:
    \(request)

    RESULT:
    \(result)
    """
  }
}
