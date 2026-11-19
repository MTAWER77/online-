const MODEL = "gemini-2.5-flash";
const API = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;
const MAX_MESSAGES = 30;
const MAX_CHARS = 30000;
const SYSTEM_PROMPT =
  "You are NOVA AI, a helpful, accurate and friendly assistant. " +
  "Always reply in the same language the user writes in (Arabic or English). " +
  "When you write code, always put it in fenced Markdown code blocks with the language name.";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/api/health") return json({ ok: true });
    if (url.pathname === "/api/chat") {
      if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
      return handleChat(request, env);
    }
    if (env.ASSETS) return env.ASSETS.fetch(request);
    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request, env) {
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

  let contents = body.messages
    .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string" && m.content.trim())
    .slice(-MAX_MESSAGES)
    .map((m) => ({ role: m.role === "assistant" ? "model" : "user", parts: [{ text: m.content }] }));
  while (contents.length && contents[0].role !== "user") contents.shift();
  if (!contents.length || contents[contents.length - 1].role !== "user") {
    return json({ error: "يجب أن تنتهي المحادثة برسالة من المستخدم." }, 400);
  }
  const total = contents.reduce((n, c) => n + c.parts[0].text.length, 0);
  if (total > MAX_CHARS) return json({ error: "المحادثة طويلة جدًا. ابدأ محادثة جديدة." }, 413);

  let res;
  try {
    res = await fetch(API, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
        contents,
        generationConfig: { temperature: 0.7, maxOutputTokens: 4096 },
      }),
    });
  } catch {
    return json({ error: "تعذر الوصول إلى Gemini. حاول مرة أخرى." }, 502);
  }

  if (!res.ok) {
    let msg = `خطأ من Gemini (${res.status}).`;
    if (res.status === 429) msg = "تم تجاوز حد الاستخدام. انتظر قليلًا ثم حاول مرة أخرى.";
    else if (res.status === 400 || res.status === 403) msg = "مفتاح Gemini غير صالح أو الطلب مرفوض. راجع إعداد المفتاح.";
    else if (res.status >= 500) msg = "خدمة Gemini غير متاحة حاليًا. حاول لاحقًا.";
    return json({ error: msg }, res.status === 429 ? 429 : 502);
  }

  let data;
  try {
    data = await res.json();
  } catch {
    return json({ error: "رد غير مفهوم من Gemini." }, 502);
  }
  const cand = data && data.candidates && data.candidates[0];
  const text = cand && cand.content && Array.isArray(cand.content.parts)
    ? cand.content.parts.map((p) => p.text || "").join("")
    : "";
  if (!text.trim()) {
    const blocked = data && data.promptFeedback && data.promptFeedback.blockReason;
    return json({ error: blocked ? "تم حظر الطلب بواسطة فلاتر الأمان." : "لم يرجع Gemini أي رد. جرّب صياغة مختلفة." }, 502);
  }
  return json({ reply: text });
}
