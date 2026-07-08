import Foundation

/// System prompt for the between-steps "resolve" pass in a chained Action
/// workflow. When a later step depends on an earlier step's result (e.g.
/// "look up Joe's email, then draft him an email"), the executor runs this
/// pass after the dependency completes: it feeds the dependency's raw text
/// output plus the dependent step's current JSON and asks the model to fill
/// in the field(s) named by the step's `resolveInstruction`.
public enum StepResolvePrompt {
  public static let prompt = """
You fill in a single JSON action using the text result of a previous step in a workflow.

You are given:
- PRIOR RESULT: the raw text output of the step this action depends on.
- INSTRUCTION: what to extract from the prior result and which field(s) to fill.
- ACTION: the current JSON action object, possibly with placeholder or empty fields.

Return ONLY the updated JSON action object — the same shape as ACTION, with the requested field(s) filled from PRIOR RESULT. No prose, no markdown fences, no preamble.

Rules:
- Change only the field(s) the INSTRUCTION calls for. Leave every other field exactly as it was in ACTION.
- Extract the specific value the instruction asks for (an email address, a name, an id, a date) — do NOT paste the entire prior result into a field.
- If the prior result does not contain the requested value, leave the field as it was in ACTION (do not invent a value).
- Keep the JSON valid and preserve all keys present in ACTION, including nulls.
"""

  /// Builds the user message for the resolve pass.
  public static func userMessage(actionJSON: String, priorResult: String, instruction: String) -> String {
    """
    PRIOR RESULT:
    \(priorResult)

    INSTRUCTION:
    \(instruction)

    ACTION:
    \(actionJSON)
    """
  }
}
