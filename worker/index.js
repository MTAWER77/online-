
const MODELS = [
  "openai/gpt-oss-120b",
  "openai/gpt-oss-20b",
  "qwen/qwen3.8-27b",
];

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

function sendEvent(controller, data) {
  controller.enqueue(
    new TextEncoder().encode(`data: ${JSON.stringify(data)}\n\n`)
  );
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/health") {
      return json({
        ok: true,
        provider: "Groq",
        model: MODELS[0],
        fallbackModels: MODELS.slice(1),
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
      error: "GROQ_API_KEY غير موجود في Cloudflare.",
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
    (sum, m) => sum + m.content.length,
    0
  );

  if (total > MAX_CHARS) {
    return json({
      error: "المحادثة طويلة جدًا. ابدأ محادثة جديدة.",
    }, 413);
  }

  // تجربة الموديلات بالترتيب تلقائيًا
  let upstream = null;
  let selectedModel = null;
  let lastStatus = 502;
  let lastDetails = "";

  for (const model of MODELS) {
    try {
      const response = await fetch(API, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${env.GROQ_API_KEY}`,
        },
        body: JSON.stringify({
          model,
          messages: [
            { role: "system", content: SYSTEM_PROMPT },
            ...messages,
          ],
          max_completion_tokens: 4096,
          stream: true,
        }),
      });

      if (response.ok) {
        upstream = response;
        selectedModel = model;
        break;
      }

      lastStatus = response.status;
      lastDetails = await response.text().catch(() => "");

      console.error(
        `Model ${model} failed:`,
        response.status,
        lastDetails.slice(0, 1000)
      );

      // لا فائدة من تجربة موديلات أخرى عند وجود مشكلة
      // في المفتاح أو الحساب أو الصلاحيات.
      if ([400, 401, 402, 403].includes(response.status)) {
        break;
      }

      // جرّب الموديل التالي عند أخطاء التوفر أو حدود الاستخدام.
      if (![404, 408, 429, 500, 502, 503, 504].includes(response.status)) {
        break;
      }
    } catch (error) {
      console.error(`Connection failed for ${model}:`, error);
      lastStatus = 502;
      lastDetails = String(error);
    }
  }

  if (!upstream) {
    if (lastStatus === 401) {
      return json({ error: "مفتاح Groq غير صالح." }, 502);
    }

    if (lastStatus === 402) {
      return json({ error: "حساب Groq لا يملك رصيدًا كافيًا." }, 502);
    }

    if (lastStatus === 403) {
      return json({ error: "حساب Groq لا يملك صلاحية استخدام الخدمة." }, 502);
    }

    if (lastStatus === 429) {
      return json({
        error: "تم تجاوز حدود استخدام جميع الموديلات المتاحة. حاول لاحقًا.",
      }, 429);
    }

    return json({
      error: "تعذر تشغيل الموديلات المتاحة حاليًا. حاول مرة أخرى.",
    }, 502);
  }

  if (!upstream.body) {
    return json({
      error: "Groq لم يرجع مجرى بيانات.",
    }, 502);
  }

  console.log("NOVA selected model:", selectedModel);

  const stream = new ReadableStream({
    async start(controller) {
      const reader = upstream.body.getReader();
      const decoder = new TextDecoder();

      let buffer = "";
      let finish = null;
      let closed = false;

      const close = () => {
        if (!closed) {
          closed = true;
          controller.close();
        }
      };

      const fail = (message) => {
        if (closed) return;
        sendEvent(controller, { error: message });
        close();
      };

      const processLine = (line) => {
        line = line.trim();

        if (!line.startsWith("data:")) return;

        const raw = line.slice(5).trim();

        if (!raw || raw === "[DONE]") return;

        let chunk;

        try {
          chunk = JSON.parse(raw);
        } catch {
          return;
        }

        const choice = chunk.choices?.[0];
        const content = choice?.delta?.content;

        if (typeof content === "string" && content.length) {
          sendEvent(controller, { t: content });
        }

        if (choice?.finish_reason) {
          finish = choice.finish_reason;
        }
      };

      try {
        while (!closed) {
          const { done, value } = await reader.read();

          if (done) break;

          buffer += decoder.decode(value, { stream: true });

          const lines = buffer.split("\n");
          buffer = lines.pop() || "";

          for (const line of lines) {
            processLine(line);
          }
        }

        buffer += decoder.decode();

        if (buffer.trim()) {
          processLine(buffer);
        }

        sendEvent(controller, {
          done: true,
          finish: finish === "length" ? "MAX_TOKENS" : finish,
        });

        close();
      } catch (error) {
        console.error("Groq streaming error:", error);
        fail("انقطع الاتصال أثناء استقبال الرد.");
      } finally {
        try {
          reader.releaseLock();
        } catch {}
      }
    },

    async cancel() {
      try {
        await upstream.body.cancel();
      } catch {}
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      "X-Accel-Buffering": "no",
    },
  });
}
