// ThreadKeep support endpoint.
//
// Accepts exactly one thing: a JSON contact-form submission from the app,
// with the fields the tester saw on screen. Validates, rate-limits, and
// relays to the private support inbox (SUPPORT_INBOX secret). Returns only
// generic statuses — no configuration, no internals, no addresses.

import { EmailMessage } from "cloudflare:email";
import { createMimeMessage } from "mimetext";

const TOPICS = new Set([
  "General Feedback",
  "Bug Report",
  "Feature Request",
  "Help Using ThreadKeep",
]);

const LIMITS = {
  message: 8000,
  email: 254,
  version: 32,
  build: 32,
  macos: 32,
  architecture: 32,
  timestamp: 40,
};

const RATE_LIMIT_PER_HOUR = 5;

const FROM_ADDRESS = "support@treefort.lol"; // sending identity only; not an inbox

function badRequest() {
  return json({ ok: false, error: "invalid" }, 400);
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function cleanString(value, max) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > max) return null;
  // Strip control characters (keep newlines/tabs in the message body).
  return trimmed.replace(/[^\P{Cc}\n\t]/gu, "");
}

function looksLikeEmail(value) {
  // Permissive shape check: something@something.something
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

async function rateLimited(env, ip) {
  const key = `ip:${ip}`;
  const current = parseInt((await env.RATE.get(key)) ?? "0", 10);
  if (current >= RATE_LIMIT_PER_HOUR) return true;
  await env.RATE.put(key, String(current + 1), { expirationTtl: 3600 });
  return false;
}

export default {
  async fetch(request, env) {
    if (request.method !== "POST" || new URL(request.url).pathname !== "/submit") {
      return json({ ok: false, error: "not_found" }, 404);
    }

    const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
    if (await rateLimited(env, ip)) {
      return json({ ok: false, error: "rate_limited" }, 429);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return badRequest();
    }
    if (typeof body !== "object" || body === null) return badRequest();

    const topic = typeof body.topic === "string" && TOPICS.has(body.topic) ? body.topic : null;
    const message = cleanString(body.message, LIMITS.message);
    const version = cleanString(body.appVersion, LIMITS.version);
    const build = cleanString(body.buildNumber, LIMITS.build);
    const macos = cleanString(body.macosVersion, LIMITS.macos);
    const architecture = cleanString(body.architecture, LIMITS.architecture);
    const timestamp = cleanString(body.timestamp, LIMITS.timestamp);
    if (!topic || !message || !version || !build || !macos || !architecture || !timestamp) {
      return badRequest();
    }

    let replyEmail = null;
    if (body.replyEmail !== undefined && body.replyEmail !== null && body.replyEmail !== "") {
      replyEmail = cleanString(body.replyEmail, LIMITS.email);
      if (!replyEmail || !looksLikeEmail(replyEmail)) return badRequest();
    }

    try {
      const mime = createMimeMessage();
      mime.setSender({ name: "ThreadKeep Support Form", addr: FROM_ADDRESS });
      mime.setRecipient(env.SUPPORT_INBOX);
      mime.setSubject(`[ThreadKeep ${version}b${build}] ${topic}`);
      mime.addMessage({
        contentType: "text/plain",
        data: [
          `Topic: ${topic}`,
          `Reply email: ${replyEmail ?? "(not provided)"}`,
          "",
          message,
          "",
          "—",
          `ThreadKeep ${version} (build ${build})`,
          `macOS ${macos} · ${architecture}`,
          `Submitted: ${timestamp}`,
        ].join("\n"),
      });

      // Set Reply-To by header injection: mimetext's setHeader rejects this
      // header, and replyEmail is regex-validated to contain no whitespace
      // (so it cannot forge additional header lines).
      let raw = mime.asRaw();
      if (replyEmail) {
        raw = `Reply-To: ${replyEmail}\r\n${raw}`;
      }

      await env.EMAIL.send(
        new EmailMessage(FROM_ADDRESS, env.SUPPORT_INBOX, raw)
      );
    } catch {
      // Never leak provider/config details to the client.
      return json({ ok: false, error: "unavailable" }, 502);
    }

    return json({ ok: true });
  },
};
