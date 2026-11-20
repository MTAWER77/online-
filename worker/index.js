const TEXT_MODELS = [
  "openai/gpt-oss-120b",
  "qwen/qwen3.8-27b",
  "openai/gpt-oss-20b",
];

const VISION_MODEL = "qwen/qwen3.8-27b";
const SEARCH_MODELS = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"];
const API = "https://api.groq.com/openai/v1/chat/completions";
const MAX_MESSAGES = 30;
const MAX_CHARS = 45000;
const MAX_IMAGES = 3;
const MAX_IMAGE_DATA_CHARS = 1800000;
const MAX_GENERATED_FILES = 20;
const MAX_GENERATED_FILE_CHARS = 100000;
const MAX_GENERATED_TOTAL_CHARS = 300000;

const SYSTEM_PROMPT =
  "You are NOVA AI, a helpful, accurate and friendly assistant. " +
  "Always reply in the same language the user writes in (Arabic or English). " +
  "Be direct and avoid unnecessary introductions. " +
  "You are also a Godot game engine expert. When users upload Godot project files: " +
  "Analyze GDScript code, .tscn scenes, .tres resources, node hierarchies, signals, paths, and interactions. " +
  "Treat multiple uploaded files as one project and reference exact file names. " +
  "Suggest specific, safe fixes and avoid breaking existing systems. " +
  "When images are attached, inspect their visible contents and answer the user's question about them. " +
  "If an image is unclear or unreadable, say so instead of guessing.";

const SEARCH_SYSTEM_PROMPT =
  SYSTEM_PROMPT + " The user enabled web search. Search the web before answering, " +
  "prioritize recent and trustworthy sources, distinguish facts from uncertainty, " +
  "and provide clickable source URLs. Answer in the user's language. Never invent sources or URLs.";

const FILES_SYSTEM_PROMPT =
  "You are NOVA AI's file-generation engine. " +
  'Return ONLY one valid JSON object: {"message":"...","files":[{"name":"relative/path.ext","content":"complete file content"}]}. ' +
  "Create complete, usable files based on the user's latest request and conversation context. " +
  "Do not use Markdown fences around the JSON. For one file, return one file. " +
  "For a project, return all required files and sensible relative paths. " +
  "For Godot projects, include project.godot and required scripts/scenes/resources when appropriate. " +
  "Do not use placeholders such as 'rest of code here'. Keep paths relative and safe. " +
  "Limit to 20 files and compact output. Use the same language as the user's latest message for the message field.";

const json = (body, status = 200, headers = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
  });

function sendEvent(controller, data) {
  controller.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(data)}\n\n`));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/api/health") {
      return json({
        ok: true, provider: "Groq", textModels: TEXT_MODELS,
        visionModel: VISION_MODEL, searchModels: SEARCH_MODELS,
        maxImagesPerRequest: MAX_IMAGES,
        searchProvider: "Groq Browser Search",
        note: "Actual model availability and limits depend on your Groq account.",
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
  if (!body || !Array.isArray(body.messages) || !body.messages.length) return { error: "لا توجد رسائل." };
  const messages = body.messages
    .filter(m => m && (m.role === "user" || m.role === "assistant") &&
      (typeof m.content === "string" || Array.isArray(m.content)))
    .slice(-MAX_MESSAGES)
    .map(m => ({ role: m.role, content: m.content }));

  while (messages.length && messages[0].role !== "user") messages.shift();
  if (!messages.length || messages[messages.length - 1].role !== "user") {
    return { error: "يجب أن تنتهي المحادثة برسالة من المستخدم." };
  }

  let total = 0, imageCount = 0;
  for (const m of messages) {
    if (typeof m.content === "string") { total += m.content.length; continue; }
    if (m.role !== "user" || !Array.isArray(m.content)) return { error: "تنسيق الرسالة غير صالح." };

    for (const part of m.content) {
      if (part?.type === "text" && typeof part.text === "string") total += part.text.length;
      else if (part?.type === "image_url" && typeof part.image_url?.url === "string") {
        imageCount++;
        const src = part.image_url.url;
        if (!/^data:image\/(jpeg|jpg|png|webp|gif);base64,[a-z0-9+/=]+$/i.test(src)) {
          return { error: "صيغة الصورة غير مدعومة. ارفع JPG أو PNG أو WEBP." };
        }
        if (src.length > MAX_IMAGE_DATA_CHARS) return { error: "حجم الصورة بعد تجهيزها كبير جدًا." };
      } else return { error: "محتوى مرفق غير صالح." };
    }
  }
  if (total > MAX_CHARS) return { error: "المحادثة طويلة جدًا. ابدأ محادثة جديدة." };
  if (imageCount > MAX_IMAGES) return { error: `يمكن تحليل ${MAX_IMAGES} صور كحد أقصى في الطلب الواحد.` };
  return { messages, hasImages: imageCount > 0 };
}

function modelList(hasImages, avoidModels) {
  const avoid = new Set(Array.isArray(avoidModels) ? avoidModels.filter(x => typeof x === "string") : []);
  return (hasImages ? [VISION_MODEL] : TEXT_MODELS).filter(m => !avoid.has(m));
}

function getRateHeaders(response) {
  const names = [
    "x-ratelimit-limit-requests", "x-ratelimit-limit-tokens",
    "x-ratelimit-remaining-requests", "x-ratelimit-remaining-tokens",
    "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens", "retry-after",
  ];
  const out = {};
  for (const name of names) {
    const value = response.headers.get(name);
    if (value !== null) out[name] = value;
  }
  return out;
}

function novaHeaders(model, response) {
  const headers = new Headers({
    "X-NOVA-Model": model,
    "Access-Control-Expose-Headers": "X-NOVA-Model, X-NOVA-Rate-Limits",
  });
  headers.set("X-NOVA-Rate-Limits", JSON.stringify(getRateHeaders(response)));
  return headers;
}

async function requestModel(model, messages, env, options = {}) {
  const payload = {
    model,
    messages: [{ role: "system", content: options.systemPrompt || SYSTEM_PROMPT }, ...messages],
    max_completion_tokens: options.maxTokens || 8192,
    ...(options.temperature !== undefined ? { temperature: options.temperature } : {}),
    stream: !!options.stream,
  };

  if (options.search) {
    payload.tools = [{ type: "browser_search" }];
    payload.tool_choice = "required";
    payload.reasoning_effort = "low";
  } else if (options.reasoningEffort) {
    payload.reasoning_effort = options.reasoningEffort;
  }

  return fetch(API, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.GROQ_API_KEY}` },
    body: JSON.stringify(payload),
  });
}

async function selectUpstream(models, messages, env, options = {}) {
  let lastStatus = 502, lastDetails = "";
  for (const model of models) {
    try {
      const response = await requestModel(model, messages, env, options);
      if (response.ok) return { response, model };
      lastStatus = response.status;
      lastDetails = await response.text().catch(() => "");
      console.error(`Model ${model} failed:`, response.status, lastDetails.slice(0, 700));
      if ([400, 401, 402, 403].includes(response.status)) break;
      if (![404, 408, 413, 429, 500, 502, 503, 504].includes(response.status)) break;
    } catch (error) {
      console.error(`Connection failed for ${model}:`, error);
      lastStatus = 502; lastDetails = String(error);
    }
  }
  return { response: null, model: null, lastStatus, lastDetails };
}

function searchSources(message) {
  const annotations = Array.isArray(message?.annotations) ? message.annotations : [];
  const found = new Map();
  for (const item of annotations) {
    const cite = item?.url_citation || item?.urlCitation || item;
    const url = typeof cite?.url === "string" ? cite.url : "";
    const title = typeof cite?.title === "string" ? cite.title : url;
    if (url.startsWith("https://") || url.startsWith("http://")) found.set(url, title || url);
  }
  return [...found.entries()].map(([url, title]) => ({ title, url })).slice(0, 10);
}

function appendSources(content, sources) {
  if (!sources.length) return content;
  const lines = sources.map((s, i) => `${i + 1}. [${s.title.replace(/[\[\]]/g, "")}](${s.url})`);
  return `${content}\n\n**المصادر:**\n${lines.join("\n")}`;
}

async function handleSearchChat(validated, body, env) {
  if (validated.hasImages) {
    return json({ error: "البحث على الويب وتحليل الصور غير متاحين معًا في نفس الرسالة. أوقف البحث لتحليل الصورة." }, 400);
  }
  const avoid = new Set(Array.isArray(body.avoidModels) ? body.avoidModels : []);
  const models = SEARCH_MODELS.filter(m => !avoid.has(m));
  if (!models.length) return json({ error: "موديلات البحث في فترة راحة مؤقتة بسبب حدود الاستخدام. جرّب بعد قليل." }, 429);

  const chosen = await selectUpstream(models, validated.messages, env, {
    stream: false, search: true, maxTokens: 4096, temperature: 0.2,
    systemPrompt: SEARCH_SYSTEM_PROMPT,
  });
  if (!chosen.response) {
    if (chosen.lastStatus === 400) {
      return json({ error: "Groq رفض طلب البحث. تأكد أن Browser Search متاح لموديل GPT-OSS في حسابك." }, 502);
    }
    return modelError(chosen.lastStatus);
  }

  try {
    const result = await chosen.response.json();
    const message = result.choices?.[0]?.message;
    const raw = message?.content;
    if (typeof raw !== "string" || !raw.trim()) return json({ error: "البحث لم يُرجع إجابة." }, 502);
    const sources = searchSources(message);
    const content = appendSources(raw, sources);
    const headers = novaHeaders(chosen.model, chosen.response);
    headers.set("Content-Type", "text/event-stream; charset=utf-8");
    headers.set("Cache-Control", "no-cache, no-transform");
    headers.set("X-Accel-Buffering", "no");

    const stream = new ReadableStream({
      start(controller) {
        sendEvent(controller, { t: content });
        sendEvent(controller, { done: true, finish: result.choices?.[0]?.finish_reason || "stop", model: chosen.model, sources });
        controller.close();
      },
    });
    return new Response(stream, { status: 200, headers });
  } catch (error) {
    console.error("Browser search response error:", error);
    return json({ error: "تعذرت قراءة نتيجة البحث من Groq." }, 502);
  }
}

async function handleChat(request, env) {
  if (!env.GROQ_API_KEY) return json({ error: "GROQ_API_KEY غير موجود في Cloudflare." }, 500);
  let body;
  try { body = await request.json(); } catch { return json({ error: "طلب JSON غير صالح." }, 400); }
  const validated = validateMessages(body);
  if (validated.error) return json({ error: validated.error }, 400);

  if (body.search === true) return handleSearchChat(validated, body, env);

  // Think mode uses GPT-OSS models, which support the reasoning_effort parameter.
  const models = body.think === true && !validated.hasImages
    ? TEXT_MODELS.filter(model => model.startsWith("openai/gpt-oss/")).filter(model => !(Array.isArray(body.avoidModels) && body.avoidModels.includes(model)))
    : modelList(validated.hasImages, body.avoidModels);
  if (!models.length) return json({
    error: validated.hasImages
      ? "موديل تحليل الصور وصل إلى حد الاستخدام المؤقت. انتظر وقت التجديد ثم جرّب مرة أخرى."
      : "كل الموديلات في فترة راحة مؤقتة بسبب حدود الاستخدام. جرّب بعد قليل.",
  }, 429);

  const chosen = await selectUpstream(models, validated.messages, env, {
    stream: true,
    reasoningEffort: body.think === true && !validated.hasImages ? "high" : undefined,
  });
  if (!chosen.response) {
    if (validated.hasImages) return json({
      error: chosen.lastStatus === 429
        ? "حد استخدام موديل تحليل الصور وصل للنهاية. جرّب بعد وقت التجديد."
        : "تعذر تشغيل موديل تحليل الصور حاليًا. تأكد من تفعيل qwen/qwen3.8-27b في حساب Groq.",
    }, chosen.lastStatus === 429 ? 429 : 502);
    return modelError(chosen.lastStatus);
  }

  const upstream = chosen.response, selectedModel = chosen.model;
  if (!upstream.body) return json({ error: "Groq لم يرجع مجرى بيانات." }, 502);
  console.log("NOVA selected model:", selectedModel, getRateHeaders(upstream));

  const headers = novaHeaders(selectedModel, upstream);
  headers.set("Content-Type", "text/event-stream; charset=utf-8");
  headers.set("Cache-Control", "no-cache, no-transform");
  headers.set("X-Accel-Buffering", "no");

  const stream = new ReadableStream({
    async start(controller) {
      const reader = upstream.body.getReader(), decoder = new TextDecoder();
      let buffer = "", finish = null, closed = false;
      const close = () => { if (!closed) { closed = true; controller.close(); } };
      const fail = message => { if (!closed) { sendEvent(controller, { error: message }); close(); } };
      const processLine = line => {
        line = line.trim();
        if (!line.startsWith("data:")) return;
        const raw = line.slice(5).trim();
        if (!raw || raw === "[DONE]") return;
        let chunk;
        try { chunk = JSON.parse(raw); } catch { return; }
        const choice = chunk.choices?.[0], content = choice?.delta?.content;
        if (typeof content === "string" && content.length) sendEvent(controller, { t: content });
        if (choice?.finish_reason) finish = choice.finish_reason;
      };
      try {
        while (!closed) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n"); buffer = lines.pop() || "";
          for (const line of lines) processLine(line);
        }
        buffer += decoder.decode();
        if (buffer.trim()) processLine(buffer);
        sendEvent(controller, { done: true, finish: finish === "length" ? "MAX_TOKENS" : finish, model: selectedModel });
        close();
      } catch (error) {
        console.error("Groq streaming error:", error);
        fail("انقطع الاتصال أثناء استقبال الرد.");
      } finally { try { reader.releaseLock(); } catch {} }
    },
    async cancel() { try { await upstream.body.cancel(); } catch {} },
  });
  return new Response(stream, { status: 200, headers });
}

async function handleGenerateFiles(request, env) {
  if (!env.GROQ_API_KEY) return json({ error: "GROQ_API_KEY غير موجود في Cloudflare." }, 500);
  let body;
  try { body = await request.json(); } catch { return json({ error: "طلب JSON غير صالح." }, 400); }
  const validated = validateMessages(body);
  if (validated.error) return json({ error: validated.error }, 400);
  if (validated.hasImages) return json({ error: "أوقف إرفاق الصور قبل طلب توليد الملفات." }, 400);

  const models = modelList(false, body.avoidModels);
  if (!models.length) return json({ error: "الموديل المطلوب في فترة راحة مؤقتة بسبب حدود الاستخدام. جرّب بعد قليل." }, 429);
  const chosen = await selectUpstream(models, validated.messages, env, {
    stream: false, maxTokens: 8192, temperature: 0.2, systemPrompt: FILES_SYSTEM_PROMPT,
  });
  if (!chosen.response) return modelError(chosen.lastStatus);

  const response = chosen.response, model = chosen.model;
  try {
    const result = await response.json(), raw = result.choices?.[0]?.message?.content;
    if (typeof raw !== "string" || !raw.trim()) return json({ error: "النموذج لم يُرجع محتوى للملفات." }, 502);
    let parsed;
    try {
      const cleaned = raw.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
      const start = cleaned.indexOf("{"), end = cleaned.lastIndexOf("}");
      parsed = JSON.parse(start >= 0 && end > start ? cleaned.slice(start, end + 1) : cleaned);
    } catch (error) {
      console.error("Generated files JSON parse error:", error, raw.slice(0, 1000));
      return json({ error: "تعذر قراءة الملفات التي أنشأها النموذج. جرّب طلبًا أبسط." }, 502);
    }
    const files = normalizeGeneratedFiles(parsed.files);
    if (!files.length) return json({ error: "لم يتم إنشاء ملفات صالحة." }, 502);
    return json({
      ok: true,
      message: typeof parsed.message === "string" ? parsed.message.slice(0, 3000) : "تم إنشاء الملفات المطلوبة. يمكنك تحميلها من الأسفل.",
      files, model, rateLimits: getRateHeaders(response),
    }, 200, { "X-NOVA-Model": model, "X-NOVA-Rate-Limits": JSON.stringify(getRateHeaders(response)) });
  } catch (error) {
    console.error("File generation response error:", error);
    return json({ error: "تعذر قراءة استجابة Groq." }, 502);
  }
}

function normalizeGeneratedFiles(input) {
  if (!Array.isArray(input)) return [];
  const files = []; let totalChars = 0; const usedNames = new Set();
  for (const item of input.slice(0, MAX_GENERATED_FILES)) {
    if (!item || typeof item.name !== "string" || typeof item.content !== "string") continue;
    let name = item.name.replace(/\\/g, "/").trim();
    name = name.split("/").filter(part => part && part !== "." && part !== "..").join("/");
    name = name.replace(/[<>:"|?*\u0000-\u001f]/g, "_").slice(0, 180);
    if (!name || item.content.length > MAX_GENERATED_FILE_CHARS) continue;
    if (totalChars + item.content.length > MAX_GENERATED_TOTAL_CHARS) break;
    let uniqueName = name, suffix = 2;
    while (usedNames.has(uniqueName.toLowerCase())) {
      const dot = name.lastIndexOf(".");
      uniqueName = dot > 0 ? name.slice(0, dot) + "-" + suffix++ + name.slice(dot) : name + "-" + suffix++;
    }
    usedNames.add(uniqueName.toLowerCase()); totalChars += item.content.length;
    files.push({ name: uniqueName, content: item.content });
  }
  return files;
}

function modelError(status) {
  if (status === 401) return json({ error: "مفتاح Groq غير صالح." }, 502);
  if (status === 402) return json({ error: "حساب Groq لا يملك رصيدًا كافيًا." }, 502);
  if (status === 403) return json({ error: "حساب Groq لا يملك صلاحية استخدام الخدمة." }, 502);
  if (status === 413) return json({ error: "حجم الطلب كبير جدًا. قلل عدد الملفات أو الصور." }, 413);
  if (status === 429) return json({ error: "تم تجاوز حدود استخدام جميع الموديلات المتاحة. حاول لاحقًا." }, 429);
  return json({ error: "تعذر تشغيل الموديلات المتاحة حاليًا. حاول مرة أخرى." }, 502);
}
