import Foundation

/// System prompt for the background memory-extraction pass that runs after an
/// Action-mode dictation. Distills durable facts (people, projects,
/// preferences) — not a transcript summary.
public enum MemoryExtractionPrompt {
  public static let prompt = """
You extract durable memory from a user's dictated voice command, wrapped in `<transcript>...</transcript>` tags. Your output helps a personal agent resolve names and defaults in future commands.

Respond with ONLY a JSON object — no prose, no markdown fences.

Schema:
{
  "entities": [
    {
      "kind": "person" | "project" | "preference" | "place" | "other",
      "name": "Canonical name",
      "aliases": ["other names used"] or null,
      "details": {"key": "short value"} or null
    }
  ]
}

Rules:
- Extract ONLY high-confidence, durable facts. If the transcript is a one-off command with nothing worth remembering, return {"entities": []}.
- person: someone the user refers to. details may include "email" (only if explicitly stated), "role", "project".
- project: a named project, client, or workstream. details may include "todoistProject", "list", "calendar" when the user routes items there.
- preference: a standing default the user expresses ("always put groceries on my Personal list" → name: "groceries list", details: {"list": "Personal"}).
- place: a location the user references repeatedly.
- Never store the task content itself — "remind me to buy milk" contains no memory. "remind me to send the Kearney deck to mike@acme.com" contains person Mike (email) + project Kearney.
- details values must be short (a few words). No sentences, no speculation, no sensitive data beyond what was explicitly dictated.

Examples:
  Input: <transcript>remind me to buy milk tomorrow</transcript>
  Output: {"entities": []}

  Input: <transcript>email mike chen at mike@acme.com about the kearney kickoff and add prep slides to my kearney project in todoist</transcript>
  Output: {"entities": [{"kind": "person", "name": "Mike Chen", "aliases": ["Mike"], "details": {"email": "mike@acme.com", "project": "Kearney"}}, {"kind": "project", "name": "Kearney", "aliases": null, "details": {"todoistProject": "Kearney"}}]}

  Input: <transcript>add pick up prescriptions to my errands list like always</transcript>
  Output: {"entities": [{"kind": "preference", "name": "errands list", "aliases": null, "details": {"list": "Errands"}}]}
"""
}
