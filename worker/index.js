// NOVA AI worker V0.3 - real streaming via Gemini streamGenerateContent (alt=sse).
// Models verified against Google's deprecation page (gemini-2.5-flash shutdown: Oct 16, 2026).
// Override with the GEMINI_MODEL variable; on 404 (model not found) the next default is tried.
const DEFAULT_MODELS = ["gemini-3.6-flash", "gemini-3.5-flash"];
const api = (model) => `https://generativelanguage.googleapis.com/v1beta/models/${model}:streamGenerateContent?alt=sse`;
const MAX_MESSAGES = 12;          // history sent to Gemini (last N messages)
const MAX_CHARS = 30000;
const DEFAULT_MAX_TOKENS = 2048;  // override with the MAX_OUTPUT_TOKENS variable (256..8192)
const SYSTEM_PROMPT =
  "You are NOVA AI, a helpful, accurate and friendly assistant. " +
  "Always reply in the same language the user writes in (Arabic or English). " +
  "Use Markdown for structure (headings, lists, tables when useful). " +
  "When you write code, always put it in fenced Markdown code blocks with the language name.";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/api/health") return json({ ok: true });
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
  if (!env.GEMINI_API_KEY) {
    return json({ error: "الخادم غير مهيأ: GEMINI_API_KEY غير موجود. أضفه بـ wrangler secret put." }, 500);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "طلب غير صالح (JSON)." }, 400);
  }
  if (!body || !Array.isArray(body.messages) || body.messages.length === 0) {
    return json({ error: "لا توجد رسائل." }, 400);
  }

  const contents = body.messages
    .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string" && m.content.trim())
    .slice(-MAX_MESSAGES)
    .map((m) => ({ role: m.role === "assistant" ? "model" : "user", parts: [{ text: m.content }] }));
  while (contents.length && contents[0].role !== "user") contents.shift();
  if (!contents.length || contents[contents.length - 1].role !== "user") {
    return json({ error: "يجب أن تنتهي المحادثة برسالة من المستخدم." }, 400);
  }
  const total = contents.reduce((n, c) => n + c.parts[0].text.length, 0);
  if (total > MAX_CHARS) return json({ error: "المحادثة طويلة جدًا. ابدأ محادثة جديدة." }, 413);

  const models = env.GEMINI_MODEL ? [String(env.GEMINI_MODEL)] : DEFAULT_MODELS;
  const payload = JSON.stringify({
    systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
    contents,
    generationConfig: { maxOutputTokens: maxTokens(env) },
  });

  let res = null, used = null;
  for (const model of models) {
    try {
      res = await fetch(api(model), {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
        body: payload,
      });
    } catch {
      return json({ error: "تعذر الوصول إلى Gemini. حاول مرة أخرى." }, 502);
    }
    used = model;
    if (res.status !== 404) break; // 404 = model not found -> try next
  }

  if (!res.ok || !res.body) {
    let msg = `خطأ من Gemini (${res.status}).`;
    if (res.status === 404) msg = "النموذج غير متاح. حدّث اسم النموذج عبر المتغير GEMINI_MODEL.";
    else if (res.status === 429) msg = "تم تجاوز حد الاستخدام. انتظر قليلًا ثم حاول مرة أخرى.";
    else if (res.status === 400 || res.status === 403) msg = "مفتاح Gemini غير صالح أو الطلب مرفوض. راجع إعداد المفتاح.";
    else if (res.status >= 500) msg = "خدمة Gemini غير متاحة حاليًا. حاول لاحقًا.";
    return json({ error: msg }, res.status === 429 ? 429 : 502);
  }
  return streamResponse(res, used, ctx);
}

// Converts Gemini's SSE into a minimal SSE protocol for the frontend:
//   data: {"t":"text chunk"}   ...   data: {"done":true,"model":"...","finish":"STOP"}
//   data: {"error":"message"}  (on any failure after streaming started)
function streamResponse(upstream, model, ctx) {
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const send = (o) => writer.write(enc.encode("data: " + JSON.stringify(o) + "\n\n"));
  const reader = upstream.body.getReader();

  const pump = (async () => {
    let buf = "", any = false, finish = null, blocked = null;
    const handleLine = async (line) => {
      line = line.trim();
      if (!line.startsWith("data:")) return;
      const s = line.slice(5).trim();
      if (!s || s === "[DONE]") return;
      let d;
      try { d = JSON.parse(s); } catch { return; }
      if (d.error) throw new Error("upstream error");
      if (d.promptFeedback && d.promptFeedback.blockReason) blocked = d.promptFeedback.blockReason;
      const cand = d.candidates && d.candidates[0];
      if (!cand) return;
      if (cand.content && Array.isArray(cand.content.parts)) {
        const text = cand.content.parts.filter((p) => !p.thought).map((p) => p.text || "").join("");
        if (text) { any = true; await send({ t: text }); }
      }
      if (cand.finishReason) finish = cand.finishReason;
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
      if (!any) {
        await send({ error: blocked ? "تم حظر الطلب بواسطة فلاتر الأمان." : "لم يرجع Gemini أي رد. جرّب صياغة مختلفة." });
      } else {
        await send({ done: true, model, finish });
      }
    } catch {
      try { await send({ error: "انقطع البث من Gemini. حاول مرة أخرى." }); } catch { /* client gone */ }
    } finally {
      try { await reader.cancel(); } catch { /* ignore */ }
      try { await writer.close(); } catch { /* ignore */ }
    }
  })();
  if (ctx && ctx.waitUntil) ctx.waitUntil(pump);

  return new Response(readable, {
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-store, no-transform",
      "X-Accel-Buffering": "no",
    },
  });
}
