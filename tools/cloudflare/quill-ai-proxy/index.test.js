import assert from "node:assert/strict";
import test from "node:test";

import { buildOpenRouterRequest } from "./index.js";

test("builds the Pro request for OpenRouter without exposing the key to clients", async () => {
  const request = buildOpenRouterRequest(
    {
      systemPrompt: "Return JSON only.",
      userMessage: "Create a reminder",
      maxTokens: 9000,
      jsonResponse: true,
    },
    {
      OPENROUTER_API_KEY: "sk-or-secret",
      OPENROUTER_MODEL: "openai/gpt-5-mini",
    }
  );

  assert.equal(request.url, "https://openrouter.ai/api/v1/chat/completions");
  assert.equal(request.headers.get("Authorization"), "Bearer sk-or-secret");
  assert.equal(request.headers.get("HTTP-Referer"), "https://quill.joevasquez.com");
  assert.equal(request.headers.get("X-OpenRouter-Title"), "Quill");

  const body = await request.json();
  assert.equal(body.model, "openai/gpt-5-mini");
  assert.equal(body.max_tokens, 8192);
  assert.deepEqual(body.response_format, { type: "json_object" });
  assert.deepEqual(body.messages, [
    { role: "system", content: "Return JSON only." },
    { role: "user", content: "Create a reminder" },
  ]);
});

test("does not force JSON mode for transcript cleanup", async () => {
  const request = buildOpenRouterRequest(
    {
      systemPrompt: "Clean up this transcript.",
      userMessage: "hello comma world",
      maxTokens: 2048,
      jsonResponse: false,
    },
    { OPENROUTER_API_KEY: "sk-or-secret" }
  );

  const body = await request.json();
  assert.equal(body.model, "openai/gpt-5-mini");
  assert.equal("response_format" in body, false);
});
