const functions = require("@google-cloud/functions-framework");

// ── Configuration ──
// Set ANTHROPIC_API_KEY as a Cloud Function environment variable (or Secret Manager ref).
// ALLOWED_EMAILS is a comma-separated whitelist and is REQUIRED — the proxy fails
// closed if it is missing. Server-side entitlement (Firestore) replaces this later.
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const ALLOWED_EMAILS = process.env.ALLOWED_EMAILS
  ? process.env.ALLOWED_EMAILS.split(",").map((e) => e.trim().toLowerCase()).filter(Boolean)
  : null;
const ANTHROPIC_MODEL = process.env.ANTHROPIC_MODEL || "claude-haiku-4-5-20251001";
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

// OAuth client IDs the bearer token must have been issued to (audience pinning).
// Default: Quill's shared macOS/iOS client. Override/extend via QUILL_OAUTH_CLIENT_IDS.
const ALLOWED_AUDIENCES = (process.env.QUILL_OAUTH_CLIENT_IDS ||
  "897102622833-ugs83fdspt94d9g373nh1v19gm4elive.apps.googleusercontent.com")
  .split(",")
  .map((a) => a.trim())
  .filter(Boolean);

// Per-user daily request cap. In-memory, so it resets when the instance is
// recycled and is not shared across instances — a soft brake against runaway
// spend, not a billing system.
const DAILY_REQUEST_LIMIT = parseInt(process.env.DAILY_REQUEST_LIMIT || "500", 10);
const usageByUser = new Map(); // email -> { day: "YYYY-MM-DD", count: number }

// Reject oversized payloads before they reach Anthropic.
const MAX_INPUT_CHARS = 100_000;

function checkDailyLimit(email) {
  const today = new Date().toISOString().slice(0, 10);
  const entry = usageByUser.get(email);
  if (!entry || entry.day !== today) {
    usageByUser.set(email, { day: today, count: 1 });
    return true;
  }
  if (entry.count >= DAILY_REQUEST_LIMIT) return false;
  entry.count += 1;
  return true;
}

functions.http("quill-ai-proxy", async (req, res) => {
  // CORS for preflight
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") {
    res.status(204).send("");
    return;
  }

  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  if (!ANTHROPIC_API_KEY) {
    console.error("ANTHROPIC_API_KEY not configured");
    res.status(500).json({ error: "Server misconfigured" });
    return;
  }

  // Fail closed: an unset allowlist means nobody gets through, not everybody.
  if (!ALLOWED_EMAILS || ALLOWED_EMAILS.length === 0) {
    console.error("ALLOWED_EMAILS not configured — refusing all requests");
    res.status(503).json({ error: "Service not configured" });
    return;
  }

  // ── Validate Google OAuth token: audience + email ──
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith("Bearer ")) {
    res.status(401).json({ error: "Missing or invalid Authorization header" });
    return;
  }

  const accessToken = authHeader.slice(7);
  let userEmail;
  try {
    // tokeninfo (unlike userinfo) returns the token's audience, so we can
    // verify the token was minted for Quill's OAuth client — not just that
    // it is some valid Google token from any app.
    const tokenInfoRes = await fetch(
      `https://oauth2.googleapis.com/tokeninfo?access_token=${encodeURIComponent(accessToken)}`
    );
    if (!tokenInfoRes.ok) {
      res.status(401).json({ error: "Invalid Google access token" });
      return;
    }
    const tokenInfo = await tokenInfoRes.json();
    if (!ALLOWED_AUDIENCES.includes(tokenInfo.aud)) {
      console.warn(`Denied: token audience ${tokenInfo.aud} is not a Quill client`);
      res.status(403).json({ error: "Token not issued to this app" });
      return;
    }
    userEmail = tokenInfo.email?.toLowerCase();
    if (!userEmail) {
      res.status(401).json({ error: "Token missing email scope" });
      return;
    }
  } catch (err) {
    console.error("Token validation failed:", err);
    res.status(401).json({ error: "Token validation failed" });
    return;
  }

  // ── Check whitelist ──
  if (!ALLOWED_EMAILS.includes(userEmail)) {
    console.warn(`Denied: ${userEmail} not in allowlist`);
    res.status(403).json({ error: "Not authorized for Pro AI" });
    return;
  }

  // ── Per-user daily cap ──
  if (!checkDailyLimit(userEmail)) {
    console.warn(`Rate limited: ${userEmail} exceeded ${DAILY_REQUEST_LIMIT} requests today`);
    res.status(429).json({ error: "Daily request limit reached" });
    return;
  }

  // ── Forward to Anthropic ──
  const { systemPrompt, userMessage } = req.body;
  if (!systemPrompt || !userMessage) {
    res.status(400).json({ error: "Missing systemPrompt or userMessage" });
    return;
  }
  if (typeof systemPrompt !== "string" || typeof userMessage !== "string" ||
      systemPrompt.length + userMessage.length > MAX_INPUT_CHARS) {
    res.status(413).json({ error: "Input too large" });
    return;
  }

  try {
    const anthropicRes = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: ANTHROPIC_MODEL,
        system: systemPrompt,
        messages: [{ role: "user", content: userMessage }],
        max_tokens: 2048,
      }),
    });

    if (!anthropicRes.ok) {
      const errBody = await anthropicRes.text();
      console.error(`Anthropic error ${anthropicRes.status}: ${errBody}`);
      res.status(502).json({ error: "AI provider error", status: anthropicRes.status });
      return;
    }

    const anthropicData = await anthropicRes.json();
    const content = anthropicData.content?.[0]?.text;
    if (!content) {
      res.status(502).json({ error: "Empty AI response" });
      return;
    }

    // Log usage for billing visibility
    const inputTokens = anthropicData.usage?.input_tokens || 0;
    const outputTokens = anthropicData.usage?.output_tokens || 0;
    console.log(
      JSON.stringify({
        event: "proxy_request",
        user: userEmail,
        model: ANTHROPIC_MODEL,
        inputTokens,
        outputTokens,
      })
    );

    res.json({ content, usage: { inputTokens, outputTokens } });
  } catch (err) {
    console.error("Anthropic call failed:", err);
    res.status(502).json({ error: "AI provider unreachable" });
  }
});
