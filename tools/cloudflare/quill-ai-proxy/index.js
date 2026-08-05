/**
 * Quill AI proxy — Cloudflare Worker.
 *
 * Replaces the GCP Cloud Function of the same name (tools/cloud-functions/),
 * which became undeployable when project quill-495210's Artifact Registry was
 * left in a broken state by the 2026-07-31 delete/undelete.
 *
 * Holds the Anthropic key server-side so Pro users get bundled AI with no key
 * of their own. Callers authenticate with the Google OAuth access token the
 * app already holds; Pro entitlement is read directly from the Athena
 * dashboard's D1 (`quill_entitlements`), which is also what the dashboard's
 * Quill Admin tab writes.
 *
 * Reading D1 directly — rather than over HTTP as the Cloud Function had to —
 * removes the shared secret, the network hop, and any dependence on
 * Cloudflare Access carve-outs.
 *
 * Contract (unchanged from the Cloud Function, so no client change beyond the
 * URL in HexCore/AI/LLMTransport.swift):
 *   POST  Authorization: Bearer <google access token>
 *         { systemPrompt, userMessage, maxTokens? }
 *   200   { content, usage: { inputTokens, outputTokens } }
 */

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const DEFAULT_MODEL = "claude-haiku-4-5-20251001";
const DEFAULT_DAILY_LIMIT = 500;
const MAX_INPUT_CHARS = 100_000;

// OAuth client IDs the bearer token must have been issued to. Without this
// audience check any valid Google token from any app would be accepted.
const DEFAULT_AUDIENCES =
  "897102622833-ugs83fdspt94d9g373nh1v19gm4elive.apps.googleusercontent.com";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/// Mirrors `sanitizeEmail` in HexCore's AnalyticsFirestoreClient.swift and
/// `quillEmailKey` in the dashboard worker: dots to underscores, then "@" to
/// "_at_". Order matters.
function emailKey(email) {
  return email.trim().toLowerCase().replace(/\./g, "_").replace(/@/g, "_at_");
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") return new Response(null, { headers: CORS });
    if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);

    if (!env.ANTHROPIC_API_KEY) {
      console.error("ANTHROPIC_API_KEY not configured");
      return json({ error: "Server misconfigured" }, 500);
    }
    if (!env.ATHENA_DB) {
      console.error("ATHENA_DB binding missing — cannot check entitlement");
      return json({ error: "Server misconfigured" }, 500);
    }

    // ── Validate the Google token: audience, then email ──
    const auth = request.headers.get("authorization") || "";
    if (!auth.startsWith("Bearer ")) {
      return json({ error: "Missing or invalid Authorization header" }, 401);
    }
    const accessToken = auth.slice(7);

    let userEmail;
    try {
      // tokeninfo (unlike userinfo) returns the token's audience, so we can
      // verify it was minted for Quill rather than merely being a valid
      // Google token from some other app.
      const info = await fetch(
        `https://oauth2.googleapis.com/tokeninfo?access_token=${encodeURIComponent(accessToken)}`
      );
      if (!info.ok) return json({ error: "Invalid Google access token" }, 401);

      const tokenInfo = await info.json();
      const audiences = (env.QUILL_OAUTH_CLIENT_IDS || DEFAULT_AUDIENCES)
        .split(",")
        .map(a => a.trim())
        .filter(Boolean);
      if (!audiences.includes(tokenInfo.aud)) {
        console.warn(`Denied: token audience ${tokenInfo.aud} is not a Quill client`);
        return json({ error: "Token not issued to this app" }, 403);
      }
      userEmail = tokenInfo.email?.toLowerCase();
      if (!userEmail) return json({ error: "Token missing email scope" }, 401);
    } catch (err) {
      console.error("Token validation failed:", err);
      return json({ error: "Token validation failed" }, 401);
    }

    const key = emailKey(userEmail);

    // ── Pro entitlement ──
    // Break-glass: ALLOWED_EMAILS still overrides, for when D1 is unreachable
    // or an approval needs to happen faster than a dashboard visit.
    const breakGlass = (env.ALLOWED_EMAILS || "")
      .split(",")
      .map(e => e.trim().toLowerCase())
      .filter(Boolean);

    if (!breakGlass.includes(userEmail)) {
      let row;
      try {
        row = await env.ATHENA_DB
          .prepare("SELECT plan FROM quill_entitlements WHERE email_key = ?")
          .bind(key)
          .first();
      } catch (err) {
        console.error("Entitlement lookup failed:", err);
        return json({ error: "Entitlement check unavailable" }, 503); // fail closed
      }
      if (row?.plan !== "pro") {
        console.warn(`Denied: ${userEmail} is not entitled to Pro`);
        return json({ error: "Not authorized for Pro AI" }, 403);
      }
    }

    // ── Per-user daily cap ──
    // Kept in D1 rather than memory: Workers isolates are ephemeral and
    // numerous, so an in-process counter would barely brake anything.
    const dailyLimit = parseInt(env.DAILY_REQUEST_LIMIT || DEFAULT_DAILY_LIMIT, 10);
    const day = new Date().toISOString().slice(0, 10);
    try {
      const usage = await env.ATHENA_DB
        .prepare(
          `INSERT INTO quill_proxy_usage (email_key, day, count) VALUES (?, ?, 1)
           ON CONFLICT(email_key, day) DO UPDATE SET count = count + 1
           RETURNING count`
        )
        .bind(key, day)
        .first();
      if (usage && usage.count > dailyLimit) {
        console.warn(`Rate limited: ${userEmail} exceeded ${dailyLimit} requests today`);
        return json({ error: "Daily request limit reached" }, 429);
      }
    } catch (err) {
      // A broken counter shouldn't deny service — the cap is a spend brake,
      // not a security control.
      console.error("Usage counter failed (allowing request):", err);
    }

    // ── Forward to Anthropic ──
    let body;
    try { body = await request.json(); }
    catch { return json({ error: "Invalid JSON" }, 400); }

    const { systemPrompt, userMessage } = body;
    if (!systemPrompt || !userMessage) {
      return json({ error: "Missing systemPrompt or userMessage" }, 400);
    }
    if (typeof systemPrompt !== "string" || typeof userMessage !== "string" ||
        systemPrompt.length + userMessage.length > MAX_INPUT_CHARS) {
      return json({ error: "Input too large" }, 413);
    }

    // Client-requested output budget, clamped. Long structured outputs (the
    // suggestion engine's multi-draft JSON) need more than a flat 2048.
    const requested = Number(body.maxTokens);
    const maxTokens = Number.isFinite(requested)
      ? Math.min(Math.max(Math.trunc(requested), 1), 8192)
      : 2048;

    const model = env.ANTHROPIC_MODEL || DEFAULT_MODEL;

    try {
      const res = await fetch(ANTHROPIC_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": env.ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model,
          system: systemPrompt,
          messages: [{ role: "user", content: userMessage }],
          max_tokens: maxTokens,
        }),
      });

      if (!res.ok) {
        console.error(`Anthropic error ${res.status}: ${await res.text()}`);
        return json({ error: "AI provider error", status: res.status }, 502);
      }

      const data = await res.json();
      const content = data.content?.[0]?.text;
      if (!content) return json({ error: "Empty AI response" }, 502);

      const inputTokens = data.usage?.input_tokens || 0;
      const outputTokens = data.usage?.output_tokens || 0;

      // Token spend per user per day, for billing visibility.
      try {
        await env.ATHENA_DB
          .prepare(
            `UPDATE quill_proxy_usage
             SET input_tokens = input_tokens + ?, output_tokens = output_tokens + ?
             WHERE email_key = ? AND day = ?`
          )
          .bind(inputTokens, outputTokens, key, day)
          .run();
      } catch (err) {
        console.error("Token accounting failed:", err);
      }

      return json({ content, usage: { inputTokens, outputTokens } });
    } catch (err) {
      console.error("Anthropic call failed:", err);
      return json({ error: "AI request failed" }, 502);
    }
  },
};
