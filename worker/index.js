// NOVA AI worker V0.4 - DeepSeek (OpenAI-compatible) with real token streaming (SSE).
// NOTE: "deepseek-chat" was retired on 2026-07-24 (DeepSeek docs) -> default is deepseek-v4-flash.
// Override with the DEEPSEEK_MODEL variable (e.g. deepseek-v4-pro).
const API = "https://api.deepseek.com/chat/completions";
const DEFAULT_MODEL = "deepseek-v4-flash";
const MAX_MESSAGES = 12;          // last N messages sent to the model
const MAX_CHARS = 30000;
const DEFAULT_MAX_TOKENS = 2048;  // override with MAX_OUTPUT_TOKENS (256..8192)
const SYSTEM_PROMPT =
  "You are NOVA AI, a helpful, accurate and friendly assistant. " +
  "Always reply in the same language the user writes in (Arabic or English). " +
  "Use Markdown for structure when useful. " +
  "When writing code, use fenced Markdown code blocks with the language name.";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/api/health") return json({ ok: true, provider: "DeepSeek" });
    if (url.pathname === "/api/chat") {
      if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
      return handleChat(request, env, ctx);
    }
    if (env.ASSETS) return env.ASSETS.fetch(request);
    return new Response("Not found", { status: 404 });
  },
};

function maxTokens(env) {
  const n = parseInt(env.MAX_OUTPUT_TOKENS, 10);
  return Number.isFinite(n) ? Math.min(Math.max(n, 256), 8192) : DEFAULT_MAX_TOKENS;
}

async function handleChat(request, env, ctx) {
  if (!env.DEEPSEEK_API_KEY) {
    return json({ error: "الخادم غير مهيأ: DEEPSEEK_API_KEY غير موجود. أضفه بـ wrangler secret put." }, 500);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "طلب غير صالح (JSON)." }, 400);
  }
  if (!body || !Array.isArray(body.messages) || !body.messages.length) {
    return json({ error: "لا توجد رسائل." }, 400);
  }

  const messages = body.messages
    .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string" && m.content.trim())
    .slice(-MAX_MESSAGES)
    .map((m) => ({ role: m.role, content: m.content }));
  while (messages.length && messages[0].role !== "user") messages.shift();
  if (!messages.length || messages[messages.length - 1].role !== "user") {
    return json({ error: "يجب أن تنتهي المحادثة برسالة من المستخدم." }, 400);
  }
  const total = messages.reduce((n, m) => n + m.content.length, 0);
  if (total > MAX_CHARS) return json({ error: "المحادثة طويلة جدًا. ابدأ محادثة جديدة." }, 413);

  const model = env.DEEPSEEK_MODEL ? String(env.DEEPSEEK_MODEL) : DEFAULT_MODEL;
  const base = {
    model,
    messages: [{ role: "system", content: SYSTEM_PROMPT }, ...messages],
    temperature: 0.7,
    max_tokens: maxTokens(env),
    stream: true,
  };
  // First try with thinking disabled (fast first token); if the API rejects that field (400), retry without it.
  const attempts = [{ ...base, thinking: { type: "disabled" } }, base];

  let res = null;
  for (let i = 0; i < attempts.length; i++) {
    try {
      res = await fetch(API, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.DEEPSEEK_API_KEY}` },
        body: JSON.stringify(attempts[i]),
      });
    } catch {
      return json({ error: "تعذر الاتصال بـ DeepSeek. حاول مرة أخرى." }, 502);
    }
    if (res.status !== 400) break;
  }

  if (!res.ok || !res.body) {
    const details = await res.text().catch(() => "");
    console.error("DeepSeek API error:", res.status, details.slice(0, 1000));
    let msg = `خطأ من DeepSeek (${res.status}). راجع سجلات الـ Worker.`;
    if (res.status === 401) msg = "مفتاح DeepSeek غير صالح.";
    else if (res.status === 402) msg = "رصيد DeepSeek غير كافٍ.";
    else if (res.status === 429) msg = "DeepSeek مشغول أو تم تجاوز الحد. حاول بعد قليل.";
    else if (res.status === 400 || res.status === 422) msg = "طلب مرفوض من DeepSeek. تأكد من اسم النموذج (DEEPSEEK_MODEL).";
    else if (res.status >= 500) msg = "خدمة DeepSeek غير متاحة حاليًا. حاول لاحقًا.";
    return json({ error: msg }, res.status === 429 ? 429 : 502);
  }
  return streamResponse(res, model, ctx);
}

// Converts DeepSeek's OpenAI-style SSE into the minimal protocol the frontend reads:
//   data: {"t":"text chunk"} ... data: {"done":true,"model":"...","finish":"STOP|MAX_TOKENS","elapsed_ms":n}
//   data: {"error":"message"}   (any failure after streaming started)
function streamResponse(upstream, model, ctx) {
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const send = (o) => writer.write(enc.encode("data: " + JSON.stringify(o) + "\n\n"));
  const reader = upstream.body.getReader();
  const started = Date.now();

  const pump = (async () => {
    let buf = "", any = false, finish = null, sawDone = false;
    const handleLine = async (line) => {
      line = line.trim();
      if (!line.startsWith("data:")) return; // ignores ": keep-alive" comments
      const s = line.slice(5).trim();
      if (s === "[DONE]") { sawDone = true; return; }
      if (!s) return;
      let d;
      try { d = JSON.parse(s); } catch { return; }
      if (d.error) throw new Error("upstream error");
      const ch = d.choices && d.choices[0];
      if (!ch) return;
      const text = ch.delta && typeof ch.delta.content === "string" ? ch.delta.content : "";
      if (text) { any = true; await send({ t: text }); } // reasoning_content is intentionally ignored
      if (ch.finish_reason) finish = ch.finish_reason;
    };
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let i;
        while ((i = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, i);
          buf = buf.slice(i + 1);
          await handleLine(line);
        }
      }
      buf += dec.decode();
      if (buf) await handleLine(buf);
      if (!any) await send({ error: "لم يرجع DeepSeek أي رد. جرّب صياغة مختلفة." });
      else if (!sawDone && !finish) await send({ error: "انقطع البث من DeepSeek. حاول مرة أخرى." });
      else await send({ done: true, model, finish: finish === "length" ? "MAX_TOKENS" : "STOP", elapsed_ms: Date.now() - started });
    } catch {
      try { await send({ error: "انقطع البث من DeepSeek. حاول مرة أخرى." }); } catch { /* client gone */ }
    } finally {
      try { await reader.cancel(); } catch { /* ignore */ }
      try { await writer.close(); } catch { /* ignore */ }
    }
  })();
  if (ctx && ctx.waitUntil) ctx.waitUntil(pump);

  return new Response(readable, {
    headers: { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-store, no-transform", "X-Accel-Buffering": "no" },
  });
}
