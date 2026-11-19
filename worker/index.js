
const MODEL = "openai/gpt-oss-120b";
const API = "https://api.groq.com/openai/v1/chat/completions";

const MAX_MESSAGES = 30;
const MAX_CHARS = 30000;

const SYSTEM_PROMPT =
  "You are NOVA AI, a helpful, accurate and friendly assistant. " +
  "Always reply in the same language the user writes in (Arabic or English). " +
  "When writing code, use fenced Markdown code blocks with the language name. " +
  "Be direct and avoid unnecessary introductions.";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/health") {
      return json({
        ok: true,
        provider: "Groq",
        model: MODEL,
      });
    }

    if (url.pathname === "/api/chat") {
      if (request.method !== "POST") {
        return json({ error: "Method not allowed" }, 405);
      }

      return handleChat(request, env);
    }

    if (env.ASSETS) {
      return env.ASSETS.fetch(request);
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request, env) {
  if (!env.GROQ_API_KEY) {
    return json({
      error: "الخادم غير مهيأ: GROQ_API_KEY غير موجود.",
    }, 500);
  }

  let body;

  try {
    body = await request.json();
  } catch {
    return json({ error: "طلب JSON غير صالح." }, 400);
  }

  if (!body || !Array.isArray(body.messages) || !body.messages.length) {
    return json({ error: "لا توجد رسائل." }, 400);
  }

  const messages = body.messages
    .filter(
      (m) =>
        m &&
        (m.role === "user" || m.role === "assistant") &&
        typeof m.content === "string" &&
        m.content.trim()
    )
    .slice(-MAX_MESSAGES)
    .map((m) => ({
      role: m.role,
      content: m.content,
    }));

  while (messages.length && messages[0].role !== "user") {
    messages.shift();
  }

  if (
    !messages.length ||
    messages[messages.length - 1].role !== "user"
  ) {
    return json({
      error: "يجب أن تنتهي المحادثة برسالة من المستخدم.",
    }, 400);
  }

  const total = messages.reduce(
    (sum, message) => sum + message.content.length,
    0
  );

  if (total > MAX_CHARS) {
    return json({
      error: "المحادثة طويلة جدًا. ابدأ محادثة جديدة.",
    }, 413);
  }

  const startedAt = Date.now();

  let response;

  try {
    response = await fetch(API, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.GROQ_API_KEY}`,
      },
      body: JSON.stringify({
        model: MODEL,
        messages: [
          {
            role: "system",
            content: SYSTEM_PROMPT,
          },
          ...messages,
        ],
        max_completion_tokens: 4096,
        stream: false,
      }),
    });
  } catch (error) {
    console.error("Groq connection error:", error);

    return json({
      error: "تعذر الاتصال بخدمة Groq. حاول مرة أخرى.",
    }, 502);
  }

  if (!response.ok) {
    const details = await response.text().catch(() => "");

    console.error(
      "Groq API error:",
      response.status,
      details.slice(0, 1500)
    );

    if (response.status === 401) {
      return json({
        error: "مفتاح Groq غير صالح. راجع GROQ_API_KEY.",
      }, 502);
    }

    if (response.status === 402) {
      return json({
        error: "حساب Groq لا يملك رصيدًا أو صلاحية استخدام كافية.",
      }, 502);
    }

    if (response.status === 429) {
      return json({
        error: "تم تجاوز حد الاستخدام المجاني. انتظر قليلًا ثم حاول.",
      }, 429);
    }

    return json({
      error: `حدث خطأ من Groq (${response.status}). راجع سجلات Worker.`,
    }, 502);
  }

  let data;

  try {
    data = await response.json();
  } catch {
    return json({
      error: "تعذر قراءة استجابة Groq.",
    }, 502);
  }

  const reply = data?.choices?.[0]?.message?.content;

  if (typeof reply !== "string" || !reply.trim()) {
    console.error("Empty Groq response:", data);

    return json({
      error: "لم يرجع النموذج أي رد. حاول مرة أخرى.",
    }, 502);
  }

  return json({
    reply,
    provider: "Groq",
    model: MODEL,
    elapsed_ms: Date.now() - startedAt,
  });
}
