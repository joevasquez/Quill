import Foundation

/// System prompt for the between-steps "resolve" pass in a chained Action
/// workflow. When a later step depends on an earlier step's result (e.g.
/// "find Joe in Dex, then draft him a birthday email"), the executor runs
/// this pass after the dependency completes: it feeds the dependency's raw
/// text output, the user's original request, and the dependent step's current
/// JSON, and asks the model to both FILL the linking field (the recipient)
/// and PERSONALIZE the action's text (greet Joe by name) using facts from the
/// prior result.
public enum StepResolvePrompt {
  public static let prompt = """
You finalize a single JSON action that depends on the result of a previous step in a workflow. Use the previous step's result to fill in and personalize the action.

You are given:
- REQUEST: the user's original spoken command, for context on what they want.
- PRIOR RESULT: the raw text output of the step this action depends on (e.g. a contact lookup returning a name and email).
- INSTRUCTION: what to pull from the prior result and which field(s) to fill.
- ACTION: the current JSON action object, with placeholder or generic fields to finalize.

Return ONLY the updated JSON action object — the same shape and keys as ACTION. No prose, no markdown fences, no preamble.

What to do:
- Fill the linking field(s) the INSTRUCTION names — e.g. set `recipient` to the email address found in PRIOR RESULT.
- PERSONALIZE the action's text using facts from PRIOR RESULT when the REQUEST implies it: address people by the name found (rewrite a generic "Happy birthday!" into "Happy birthday, Joe!"), and weave in relevant details the prior result provides. Update `subject`/`notes`/`title` as needed to reflect that personalization.
- Keep the message's intent and tone from ACTION/REQUEST — you are personalizing it, not rewriting the whole thing from scratch.

Rules:
- Only use facts actually present in PRIOR RESULT. NEVER invent an email, name, or detail that isn't there. If a needed value is missing, leave that field as it was in ACTION.
- Extract specific values (an email address, a first name) — do NOT paste the entire raw PRIOR RESULT into a field.
- Preserve every key present in ACTION (including nulls) and leave fields the request doesn't touch unchanged. Keep the JSON valid.
"""

  /// Builds the user message for the resolve pass.
  public static func userMessage(actionJSON: String, priorResult: String, instruction: String, request: String) -> String {
    """
    REQUEST:
    \(request)

    PRIOR RESULT:
    \(priorResult)

    INSTRUCTION:
    \(instruction)

    ACTION:
    \(actionJSON)
    """
  }
}
