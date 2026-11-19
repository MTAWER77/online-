const MODELS = [
  "openai/gpt-oss-120b",
  "openai/gpt-oss-20b",
  "qwen/qwen3.8-27b",
];

const API = "https://api.groq.com/openai/v1/chat/completions";
const MAX_MESSAGES = 30;
const MAX_CHARS = 45000;
const MAX_GENERATED_FILES = 20;
const MAX_GENERATED_FILE_CHARS = 100000;
const MAX_GENERATED_TOTAL_CHARS = 300000;

const SYSTEM_PROMPT =
  "You are NOVA AI, a helpful, accurate and friendly assistant. " +
  "Always reply in the same language the user writes in (Arabic or English). " +
  "When writing code, use fenced Markdown code blocks with the language name. " +
  "Be direct and avoid unnecessary introductions. " +
  "You are also a Godot game engine expert. When users upload Godot project files: " +
  "Analyze GDScript code: explain logic, find bugs, suggest fixes. " +
  "Analyze .tscn scene files: understand node hierarchy, resources, connections. " +
  "Analyze .tres resource files: understand configurations and data. " +
  "Understand relationships between scripts, scenes, and resources. " +
  "When multiple files are uploaded, treat them as one project and analyze interactions. " +
  "Always reference file names when explaining issues. " +
  "Suggest specific code fixes with proper GDScript syntax. " +
  "Help users add features without breaking existing systems. " +
  "Detect common Godot errors: null references, signal issues, node path problems.";

const FILES_SYSTEM_PROMPT =
  "You are NOVA AI's file-generation engine. " +
  "Create complete, usable files based on the user's latest request and conversation context. " +
  "Return ONLY one valid JSON object, with this exact structure: " +
  '{"message":"A short helpful explanation in the user language","files":[{"name":"relative/path.ext","content":"complete file content"}]}. ' +
  "Do not use Markdown fences around the JSON. " +
  "For one file, return one file. For a project, return all required files and sensible relative paths. " +
  "For Godot projects, include project.godot and the required scripts/scenes/resources when appropriate. " +
  "Do not omit important code with placeholders such as 'rest of code here'. " +
  "Keep filenames safe and relative; never use absolute paths or ../. " +
  "Limit output to 20 files and keep the combined content reasonably compact. " +
  "Do not include explanations inside file contents unless they belong in the requested file. " +
  "Use the same language as the user's latest message for the message field.";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });

function sendEvent(controller, data) {
  controller.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(data)}\n\n`));
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
      if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
      return handleChat(request, env);
    }

    if (url.pathname === "/api/generate-files") {
      if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
      return handleGenerateFiles(request, env);
    }

    if (env.ASSETS) return env.ASSETS.fetch(request);
    return new Response("Not found", { status: 404 });
  },
};

function validateMessages(body) {
  if (!body || !Array.isArray(body.messages) || !body.messages.length) {
    return { error: "لا توجد رسائل." };
  }

  const messages = body.messages
    .filter((m) =>
      m &&
      (m.role === "user" || m.role === "assistant") &&
      typeof m.content === "string" &&
      m.content.trim()
    )
    .slice(-MAX_MESSAGES)
    .map((m) => ({ role: m.role, content: m.content }));

  while (messages.length && messages[0].role !== "user") messages.shift();

  if (!messages.length || messages[messages.length - 1].role !== "user") {
    return { error: "يجب أن تنتهي المحادثة برسالة من المستخدم." };
  }

  const total = messages.reduce((sum, m) => sum + m.content.length, 0);
  if (total > MAX_CHARS) return { error: "المحادثة طويلة جدًا. ابدأ محادثة جديدة." };

  return { messages };
}

async function handleChat(request, env) {
  if (!env.GROQ_API_KEY) return json({ error: "GROQ_API_KEY غير موجود في Cloudflare." }, 500);

  let body;
  try { body = await request.json(); }
  catch { return json({ error: "طلب JSON غير صالح." }, 400); }

  const validated = validateMessages(body);
  if (validated.error) return json({ error: validated.error }, 400);
  const messages = validated.messages;

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
          messages: [{ role: "system", content: SYSTEM_PROMPT }, ...messages],
          max_completion_tokens: 8192,
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
      console.error(`Model ${model} failed:`, response.status, lastDetails.slice(0, 1000));

      if ([400, 401, 402, 403].includes(response.status)) break;
      if (![404, 408, 429, 500, 502, 503, 504].includes(response.status)) break;
    } catch (error) {
      console.error(`Connection failed for ${model}:`, error);
      lastStatus = 502;
      lastDetails = String(error);
    }
  }

  if (!upstream) return modelError(lastStatus);
  if (!upstream.body) return json({ error: "Groq لم يرجع مجرى بيانات." }, 502);

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
        try { chunk = JSON.parse(raw); } catch { return; }

        const choice = chunk.choices?.[0];
        const content = choice?.delta?.content;
        if (typeof content === "string" && content.length) sendEvent(controller, { t: content });
        if (choice?.finish_reason) finish = choice.finish_reason;
      };

      try {
        while (!closed) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() || "";
          for (const line of lines) processLine(line);
        }

        buffer += decoder.decode();
        if (buffer.trim()) processLine(buffer);
        sendEvent(controller, { done: true, finish: finish === "length" ? "MAX_TOKENS" : finish });
        close();
      } catch (error) {
        console.error("Groq streaming error:", error);
        fail("انقطع الاتصال أثناء استقبال الرد.");
      } finally {
        try { reader.releaseLock(); } catch {}
      }
    },
    async cancel() {
      try { await upstream.body.cancel(); } catch {}
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

async function handleGenerateFiles(request, env) {
  if (!env.GROQ_API_KEY) return json({ error: "GROQ_API_KEY غير موجود في Cloudflare." }, 500);

  let body;
  try { body = await request.json(); }
  catch { return json({ error: "طلب JSON غير صالح." }, 400); }

  const validated = validateMessages(body);
  if (validated.error) return json({ error: validated.error }, 400);

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
            { role: "system", content: FILES_SYSTEM_PROMPT },
            ...validated.messages,
          ],
          max_completion_tokens: 8192,
          temperature: 0.2,
          stream: false,
        }),
      });

      if (!response.ok) {
        lastStatus = response.status;
        lastDetails = await response.text().catch(() => "");
        console.error(`File generation model ${model} failed:`, response.status, lastDetails.slice(0, 1000));
        if ([400, 401, 402, 403].includes(response.status)) break;
        if (![404, 408, 429, 500, 502, 503, 504].includes(response.status)) break;
        continue;
      }

      const result = await response.json();
      const raw = result.choices?.[0]?.message?.content;
      if (typeof raw !== "string" || !raw.trim()) {
        return json({ error: "النموذج لم يُرجع محتوى للملفات." }, 502);
      }

      let parsed;
      try {
        const cleaned = raw.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
        const start = cleaned.indexOf("{");
        const end = cleaned.lastIndexOf("}");
        parsed = JSON.parse(start >= 0 && end > start ? cleaned.slice(start, end + 1) : cleaned);
      } catch (error) {
        console.error("Generated files JSON parse error:", error, raw.slice(0, 1500));
        return json({ error: "تعذر قراءة الملفات التي أنشأها النموذج. جرّب طلبًا أبسط." }, 502);
      }

      const files = normalizeGeneratedFiles(parsed.files);
      if (!files.length) return json({ error: "لم يتم إنشاء ملفات صالحة." }, 502);

      return json({
        ok: true,
        message: typeof parsed.message === "string"
          ? parsed.message.slice(0, 3000)
          : "تم إنشاء الملفات المطلوبة. يمكنك تحميلها من الأسفل.",
        files,
        model,
      });
    } catch (error) {
      console.error(`File generation request failed for ${model}:`, error);
      lastStatus = 502;
      lastDetails = String(error);
    }
  }

  return modelError(lastStatus);
}

function normalizeGeneratedFiles(input) {
  if (!Array.isArray(input)) return [];
  const files = [];
  let totalChars = 0;
  const usedNames = new Set();

  for (const item of input.slice(0, MAX_GENERATED_FILES)) {
    if (!item || typeof item.name !== "string" || typeof item.content !== "string") continue;

    let name = item.name.replace(/\\/g, "/").trim();
    name = name.split("/").filter((part) => part && part !== "." && part !== "..").join("/");
    name = name.replace(/[<>:"|?*\u0000-\u001f]/g, "_").slice(0, 180);
    if (!name) continue;

    if (item.content.length > MAX_GENERATED_FILE_CHARS) continue;
    if (totalChars + item.content.length > MAX_GENERATED_TOTAL_CHARS) break;

    let uniqueName = name;
    let suffix = 2;
    while (usedNames.has(uniqueName.toLowerCase())) {
      const dot = name.lastIndexOf(".");
      uniqueName = dot > 0
        ? name.slice(0, dot) + "-" + suffix++ + name.slice(dot)
        : name + "-" + suffix++;
    }

    usedNames.add(uniqueName.toLowerCase());
    totalChars += item.content.length;
    files.push({ name: uniqueName, content: item.content });
  }

  return files;
}

function modelError(status) {
  if (status === 401) return json({ error: "مفتاح Groq غير صالح." }, 502);
  if (status === 402) return json({ error: "حساب Groq لا يملك رصيدًا كافيًا." }, 502);
  if (status === 403) return json({ error: "حساب Groq لا يملك صلاحية استخدام الخدمة." }, 502);
  if (status === 429) {
    return json({ error: "تم تجاوز حدود استخدام جميع الموديلات المتاحة. حاول لاحقًا." }, 429);
  }
  return json({ error: "تعذر تشغيل الموديلات المتاحة حاليًا. حاول مرة أخرى." }, 502);
}
